import PilothouseKit
import SwiftUI

enum WindowID {
    static let pairing = "pairing"
    static let claudeSetup = "claude-setup"
    static let tailscale = "tailscale"
}

/// Menu-bar-only app (`LSUIElement`), distributed outside the Mac App Store.
@main
struct PilothouseMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(appDelegate.controller)
        } label: {
            MenuBarLabel(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)

        Window(Text("Pair a Device"), id: WindowID.pairing) {
            PairingView()
                .environment(appDelegate.controller)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window(Text("Claude Code"), id: WindowID.claudeSetup) {
            ClaudeSetupView()
                .environment(appDelegate.controller)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window(Text("Tailscale"), id: WindowID.tailscale) {
            TailscaleAssistantView()
                .environment(appDelegate.controller)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(appDelegate.controller)
        }
    }
}

/// The status-bar icon: the helm glyph, with a dot while Claude waits for approval.
struct MenuBarLabel: View {
    let controller: AppController

    var body: some View {
        switch controller.phase {
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .accessibilityLabel(Text("Pilothouse needs attention"))
        default:
            Image(controller.pendingPermissionCount > 0 ? "MenuBarIconBadge" : "MenuBarIcon")
                .accessibilityLabel(Text("Pilothouse"))
        }
    }
}
