import Foundation
import Network
import Observation
import PilothouseKit
import UIKit

/// Live state of the connection to one Mac: sessions, transcripts, pending
/// permission requests. Wraps the `MacClient` actor for SwiftUI.
@MainActor
@Observable
final class MacConnection {
    private(set) var mac: PairedMac
    private(set) var state: MacConnectionState = .idle
    private(set) var status: MacStatus?
    private(set) var sessions: [SessionSummary] = []
    private(set) var pendingPermissions: [PermissionRequest] = []
    /// Set when the app returns to the foreground while sessions were busy.
    var resumedWhileAwayNotice: String?

    @ObservationIgnored let client: MacClient
    @ObservationIgnored private var chats: [String: ChatState] = [:]
    @ObservationIgnored private var subscribed: Set<String> = []
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let cache: TranscriptCache
    @ObservationIgnored private let store: PairedMacStore
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var wasBusyWhenBackgrounded = false

    init(
        mac: PairedMac,
        identity: IdentityKeyPair,
        connector: any TransportConnector,
        preference: ConnectionPreference,
        bonjour: BonjourBrowser?,
        cache: TranscriptCache,
        store: PairedMacStore
    ) {
        self.mac = mac
        self.cache = cache
        self.store = store
        let macId = mac.id
        client = MacClient(
            mac: mac,
            identity: identity,
            device: DeviceDescription.current,
            connector: connector,
            preference: preference,
            bonjourEndpoints: { bonjour?.endpoints(matching: macId) ?? [] },
            onMacUpdated: { updated in
                await MainActor.run { store.upsert(updated) }
            }
        )
        sessions = cache.sessions(macId: mac.id)
    }

    var isConnected: Bool { state.isConnected }

    var route: ConnectionRoute? {
        if case .connected(let route, _) = state { return route }
        return nil
    }

    // MARK: Lifecycle

    func start() {
        let client = self.client
        tasks.append(Task { [weak self] in
            for await state in client.states {
                await self?.stateChanged(state)
            }
        })
        tasks.append(Task { [weak self] in
            for await message in client.pushes {
                self?.handle(message)
            }
        })
        pathMonitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { await client.reconnectNow() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.ardasenturk.Pilothouse.ios.path"))
        Task { await client.start() }
    }

    func stop() async {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        pathMonitor.cancel()
        await client.stop()
        cache.save()
    }

    func setPreference(_ preference: ConnectionPreference) {
        let client = self.client
        Task { await client.setPreference(preference) }
    }

    /// Called when the app becomes active again.
    func appBecameActive() {
        let client = self.client
        Task { await client.reconnectNow() }
    }

    func appWentToBackground() {
        wasBusyWhenBackgrounded = sessions.contains { $0.state.isBusy }
        cache.save()
    }

    private func stateChanged(_ newState: MacConnectionState) async {
        state = newState
        guard newState.isConnected else { return }
        await refreshSessions()
        await refreshStatus()
        for sessionId in subscribed {
            await subscribe(sessionId)
        }
        if wasBusyWhenBackgrounded {
            wasBusyWhenBackgrounded = false
            resumedWhileAwayNotice = String(localized: "Claude kept working on your Mac while you were away.")
        }
    }

    // MARK: Pushes

    private func handle(_ message: ServerMessage) {
        switch message {
        case .helloAck(let ack):
            pendingPermissions = ack.pendingPermissions
        case .event(let payload):
            let event = payload.sequencedEvent
            chat(for: payload.sessionId).apply(event)
            cache.append(event, sessionId: payload.sessionId)
        case .sessionStarted(let payload), .sessionUpdated(let payload):
            upsert(payload.session)
        case .sessionDeleted(let ref):
            removeSession(ref.sessionId)
        case .sessionEnded(let ended):
            if let index = sessions.firstIndex(where: { $0.id == ended.sessionId }), ended.reason != .deleted {
                sessions[index].state = .closed
                cache.store(sessions[index], macId: mac.id)
            }
        case .permissionRequest(let request):
            guard !pendingPermissions.contains(where: { $0.id == request.id }) else { return }
            pendingPermissions.append(request)
            Haptics.permissionRequested()
        case .permissionResolved(let resolved):
            pendingPermissions.removeAll { $0.id == resolved.requestId }
        case .macStatus(let newStatus):
            apply(newStatus)
        case .error(let error):
            if error.code == .deviceRevoked {
                state = .failed(message: error.message, code: error.code)
            }
        case .ok, .directoryListing, .sessionList:
            break
        }
    }

    private func apply(_ newStatus: MacStatus) {
        status = newStatus
        // Learn new addresses (e.g. Tailscale set up after pairing).
        let addresses = newStatus.addresses
        guard !mac.isDemo, !addresses.isEmpty, addresses != mac.addresses || newStatus.port != mac.port else { return }
        mac.addresses = addresses
        mac.port = newStatus.port
        mac.name = newStatus.macName
        store.upsert(mac)
        let client = self.client
        let port = newStatus.port
        Task { await client.updateAddresses(addresses, port: port) }
    }

    private func upsert(_ session: SessionSummary) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
        cache.store(session, macId: mac.id)
        if !session.state.isBusy {
            chats[session.id]?.finishStreaming()
        }
    }

    private func removeSession(_ id: String) {
        sessions.removeAll { $0.id == id }
        chats.removeValue(forKey: id)
        subscribed.remove(id)
        pendingPermissions.removeAll { $0.sessionId == id }
        cache.deleteSession(id)
    }

    // MARK: Transcripts

    /// The transcript of `sessionId`, seeded from the offline cache.
    func chat(for sessionId: String) -> ChatState {
        if let chat = chats[sessionId] { return chat }
        let chat = ChatState(sessionId: sessionId)
        chat.replay(cache.events(sessionId: sessionId))
        chats[sessionId] = chat
        return chat
    }

    func session(_ id: String) -> SessionSummary? {
        sessions.first { $0.id == id }
    }

    /// Starts streaming a session's events (catch-up from the cached position).
    func open(_ sessionId: String) async {
        subscribed.insert(sessionId)
        guard isConnected else { return }
        await subscribe(sessionId)
    }

    private func subscribe(_ sessionId: String) async {
        let fromSeq = chat(for: sessionId).lastSeq + 1
        _ = try? await client.request(.subscribe(Subscribe(sessionId: sessionId, fromSeq: fromSeq)))
    }

    // MARK: Commands

    func refreshSessions() async {
        guard case .sessionList(let list)? = try? await client.request(.listSessions) else { return }
        sessions = list.sessions.sorted { $0.updatedAt > $1.updatedAt }
        cache.store(list.sessions, macId: mac.id, replacingAll: true)
    }

    func refreshStatus() async {
        if case .macStatus(let newStatus)? = try? await client.request(.macStatus) {
            apply(newStatus)
        }
    }

    func listDirectory(_ path: String?, showHidden: Bool) async throws -> DirectoryListing {
        let response = try await client.request(.listDirectory(ListDirectory(path: path, showHidden: showHidden)))
        guard case .directoryListing(let listing) = response else {
            throw MacClientError.unexpectedResponse(response.typeName)
        }
        return listing
    }

    func startSession(cwd: String, model: String?, permissionMode: PermissionMode, firstMessage: String?) async throws -> SessionSummary {
        let response = try await client.request(.startSession(StartSession(
            cwd: cwd, model: model, permissionMode: permissionMode, firstMessage: firstMessage
        )), timeout: 60)
        guard case .sessionStarted(let payload) = response else {
            throw MacClientError.unexpectedResponse(response.typeName)
        }
        upsert(payload.session)
        await open(payload.session.id)
        return payload.session
    }

    func send(_ text: String, attachments: [MessageAttachment], to sessionId: String) async throws {
        _ = try await client.request(.sendMessage(SendMessage(
            sessionId: sessionId, text: text, attachments: attachments.isEmpty ? nil : attachments
        )), timeout: 60)
    }

    func interrupt(_ sessionId: String) async throws {
        _ = try await client.request(.interrupt(SessionRef(sessionId: sessionId)))
    }

    func close(_ sessionId: String) async throws {
        _ = try await client.request(.closeSession(SessionRef(sessionId: sessionId)))
    }

    func resume(_ sessionId: String) async throws {
        let response = try await client.request(.resumeSession(SessionRef(sessionId: sessionId)), timeout: 60)
        if case .sessionStarted(let payload) = response { upsert(payload.session) }
        await open(sessionId)
    }

    func delete(_ sessionId: String) async throws {
        _ = try await client.request(.deleteSession(SessionRef(sessionId: sessionId)))
        removeSession(sessionId)
    }

    func respond(to request: PermissionRequest, allow: Bool, remember: Bool) async throws {
        _ = try await client.request(.permissionResponse(PermissionResponse(requestId: request.id, allow: allow, remember: remember)))
        pendingPermissions.removeAll { $0.id == request.id }
        if allow { Haptics.success() }
    }
}

/// How this device introduces itself to the Mac.
enum DeviceDescription {
    @MainActor static var current: DeviceInfo {
        let device = UIDevice.current
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return DeviceInfo(name: device.name, platform: device.userInterfaceIdiom == .pad ? "iPadOS" : "iOS", appVersion: version)
    }
}
