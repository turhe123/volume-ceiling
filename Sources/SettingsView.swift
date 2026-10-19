import ServiceManagement
import SwiftUI
import UserNotifications

/// Settings window: defaults, Safe preset, notifications, connect clamp, login item, and lock.
struct SettingsView: View {
    @EnvironmentObject var limiter: Limiter
    @AppStorage(Prefs.defaultCeiling) private var defaultCeiling = 0.8
    @AppStorage(Prefs.notifications) private var notifications = false
    @AppStorage(Prefs.clampOnConnect) private var clampOnConnect = true
    @AppStorage(Prefs.lockSettings) private var lockSettings = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var notificationsDenied = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                if limiter.isLocked {
                    Button { limiter.requestUnlock() } label: { Label("Settings are locked — Unlock…", systemImage: "lock.fill") }
                }
                HStack {
                    Slider(value: $defaultCeiling, in: 0.05...1) { Text("Default ceiling") }
                    Text("\(Int(defaultCeiling * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Text("Used for any device without its own ceiling.").font(.caption).foregroundStyle(.secondary)
                Button("Apply Safe preset (60%) to headphones") {
                    limiter.applySafePreset()
                    message = "Safe preset applied to headphone-type devices."
                }
            }
            .disabled(limiter.isLocked)

            Section {
                Toggle("Show notifications when the limiter intervenes", isOn: $notifications)
                    .onChange(of: notifications) { _, on in
                        guard on else { return }
                        Notifier.requestAuthorization { granted in
                            notificationsDenied = !granted
                            if !granted { notifications = false }
                        }
                    }
                if notificationsDenied {
                    HStack {
                        Text("Notifications are blocked. Allow them in System Settings › Notifications.")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Open") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                Toggle("Clamp volume when a device connects", isOn: $clampOnConnect)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                Toggle("Lock settings (require a confirmation click to change)", isOn: $lockSettings)
            }
            .disabled(limiter.isLocked)

            Section {
                Text("VolumeCeiling enforces limits in software by lowering the volume right after it rises. "
                     + "Brief spikes within the callback latency may occur, and outputs without software volume cannot be limited.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.caption).foregroundStyle(.green) }
                Button { Support.open() } label: { Text("Support / Donate ❤️") }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                DispatchQueue.main.async { notificationsDenied = settings.authorizationStatus == .denied }
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        guard on != (service.status == .enabled) else { return }
        do {
            if on { try service.register() } else { try service.unregister() }
            message = nil
        } catch {
            message = "Couldn't update login item: \(error.localizedDescription)"
            launchAtLogin = service.status == .enabled
        }
    }
}
