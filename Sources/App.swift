import AppKit
import SwiftUI

/// Entry point: a menu bar extra plus a Settings window.
@main
struct VolumeCeilingApp: App {
    @StateObject private var limiter = Limiter()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(limiter)
        } label: {
            MenuBarLabel().environmentObject(limiter)
        }
        .menuBarExtraStyle(.window)

        Window("VolumeCeiling Settings", id: "settings") {
            SettingsView().environmentObject(limiter)
        }
        .windowResizability(.contentSize)
    }
}

/// Menu bar indicator: state icon, short device name and its ceiling.
struct MenuBarLabel: View {
    @EnvironmentObject var limiter: Limiter

    var body: some View {
        let icon = !limiter.isEnabled ? "speaker.slash" : limiter.isPaused ? "pause.circle" : "speaker.wave.2"
        if let d = limiter.activeDevice, d.isSupported {
            Label("\(String(d.name.prefix(14))) \(Int(limiter.ceiling(for: d.uid) * 100))%", systemImage: icon)
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: icon)
        }
    }
}

/// Opens the donation page.
enum Support {
    static func open() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
    }
}
