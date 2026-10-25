import Foundation
import Observation
import RemoteCodeKit
import SwiftUI

/// Launch arguments used by UI tests and screenshot automation.
struct LaunchOptions {
    /// `-UITesting`: in-memory storage, fresh preferences, no animations.
    var isUITesting: Bool
    /// `-DemoMode`: start directly in demo mode.
    var forceDemo: Bool
    /// `-DemoPace <x>`: scales scripted delays of the demo Mac.
    var demoPace: Double

    static var current: LaunchOptions {
        let arguments = ProcessInfo.processInfo.arguments
        let defaults = UserDefaults.standard
        return LaunchOptions(
            isUITesting: arguments.contains("-UITesting"),
            forceDemo: arguments.contains("-DemoMode"),
            demoPace: defaults.object(forKey: "DemoPace") as? Double ?? 1
        )
    }
}

/// Root state of the iOS app.
@MainActor
@Observable
final class AppModel {
    let launch: LaunchOptions
    let preferences: UserPreferences
    let store: PairedMacStore
    let cache: TranscriptCache
    private(set) var connection: MacConnection?
    private(set) var identityError: String?
    var selectedSessionId: String?
    var isPresentingNewChat = false
    var isPresentingSettings = false
    var isPresentingInsights = false
    var isPresentingPairing = false
    /// A `pilothouse://pair` link opened from outside (Camera app, paste).
    var incomingPairingLink: String?

    @ObservationIgnored private let identityStore: any IdentityStore
    @ObservationIgnored private var identity: IdentityKeyPair?
    @ObservationIgnored private let bonjour = BonjourBrowser()
    @ObservationIgnored private var demoConnector: DemoConnector?

    init(launch: LaunchOptions = .current) {
        self.launch = launch
        let defaults: UserDefaults
        if launch.isUITesting, let testing = UserDefaults(suiteName: "RemoteCodeUITests") {
            testing.removePersistentDomain(forName: "RemoteCodeUITests")
            defaults = testing
        } else {
            defaults = .standard
        }
        preferences = UserPreferences(defaults: defaults)
        store = PairedMacStore(inMemory: launch.isUITesting)
        cache = TranscriptCache(inMemory: launch.isUITesting)
        identityStore = launch.isUITesting
            ? InMemoryIdentityStore()
            : KeychainIdentityStore(service: "com.ardasenturk.Pilothouse.identity")
        if launch.forceDemo { preferences.demoMode = true }
        do {
            identity = try identityStore.loadOrCreateIdentity()
        } catch {
            identityError = String(localized: "Remote Code could not access the Keychain: \(error.localizedDescription)")
        }
    }

    var hasPairedMac: Bool { !store.macs.isEmpty || preferences.demoMode }

    var activeMac: PairedMac? { connection?.mac }

    // MARK: Connection

    /// Connects to the active Mac (or the demo Mac).
    func connect() {
        guard connection == nil, let identity else { return }
        if preferences.demoMode {
            let connector = demoConnector ?? DemoConnector(pace: launch.demoPace)
            demoConnector = connector
            connection = MacConnection(
                mac: connector.mac, identity: identity, connector: connector, preference: .automatic,
                bonjour: nil, cache: cache, store: store
            )
        } else {
            guard let mac = store.mac(id: preferences.activeMacId ?? "") ?? store.macs.first else { return }
            preferences.activeMacId = mac.id
            bonjour.start()
            connection = MacConnection(
                mac: mac, identity: identity, connector: NetworkTransportConnector(),
                preference: preferences.connectionPreference, bonjour: bonjour, cache: cache, store: store
            )
        }
        connection?.start()
    }

    func disconnect() async {
        await connection?.stop()
        connection = nil
        selectedSessionId = nil
    }

    func switchToMac(_ id: String) async {
        await disconnect()
        preferences.demoMode = false
        preferences.activeMacId = id
        connect()
    }

    func setDemoMode(_ enabled: Bool) async {
        await disconnect()
        preferences.demoMode = enabled
        if !enabled { demoConnector = nil }
        connect()
    }

    /// Opens the session of a `pilothouse://session/<id>` link (a tapped
    /// notification, D-095), switching to the link's Mac if it is paired.
    func open(_ link: SessionLink) async {
        guard hasPairedMac else { return }
        isPresentingNewChat = false
        isPresentingSettings = false
        if let macId = link.macId, macId != activeMac?.id, store.mac(id: macId) != nil {
            await switchToMac(macId)
        }
        selectedSessionId = link.sessionId
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if connection == nil { connect() }
            if !preferences.demoMode { bonjour.start() }
            connection?.appBecameActive()
        case .background:
            connection?.appWentToBackground()
            bonjour.stop()
        default:
            break
        }
    }

    // MARK: Pairing

    /// Pairs with the Mac in `link` and makes it the active Mac.
    func pair(link: String) async throws -> PairedMac {
        guard let identity else {
            throw ErrorPayload(code: .internalError, message: identityError ?? "Keychain unavailable")
        }
        let payload = try PairingPayload(link: link)
        // Pairing is usually the first LAN access, so iOS may show the Local
        // Network alert during it: wait for the answer instead of failing.
        let mac = try await MacClient.pair(
            payload: payload, identity: identity, device: DeviceDescription.current,
            connector: NetworkTransportConnector(localNetworkGrace: 30)
        )
        store.upsert(mac)
        await switchToMac(mac.id)
        return mac
    }

    /// Browsing for Macs makes iOS ask for Local Network access now, before
    /// the first connection attempt depends on the answer.
    func requestLocalNetworkAccess() {
        guard !preferences.demoMode else { return }
        bonjour.start()
    }

    func unpair(_ mac: PairedMac) async {
        if activeMac?.id == mac.id { await disconnect() }
        store.remove(mac.id)
        for session in cache.sessions(macId: mac.id) { cache.deleteSession(session.id) }
        if preferences.activeMacId == mac.id { preferences.activeMacId = store.macs.first?.id }
        connect()
    }

    /// Verification code of a Mac's key, to compare with the Mac's pairing window.
    func verificationCode(for mac: PairedMac) -> String {
        KeyFingerprint.displayCode(for: mac.publicKey)
    }

    func clearCache() {
        cache.clearAll()
    }

    /// UI tests only: cut the demo connection to exercise reconnection.
    func simulateNetworkDrop() async {
        await demoConnector?.simulateNetworkDrop()
    }
}
