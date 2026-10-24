import Foundation
import PilothouseKit
import SwiftUI

extension SessionState {
    var localizedName: LocalizedStringKey {
        switch self {
        case .starting: "Starting"
        case .running: "Working"
        case .awaitingPermission: "Needs approval"
        case .idle: "Ready"
        case .closed: "Closed"
        }
    }
}

extension PermissionMode {
    var localizedName: LocalizedStringKey {
        switch self {
        case .default: "Ask every time"
        case .acceptEdits: "Accept edits"
        case .plan: "Plan only"
        case .bypassPermissions: "Bypass permissions"
        }
    }

    var localizedDescription: LocalizedStringKey {
        switch self {
        case .default: "Claude asks before editing files or running commands."
        case .acceptEdits: "File edits are applied automatically; commands still need approval."
        case .plan: "Claude only reads and plans; it does not change anything."
        case .bypassPermissions: "Claude edits and runs commands without asking. Use with care."
        }
    }

    var symbol: String {
        switch self {
        case .default: "hand.raised"
        case .acceptEdits: "pencil.line"
        case .plan: "list.bullet.clipboard"
        case .bypassPermissions: "exclamationmark.shield"
        }
    }
}

extension ConnectionRoute {
    var localizedName: LocalizedStringKey {
        switch self {
        case .local: "Local network"
        case .tailscale: "Tailscale"
        case .demo: "Demo"
        }
    }
}

extension String {
    /// Path relative to `base` if it is inside it, otherwise unchanged.
    func relativePath(to base: String) -> String {
        guard hasPrefix(base + "/") else { return self }
        return String(dropFirst(base.count + 1))
    }

    /// `~`-relative path given the Mac's home folder.
    func abbreviatingHome(_ home: String?) -> String {
        guard let home, hasPrefix(home) else { return self }
        let rest = dropFirst(home.count)
        return rest.isEmpty ? "~" : "~\(rest)"
    }

    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }
}

extension Int {
    /// `1.2 s`, `3 min 4 s`.
    var formattedDuration: String {
        Duration.milliseconds(self).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated, fractionalPart: .show(length: 1)))
    }
}

/// Brand colours.
extension Color {
    static let brandTeal = Color("AccentColor")
}

/// Display names of `AgentKind.effortLevels` values.
enum EffortLevel {
    static func localizedName(_ raw: String) -> LocalizedStringKey {
        switch raw {
        case "low": LocalizedStringKey("Low")
        case "medium": LocalizedStringKey("Medium")
        case "high": LocalizedStringKey("High")
        case "xhigh": LocalizedStringKey("Extra high")
        case "max": LocalizedStringKey("Max")
        case "ultra": LocalizedStringKey("Ultra")
        case "minimal": LocalizedStringKey("Minimal")
        case "none": LocalizedStringKey("None")
        default: LocalizedStringKey(stringLiteral: raw)
        }
    }
}

extension ModelOption {
    /// A pinned, dated model (`claude-opus-4-8`) rather than an alias that
    /// follows the newest one (`opus`); listed under "Earlier models".
    var isOlder: Bool {
        id.hasPrefix("claude-") && !isDefault
    }
}
