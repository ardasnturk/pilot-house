import Foundation
import Observation
import PilothouseHost
import PilothouseKit

/// User preferences of the Mac app, persisted in `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let keepAwakeWithLidClosed = "keepAwakeWithLidClosed"
        static let pauseLidModeOnBattery = "pauseLidModeOnBattery"
        static let retentionDays = "retentionDays"
        static let allowBypassPermissions = "allowBypassPermissions"
        static let defaultModel = "defaultModel"
        static let defaultPermissionMode = "defaultPermissionMode"
        static let useAPIKey = "useAPIKey"
        static let preferredPort = "preferredPort"
        static let didShowWelcome = "didShowWelcome"
        static let notificationsEnabled = "notificationsEnabled"
        static let notifyOnMac = "notifyOnMac"
        static let notifyViaNtfy = "notifyViaNtfy"
        static let notificationKinds = "notificationKinds"
        static let notificationIncludesSummary = "notificationIncludesSummary"
        static let ntfyServer = "ntfyServer"
        static let ntfyTopic = "ntfyTopic"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Optional "stay awake with the lid closed" mode (needs the privileged helper).
    var keepAwakeWithLidClosed: Bool {
        didSet { defaults.set(keepAwakeWithLidClosed, forKey: Key.keepAwakeWithLidClosed) }
    }

    /// Suspend the lid-closed mode while running on battery (default on).
    var pauseLidModeOnBattery: Bool {
        didSet { defaults.set(pauseLidModeOnBattery, forKey: Key.pauseLidModeOnBattery) }
    }

    /// Session logs untouched for longer are deleted.
    var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
    }

    /// Lets phones start sessions in `bypassPermissions` mode.
    var allowBypassPermissions: Bool {
        didSet { defaults.set(allowBypassPermissions, forKey: Key.allowBypassPermissions) }
    }

    /// Model alias or ID passed as `--model`; empty = Claude Code's default.
    var defaultModel: String {
        didSet { defaults.set(defaultModel, forKey: Key.defaultModel) }
    }

    var defaultPermissionMode: PermissionMode {
        didSet { defaults.set(defaultPermissionMode.rawValue, forKey: Key.defaultPermissionMode) }
    }

    /// Pass the Keychain-stored API key as `ANTHROPIC_API_KEY` instead of the CLI's own login.
    var useAPIKey: Bool {
        didSet { defaults.set(useAPIKey, forKey: Key.useAPIKey) }
    }

    var preferredPort: Int {
        didSet { defaults.set(preferredPort, forKey: Key.preferredPort) }
    }

    var didShowWelcome: Bool {
        didSet { defaults.set(didShowWelcome, forKey: Key.didShowWelcome) }
    }

    /// Master switch for notifications (D-095); off by default.
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    /// Native notifications on this Mac.
    var notifyOnMac: Bool {
        didSet { defaults.set(notifyOnMac, forKey: Key.notifyOnMac) }
    }

    /// Publish to the ntfy topic (sends data to the ntfy server).
    var notifyViaNtfy: Bool {
        didSet { defaults.set(notifyViaNtfy, forKey: Key.notifyViaNtfy) }
    }

    var notificationKinds: Set<HostAlert.Kind> {
        didSet { defaults.set(notificationKinds.map(\.rawValue).sorted(), forKey: Key.notificationKinds) }
    }

    /// Adds the last message, tool or error to notifications (off = "Task finished · folder" only).
    var notificationIncludesSummary: Bool {
        didSet { defaults.set(notificationIncludesSummary, forKey: Key.notificationIncludesSummary) }
    }

    var ntfyServer: String {
        didSet { defaults.set(ntfyServer, forKey: Key.ntfyServer) }
    }

    /// Random topic generated on first launch; acts as a password on public servers.
    var ntfyTopic: String {
        didSet { defaults.set(ntfyTopic, forKey: Key.ntfyTopic) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.pauseLidModeOnBattery: true,
            Key.retentionDays: 30,
            Key.preferredPort: PilothouseProtocol.defaultPort,
            Key.defaultPermissionMode: PermissionMode.default.rawValue,
            Key.notifyOnMac: true,
            Key.ntfyServer: NtfyConfiguration.defaultServer,
            Key.notificationKinds: AppSettings.notificationKindsInSettings.map(\.rawValue),
        ])
        keepAwakeWithLidClosed = defaults.bool(forKey: Key.keepAwakeWithLidClosed)
        pauseLidModeOnBattery = defaults.bool(forKey: Key.pauseLidModeOnBattery)
        retentionDays = max(1, defaults.integer(forKey: Key.retentionDays))
        allowBypassPermissions = defaults.bool(forKey: Key.allowBypassPermissions)
        defaultModel = defaults.string(forKey: Key.defaultModel) ?? ""
        defaultPermissionMode = PermissionMode(rawValue: defaults.string(forKey: Key.defaultPermissionMode) ?? "") ?? .default
        useAPIKey = defaults.bool(forKey: Key.useAPIKey)
        preferredPort = defaults.integer(forKey: Key.preferredPort)
        didShowWelcome = defaults.bool(forKey: Key.didShowWelcome)
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        notifyOnMac = defaults.bool(forKey: Key.notifyOnMac)
        notifyViaNtfy = defaults.bool(forKey: Key.notifyViaNtfy)
        notificationKinds = Set((defaults.stringArray(forKey: Key.notificationKinds) ?? []).compactMap(HostAlert.Kind.init(rawValue:)))
        notificationIncludesSummary = defaults.bool(forKey: Key.notificationIncludesSummary)
        ntfyServer = defaults.string(forKey: Key.ntfyServer) ?? NtfyConfiguration.defaultServer
        if let topic = defaults.string(forKey: Key.ntfyTopic), NtfyConfiguration.isValidTopic(topic) {
            ntfyTopic = topic
        } else {
            ntfyTopic = NtfyConfiguration.randomTopic()
            defaults.set(ntfyTopic, forKey: Key.ntfyTopic)
        }
    }

    /// Events offered in Settings. `.subagentFinished` joins once sub-agent
    /// tracking posts it.
    static let notificationKindsInSettings: [HostAlert.Kind] = [.turnFinished, .permissionRequested, .sessionFailed]

    /// Model aliases offered in pickers (free text is accepted too).
    static let modelSuggestions = ["", "fable", "opus", "sonnet", "haiku"]
}
