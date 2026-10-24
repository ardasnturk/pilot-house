import Foundation
import PilothouseKit

extension SessionState {
    var localizedName: String {
        switch self {
        case .starting: String(localized: "Starting")
        case .running: String(localized: "Working")
        case .awaitingPermission: String(localized: "Waiting for approval")
        case .idle: String(localized: "Idle")
        case .closed: String(localized: "Closed")
        }
    }
}

extension PermissionMode {
    var localizedName: String {
        switch self {
        case .default: String(localized: "Ask every time")
        case .acceptEdits: String(localized: "Accept edits")
        case .plan: String(localized: "Plan only")
        case .bypassPermissions: String(localized: "Bypass permissions")
        }
    }
}

enum AppInfo {
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    static let repositoryURL = URL(string: "https://github.com/ardasnturk/pilot-house")
    static let claudeCodeSetupURL = URL(string: "https://docs.claude.com/en/docs/claude-code/setup")
    static let tailscaleDownloadURL = URL(string: "https://tailscale.com/download/mac")
}

extension String {
    /// `~`-relative form of an absolute path inside the home folder.
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        guard hasPrefix(home) else { return self }
        let rest = dropFirst(home.count)
        return rest.isEmpty ? "~" : "~\(rest)"
    }
}
