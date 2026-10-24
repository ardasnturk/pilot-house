import Foundation
import Observation
import PilothouseKit

/// Persists paired Macs (public data only: name, public key, addresses) in
/// Application Support with complete file protection until first unlock.
@MainActor
@Observable
final class PairedMacStore {
    private(set) var macs: [PairedMac] = []
    @ObservationIgnored private let url: URL?

    init(inMemory: Bool) {
        if inMemory {
            url = nil
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            url = support?.appendingPathComponent("paired-macs.json")
            if let url, let data = try? Data(contentsOf: url), let decoded = try? PilothouseJSON.decode([PairedMac].self, from: data) {
                macs = decoded
            }
        }
    }

    func mac(id: String) -> PairedMac? {
        macs.first { $0.id == id }
    }

    func upsert(_ mac: PairedMac) {
        if let index = macs.firstIndex(where: { $0.id == mac.id }) {
            macs[index] = mac
        } else {
            macs.append(mac)
        }
        save()
    }

    func remove(_ id: String) {
        macs.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PilothouseJSON.encode(macs)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            PilothouseLog("PairedMacStore").error("Could not save paired Macs: \(error)")
        }
    }
}

/// User preferences of the iOS app.
@MainActor
@Observable
final class UserPreferences {
    enum Appearance: String, CaseIterable {
        case system
        case light
        case dark
    }

    private enum Key {
        static let activeMacId = "activeMacId"
        static let connectionPreference = "connectionPreference"
        static let tailscaleOptIn = "tailscaleOptIn"
        static let defaultModel = "defaultModel"
        static let defaultEffort = "defaultEffort"
        static let defaultPermissionMode = "defaultPermissionMode"
        static let appearance = "appearance"
        static let hapticsEnabled = "hapticsEnabled"
        static let demoMode = "demoMode"
        static let favoriteFolders = "favoriteFolders"
        static let recentFolders = "recentFolders"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var activeMacId: String? { didSet { defaults.set(activeMacId, forKey: Key.activeMacId) } }
    var connectionPreference: ConnectionPreference {
        didSet {
            defaults.set(connectionPreference.rawValue, forKey: Key.connectionPreference)
            defaults.set(connectionPreference != .localOnly, forKey: Key.tailscaleOptIn)
        }
    }
    /// "Use Tailscale when away": the local network first, Tailscale only when the Mac is not there.
    var usesTailscale: Bool {
        get { connectionPreference != .localOnly }
        set { connectionPreference = newValue ? .automatic : .localOnly }
    }
    var defaultModel: String { didSet { defaults.set(defaultModel, forKey: Key.defaultModel) } }
    /// Effort for new chats (`""` = the agent's default); used when the agent supports it.
    var defaultEffort: String { didSet { defaults.set(defaultEffort, forKey: Key.defaultEffort) } }
    var defaultPermissionMode: PermissionMode { didSet { defaults.set(defaultPermissionMode.rawValue, forKey: Key.defaultPermissionMode) } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled) } }
    var demoMode: Bool { didSet { defaults.set(demoMode, forKey: Key.demoMode) } }
    var favoriteFolders: [String] { didSet { defaults.set(favoriteFolders, forKey: Key.favoriteFolders) } }
    var recentFolders: [String] { didSet { defaults.set(recentFolders, forKey: Key.recentFolders) } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        defaults.register(defaults: [Key.hapticsEnabled: true])
        activeMacId = defaults.string(forKey: Key.activeMacId)
        // Tailscale is opt-in (D-103). 1.0 defaulted to `automatic`; keep it only
        // for someone who chose Tailscale explicitly.
        let storedPreference = ConnectionPreference(rawValue: defaults.string(forKey: Key.connectionPreference) ?? "")
        connectionPreference = defaults.bool(forKey: Key.tailscaleOptIn) || storedPreference == .tailscaleOnly ? .automatic : .localOnly
        defaultModel = defaults.string(forKey: Key.defaultModel) ?? ""
        defaultEffort = defaults.string(forKey: Key.defaultEffort) ?? ""
        defaultPermissionMode = PermissionMode(rawValue: defaults.string(forKey: Key.defaultPermissionMode) ?? "") ?? .default
        appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        hapticsEnabled = defaults.bool(forKey: Key.hapticsEnabled)
        demoMode = defaults.bool(forKey: Key.demoMode)
        favoriteFolders = defaults.stringArray(forKey: Key.favoriteFolders) ?? []
        recentFolders = defaults.stringArray(forKey: Key.recentFolders) ?? []
    }

    func toggleFavorite(_ path: String) {
        if let index = favoriteFolders.firstIndex(of: path) {
            favoriteFolders.remove(at: index)
        } else {
            favoriteFolders.append(path)
        }
    }

    func noteRecent(_ path: String) {
        var recents = recentFolders.filter { $0 != path }
        recents.insert(path, at: 0)
        recentFolders = Array(recents.prefix(8))
    }

    static let modelSuggestions = ["", "fable", "opus", "sonnet", "haiku"]
}
