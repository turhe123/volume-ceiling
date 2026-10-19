import AppKit
import CoreAudio
import Foundation

/// UserDefaults keys shared by the limiter and the settings UI.
enum Prefs {
    static let enabled = "limiterEnabled"
    static let defaultCeiling = "defaultCeiling"
    static let notifications = "showNotifications"
    static let clampOnConnect = "clampOnConnect"
    static let lockSettings = "lockSettings"
    static let ceilings = "deviceCeilings"
    static let names = "deviceNames"
    static let lastVolumes = "lastVolumes"
    static let pausedUntil = "pausedUntil"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            enabled: true, defaultCeiling: 0.8, notifications: false, clampOnConnect: true, lockSettings: false,
        ])
    }
}

/// A row in the device list: a connected device or one remembered from earlier.
struct DeviceEntry: Identifiable {
    let uid: String
    let name: String
    let device: AudioDevice?
    var id: String { uid }
}

/// Watches CoreAudio for device and volume changes and enforces per-device volume ceilings.
final class Limiter: ObservableObject {
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var defaultID: AudioDeviceID = 0
    @Published private(set) var currentVolume: Double?
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var unlockedUntil: Date?

    private let defaults = UserDefaults.standard
    private var watchedID: AudioDeviceID = 0
    private var volumeBlock: AudioObjectPropertyListenerBlock?
    private var pending: DispatchWorkItem?
    private var isWriting = false
    private var resumeTimer: Timer?
    private var lastNotified: [String: Date] = [:]
    private let volumeAddresses = [
        CoreAudioHAL.mainVolume,
        CoreAudioHAL.scalar(kAudioObjectPropertyElementWildcard),
    ]

    init() {
        Prefs.registerDefaults()
        if let until = defaults.object(forKey: Prefs.pausedUntil) as? Date, until > Date() { schedulePause(until) }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.hardwareChanged() }
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var a = CoreAudioHAL.address(sel)
            AudioObjectAddPropertyListenerBlock(CoreAudioHAL.system, &a, .main, block)
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
            self?.scheduleEnforce(delay: 0.05)
        }
        hardwareChanged()
    }

    // MARK: - State

    var isEnabled: Bool { defaults.bool(forKey: Prefs.enabled) }
    var isPaused: Bool { (pausedUntil ?? .distantPast) > Date() }
    var isActive: Bool { isEnabled && !isPaused }
    var defaultCeiling: Double { defaults.double(forKey: Prefs.defaultCeiling) }
    var activeDevice: AudioDevice? { devices.first { $0.id == defaultID } }
    var isLocked: Bool { defaults.bool(forKey: Prefs.lockSettings) && (unlockedUntil ?? .distantPast) < Date() }

    private var ceilingMap: [String: Double] { defaults.dictionary(forKey: Prefs.ceilings) as? [String: Double] ?? [:] }
    private var lastVolumes: [String: Double] { defaults.dictionary(forKey: Prefs.lastVolumes) as? [String: Double] ?? [:] }

    func ceiling(for uid: String) -> Double { ceilingMap[uid] ?? defaultCeiling }
    func hasCustomCeiling(_ uid: String) -> Bool { ceilingMap[uid] != nil }

    func setCeiling(_ value: Double?, for uid: String) {
        var map = ceilingMap
        map[uid] = value.map { min(max($0, 0.05), 1) }
        defaults.set(map, forKey: Prefs.ceilings)
    }

    /// Every device except the active one: connected first, then remembered ones.
    var otherEntries: [DeviceEntry] {
        let connected = devices.filter { $0.id != defaultID }.map { DeviceEntry(uid: $0.uid, name: $0.name, device: $0) }
        let liveUIDs = Set(devices.map(\.uid))
        let names = defaults.dictionary(forKey: Prefs.names) as? [String: String] ?? [:]
        let remembered = names.filter { !liveUIDs.contains($0.key) }
            .map { DeviceEntry(uid: $0.key, name: $0.value, device: nil) }
            .sorted { $0.name < $1.name }
        return connected + remembered
    }

    /// Sets 60% on every connected or remembered device that looks like headphones.
    func applySafePreset() {
        for d in devices where d.isHeadphones { setCeiling(0.6, for: d.uid) }
        let names = defaults.dictionary(forKey: Prefs.names) as? [String: String] ?? [:]
        for (uid, name) in names where CoreAudioHAL.isHeadphoneName(name) { setCeiling(0.6, for: uid) }
    }

    // MARK: - Pause / lock

    func pauseForOneHour() { schedulePause(Date().addingTimeInterval(3600)) }

    func resume() {
        resumeTimer?.invalidate()
        pausedUntil = nil
        defaults.removeObject(forKey: Prefs.pausedUntil)
        enforceActive(onConnect: false)
    }

    private func schedulePause(_ until: Date) {
        pausedUntil = until
        defaults.set(until, forKey: Prefs.pausedUntil)
        resumeTimer?.invalidate()
        resumeTimer = Timer.scheduledTimer(withTimeInterval: max(until.timeIntervalSinceNow, 1), repeats: false) { [weak self] _ in
            self?.resume()
        }
    }

    /// Asks for an explicit confirmation click before allowing edits for five minutes.
    func requestUnlock() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Unlock VolumeCeiling settings?"
        alert.informativeText = "Volume limits are locked. Unlock editing for the next 5 minutes?"
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { unlockedUntil = Date().addingTimeInterval(300) }
    }

    // MARK: - CoreAudio events

    private func hardwareChanged() {
        let previous = Set(devices.map(\.uid))
        devices = CoreAudioHAL.outputDevices()
        let storedNames = defaults.dictionary(forKey: Prefs.names) as? [String: String] ?? [:]
        var names = storedNames
        for d in devices { names[d.uid] = d.name }
        if names != storedNames { defaults.set(names, forKey: Prefs.names) }

        let newDefault = CoreAudioHAL.defaultOutputID()
        let defaultChanged = newDefault != watchedID
        defaultID = newDefault
        if defaultChanged { watchVolume(of: newDefault) }
        currentVolume = activeDevice.flatMap(CoreAudioHAL.volume)

        guard defaults.bool(forKey: Prefs.clampOnConnect) else { return }
        // One-time clamp for newly connected devices and the newly active device.
        for d in devices where !previous.contains(d.uid) || (defaultChanged && d.id == newDefault) {
            enforce(d, onConnect: true)
        }
    }

    private func watchVolume(of id: AudioDeviceID) {
        if let block = volumeBlock, watchedID != 0 {
            for addr in volumeAddresses {
                var a = addr
                AudioObjectRemovePropertyListenerBlock(watchedID, &a, .main, block)
            }
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.volumeChanged() }
        for addr in volumeAddresses {
            var a = addr
            AudioObjectAddPropertyListenerBlock(id, &a, .main, block)
        }
        volumeBlock = block
        watchedID = id
    }

    private func volumeChanged() {
        currentVolume = activeDevice.flatMap(CoreAudioHAL.volume)
        // Our own writes echo back here; wait them out, and coalesce key-repeat bursts.
        scheduleEnforce(delay: isWriting ? 0.06 : 0.015)
    }

    private func scheduleEnforce(delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.enforceActive(onConnect: false) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func enforceActive(onConnect: Bool) {
        if let d = activeDevice { enforce(d, onConnect: onConnect) }
        currentVolume = activeDevice.flatMap(CoreAudioHAL.volume)
    }

    private func enforce(_ device: AudioDevice, onConnect: Bool) {
        guard isActive, !isWriting, device.isSupported, let volume = CoreAudioHAL.volume(of: device) else { return }
        let limit = ceiling(for: device.uid)
        guard volume > limit + 0.005 else {
            var last = lastVolumes
            if abs((last[device.uid] ?? -1) - volume) > 0.001 {
                last[device.uid] = volume
                defaults.set(last, forKey: Prefs.lastVolumes)
            }
            return
        }
        // On reconnect, return to the last volume we saw (never above the ceiling).
        let target = onConnect ? min(limit, lastVolumes[device.uid] ?? limit) : limit
        isWriting = true
        let changed = CoreAudioHAL.clamp(device, to: target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.isWriting = false }
        if changed { notifyIntervention(device, limit: limit) }
    }

    private func notifyIntervention(_ device: AudioDevice, limit: Double) {
        guard defaults.bool(forKey: Prefs.notifications) else { return }
        if let last = lastNotified[device.uid], Date().timeIntervalSince(last) < 30 { return }
        lastNotified[device.uid] = Date()
        Notifier.post(title: "Volume limited", body: "\(device.name) was lowered to its \(Int(limit * 100))% ceiling.")
    }
}
