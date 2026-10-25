import Foundation
import ServiceManagement

/// "Open at login" via `SMAppService.mainApp` (prompt §4.1).
enum LaunchAtLogin {
    /// Registered, including when macOS still waits for the user's approval.
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: true
        default: false
        }
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            // A stale record can report `.enabled` while the Mac no longer
            // opens the app; registering again repairs it.
            if SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
            }
            try SMAppService.mainApp.register()
        } else {
            guard isEnabled else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
