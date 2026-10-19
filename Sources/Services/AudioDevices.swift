import CoreAudio
import AudioToolbox
import Foundation

/// How an output device exposes software volume.
enum VolumeControl: Equatable {
    /// Device has a settable virtual main volume (plus possibly per-channel scalars).
    case main
    /// Device only exposes per-channel scalars on these elements.
    case channels([AudioObjectPropertyElement])
    /// No software volume control — cannot be limited.
    case none
}

/// A snapshot of one CoreAudio output device.
struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let control: VolumeControl
    let isHeadphones: Bool

    var isSupported: Bool { control != .none }
}

/// Thin, error-tolerant wrappers around the CoreAudio HAL property API.
enum CoreAudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let output = kAudioDevicePropertyScopeOutput

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        return AudioObjectHasProperty(id, &a)
    }

    static func isSettable(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        var settable: DarwinBoolean = false
        guard has(id, addr), AudioObjectIsPropertySettable(id, &a, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func get<T>(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, initial: T) -> T? {
        var a = addr
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    /// Writes a property; errors (e.g. device unplugged mid-write) are returned, never thrown.
    @discardableResult
    static func set<T>(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var a = addr
        var v = value
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func defaultOutputID() -> AudioDeviceID {
        get(system, address(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioDeviceID(0)) ?? 0
    }

    /// All devices that have at least one output stream.
    static func outputDevices() -> [AudioDevice] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutputStreams(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? "Unknown Device"
            return AudioDevice(id: id, uid: uid, name: name,
                               control: volumeControl(id), isHeadphones: looksLikeHeadphones(id, name: name))
        }
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var a = address(kAudioDevicePropertyStreams, output)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }

    static let mainVolume = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)

    static func scalar(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        address(kAudioDevicePropertyVolumeScalar, output, element)
    }

    static func volumeControl(_ id: AudioDeviceID) -> VolumeControl {
        if isSettable(id, mainVolume) { return .main }
        let channels = (0...2).map(AudioObjectPropertyElement.init).filter { isSettable(id, scalar($0)) }
        return channels.isEmpty ? .none : .channels(channels)
    }

    /// Heuristic: built-in headphone jack data source, Bluetooth transport, or a telling name.
    static func looksLikeHeadphones(_ id: AudioDeviceID, name: String) -> Bool {
        let headphoneSource: UInt32 = 0x6864_706E // 'hdpn'
        if get(id, address(kAudioDevicePropertyDataSource, output), initial: UInt32(0)) == headphoneSource { return true }
        let transport = get(id, address(kAudioDevicePropertyTransportType), initial: UInt32(0)) ?? 0
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        return isHeadphoneName(name)
    }

    static func isHeadphoneName(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["headphone", "airpods", "buds", "earpods", "headset", "beats"].contains { n.contains($0) }
    }

    /// Current loudness 0...1 (main volume, or the loudest channel).
    static func volume(of device: AudioDevice) -> Double? {
        switch device.control {
        case .main:
            return get(device.id, mainVolume, initial: Float32(0)).map(Double.init)
        case .channels(let els):
            let values = els.compactMap { get(device.id, scalar($0), initial: Float32(0)) }
            return values.max().map(Double.init)
        case .none:
            return nil
        }
    }

    /// Lowers the device so that no channel exceeds `ceiling`. Returns true if anything was written.
    @discardableResult
    static func clamp(_ device: AudioDevice, to ceiling: Double) -> Bool {
        let limit = Float32(ceiling)
        var changed = false
        if device.control == .main, let v = get(device.id, mainVolume, initial: Float32(0)), v > limit + 0.001 {
            changed = set(device.id, mainVolume, limit) == noErr || changed
        }
        // Clamp independent left/right (and master element) scalars too.
        for el in (0...2).map(AudioObjectPropertyElement.init) where isSettable(device.id, scalar(el)) {
            if let v = get(device.id, scalar(el), initial: Float32(0)), v > limit + 0.001 {
                changed = set(device.id, scalar(el), limit) == noErr || changed
            }
        }
        return changed
    }
}
