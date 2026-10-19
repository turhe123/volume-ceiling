import SwiftUI

/// The MenuBarExtra window: active device, other devices, and footer actions.
struct MenuView: View {
    @EnvironmentObject var limiter: Limiter
    @AppStorage(Prefs.enabled) private var enabled = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("VolumeCeiling").font(.headline)
                StatusPill()
                Spacer()
                Toggle("Limiter", isOn: $enabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .disabled(limiter.isLocked)
            }

            if !limiter.devices.contains(where: \.isSupported) {
                Label("No output device with software volume was found. Some digital outputs (HDMI, DisplayPort, certain USB DACs) "
                      + "control volume in hardware and cannot be limited by software.", systemImage: "speaker.badge.exclamationmark")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if let device = limiter.activeDevice {
                ActiveDeviceCard(device: device)
            }

            if limiter.isLocked {
                Button { limiter.requestUnlock() } label: { Label("Settings locked — Unlock…", systemImage: "lock.fill") }
            }

            let others = limiter.otherEntries
            if !others.isEmpty {
                Text("Other devices").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(others) { DeviceRow(entry: $0) }
                    }
                }
                .frame(maxHeight: 190)
            }

            Text("Limits are enforced in software; brief spikes within the callback latency may occur.")
                .font(.caption2).foregroundStyle(.tertiary)

            Divider()
            HStack {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                }
                if limiter.isPaused {
                    Button("Resume") { limiter.resume() }
                } else {
                    Button("Pause 1 hour") { limiter.pauseForOneHour() }.disabled(!enabled || limiter.isLocked)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            Button { Support.open() } label: { Text("Support / Donate ❤️").frame(maxWidth: .infinity) }
        }
        .padding(14)
        .frame(width: 340)
    }
}

/// Small coloured badge showing Active / Paused / Off.
struct StatusPill: View {
    @EnvironmentObject var limiter: Limiter

    var body: some View {
        let (text, color): (String, Color) = !limiter.isEnabled ? ("Off", .gray)
            : limiter.isPaused ? ("Paused", .orange) : ("Active", .green)
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule()).foregroundStyle(color)
    }
}

/// The current default output with its live volume and ceiling slider.
struct ActiveDeviceCard: View {
    @EnvironmentObject var limiter: Limiter
    let device: AudioDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: device.isHeadphones ? "headphones" : "hifispeaker")
                Text(device.name).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                if let v = limiter.currentVolume { Text("Now \(Int(v * 100))%").monospacedDigit().foregroundStyle(.secondary) }
            }
            if device.isSupported {
                CeilingSlider(uid: device.uid, marker: limiter.currentVolume)
            } else {
                Text("No software volume control — this output can't be limited.").font(.caption).foregroundStyle(.secondary)
            }
            if limiter.isPaused, let until = limiter.pausedUntil {
                Text("Paused until \(until.formatted(date: .omitted, time: .shortened)); changes apply on resume.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A non-active device (connected or remembered) with its own slider and reset button.
struct DeviceRow: View {
    @EnvironmentObject var limiter: Limiter
    let entry: DeviceEntry

    var body: some View {
        let unsupported = entry.device.map { !$0.isSupported } ?? false
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.name).lineLimit(1)
                Spacer()
                if entry.device == nil { Text("Not connected").font(.caption2).foregroundStyle(.secondary) }
                Button { limiter.setCeiling(nil, for: entry.uid) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless).help("Reset to default ceiling")
                    .disabled(!limiter.hasCustomCeiling(entry.uid) || limiter.isLocked)
            }
            if unsupported {
                Text("Unsupported: no software volume control").font(.caption).foregroundStyle(.secondary)
            } else {
                CeilingSlider(uid: entry.uid, marker: nil)
            }
        }
        .opacity(unsupported || entry.device == nil ? 0.55 : 1)
    }
}

/// Ceiling slider with a tick marking the live volume.
struct CeilingSlider: View {
    @EnvironmentObject var limiter: Limiter
    let uid: String
    let marker: Double?

    var body: some View {
        let binding = Binding(get: { limiter.ceiling(for: uid) }, set: { limiter.setCeiling($0, for: uid) })
        HStack {
            Slider(value: binding, in: 0.05...1)
                .overlay(alignment: .leading) {
                    if let marker {
                        GeometryReader { geo in
                            Rectangle().fill(.secondary).frame(width: 2, height: 8)
                                .offset(x: 8 + (geo.size.width - 16) * min(marker, 1) - 1, y: -6)
                                .help("Current volume")
                        }
                        .allowsHitTesting(false)
                    }
                }
            Text("\(Int(binding.wrappedValue * 100))%").monospacedDigit().frame(width: 38, alignment: .trailing)
        }
        .disabled(limiter.isLocked)
    }
}
