import Foundation
import Observation
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.pauseLidModeOnBattery: true,
            Key.retentionDays: 30,
            Key.preferredPort: PilothouseProtocol.defaultPort,
            Key.defaultPermissionMode: PermissionMode.default.rawValue,
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
    }

    /// Model aliases offered in pickers (free text is accepted too).
    static let modelSuggestions = ["", "fable", "opus", "sonnet", "haiku"]
}
