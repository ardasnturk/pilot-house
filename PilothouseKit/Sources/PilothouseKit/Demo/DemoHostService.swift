import Foundation

/// An in-process, scripted stand-in for a Mac running Pilothouse.
///
/// Powers the iOS demo mode (App Review, screenshots) and the UI tests. It
/// speaks the real protocol through the real Noise channel over an in-memory
/// transport, so the app exercises exactly the production code paths.
public actor DemoHostService: HostService {
    /// Multiplier for all scripted delays (0 = instant, 1 = realistic).
    public let pace: Double
    public static let homePath = "/Users/demo"

    private var sessions: [String: SessionSummary] = [:]
    private var events: [String: [SequencedEvent]] = [:]
    private var sessionSubscribers: [String: [UUID: AsyncStream<SequencedEvent>.Continuation]] = [:]
    private var notificationSubscribers: [UUID: AsyncStream<HostNotification>.Continuation] = [:]
    private var pendingPermissions: [String: (request: PermissionRequest, continuation: CheckedContinuation<Bool, Never>)] = [:]
    private var runningTurns: [String: Task<Void, Never>] = [:]
    private var turnCounter = 0
    /// Folders created in the demo, by parent path (the scripted tree is immutable).
    private var createdFolders: [String: [String]] = [:]
    private let now: Date

    public init(pace: Double = 1, now: Date = Date()) {
        self.pace = pace
        self.now = now
        for seed in DemoContent.seedSessions(now: now) {
            sessions[seed.summary.id] = seed.summary
            events[seed.summary.id] = seed.events.enumerated().map { index, event in
                SequencedEvent(seq: index + 1, timestamp: seed.summary.updatedAt.addingTimeInterval(Double(index - seed.events.count)), event: event)
            }
            sessions[seed.summary.id]?.lastSeq = seed.events.count
        }
    }

    // MARK: HostService

    public func helloAck(for client: ClientContext) async -> HelloAck {
        HelloAck(
            macName: DemoContent.macName,
            macId: "demo",
            serverVersion: "1.0 (demo)",
            pendingPermissions: pendingPermissions.values.map(\.request)
        )
    }

    public func macStatus() async -> MacStatus {
        MacStatus(
            macName: DemoContent.macName,
            sleepPrevented: true,
            lidClosedModeEnabled: false,
            claude: ClaudeCLIStatus(installed: true, path: "/Users/demo/.local/bin/claude", version: "2.1.310 (Claude Code)"),
            tailscale: TailscaleStatus(
                installed: true, running: true, backendState: "Running", ipv4: "100.101.102.103",
                magicDNSName: "demo-macbook.tail-demo.ts.net", tailnetName: "tail-demo.ts.net", magicDNSEnabled: true
            ),
            addresses: [HostAddress(host: "192.168.1.20", kind: .local)],
            port: PilothouseProtocol.defaultPort,
            activeSessionCount: sessions.values.filter { $0.state != .closed }.count,
            bypassPermissionsAllowed: false,
            defaultModel: "sonnet",
            agents: [
                AgentStatus(kind: .claude, installed: true, version: "2.1.310 (Claude Code)", loggedIn: true, models: ["opus", "sonnet", "haiku"]),
                AgentStatus(kind: .codex, installed: true, version: "codex-cli 0.162.1", loggedIn: true, delegationEnabled: true),
                AgentStatus(kind: .gemini, installed: true, version: "0.24.0", delegationEnabled: true),
            ]
        )
    }

    public func listDirectory(_ request: ListDirectory) async throws -> DirectoryListing {
        let path = DemoContent.normalize(request.path, home: Self.homePath)
        guard path.hasPrefix(Self.homePath) else {
            throw ErrorPayload(code: .pathOutsideHome, message: "Only folders inside your home folder can be browsed.")
        }
        guard let entries = children(of: path) else {
            throw ErrorPayload(code: .notFound, message: "Folder not found.")
        }
        let nodes = entries
            .filter { request.showHidden || !$0.hasPrefix(".") }
            .map { name -> FileNode in
                let childPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
                let isDirectory = children(of: childPath) != nil
                return FileNode(
                    name: name,
                    path: childPath,
                    isDirectory: isDirectory,
                    isHidden: name.hasPrefix("."),
                    isGitRepository: DemoContent.gitRepositories.contains(childPath),
                    size: isDirectory ? nil : Int64(1_024 + name.count * 311),
                    modifiedAt: now.addingTimeInterval(-Double(name.count) * 3_600)
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        let parent = path == Self.homePath ? nil : (path as NSString).deletingLastPathComponent
        return DirectoryListing(
            path: path,
            homePath: Self.homePath,
            parentPath: parent,
            isGitRepository: DemoContent.gitRepositories.contains(path),
            entries: nodes
        )
    }

    public func createDirectory(_ request: CreateDirectory) async throws -> DirectoryListing {
        let parent = DemoContent.normalize(request.parent, home: Self.homePath)
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else {
            throw ErrorPayload(code: .invalidName, message: "Folder names cannot be empty, start with a dot or contain / or :.")
        }
        guard let siblings = children(of: parent) else {
            throw ErrorPayload(code: .notFound, message: "Folder not found.")
        }
        guard !siblings.contains(name) else {
            throw ErrorPayload(code: .alreadyExists, message: "A folder named \(name) already exists.")
        }
        createdFolders[parent, default: []].append(name)
        createdFolders["\(parent)/\(name)"] = []
        return try await listDirectory(ListDirectory(path: parent))
    }

    private func children(of path: String) -> [String]? {
        let scripted = DemoContent.tree[path]
        let created = createdFolders[path]
        guard scripted != nil || created != nil else { return nil }
        return (scripted ?? []) + (created ?? [])
    }

    public func weeklySummary(_ request: GetWeeklySummary) async throws -> WeeklySummary {
        DemoContent.weeklySummary(containing: request.week ?? now)
    }

    public func usageLimits() async -> [UsageLimits] {
        DemoContent.usageLimits(now: now)
    }

    public func listSessions() async -> [SessionSummary] {
        sessions.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func startSession(_ request: StartSession, from client: ClientContext) async throws -> SessionSummary {
        let cwd = DemoContent.normalize(request.cwd, home: Self.homePath)
        guard children(of: cwd) != nil else {
            throw ErrorPayload(code: .notFound, message: "Folder not found.")
        }
        let id = UUID().uuidString.lowercased()
        let date = Date()
        let title = request.firstMessage.map { DemoContent.title(from: $0) } ?? (cwd as NSString).lastPathComponent
        let summary = SessionSummary(
            id: id, cwd: cwd, title: title, createdAt: date, updatedAt: date,
            model: request.model ?? "sonnet", permissionMode: request.permissionMode ?? .default, state: .idle,
            slashCommands: DemoContent.slashCommands, agent: request.agent
        )
        sessions[id] = summary
        events[id] = []
        broadcast(.sessionStarted(summary))
        append(.sessionInfo(SessionEvent.SessionInfo(
            claudeSessionId: id, model: summary.model, permissionMode: summary.permissionMode.rawValue, cwd: cwd,
            claudeVersion: "2.1.310", slashCommands: DemoContent.slashCommands
        )), to: id)
        if let first = request.firstMessage, !first.isEmpty {
            try await sendMessage(SendMessage(sessionId: id, text: first), from: client)
        }
        return sessions[id] ?? summary
    }

    public func resumeSession(id: String) async throws -> SessionSummary {
        guard var session = sessions[id] else { throw ErrorPayload(code: .notFound, message: "Session not found.") }
        if session.state == .closed {
            session.state = .idle
            session.updatedAt = Date()
            sessions[id] = session
            broadcast(.sessionUpdated(session))
            append(.systemNotice(.init(kind: "resumed", level: .info, text: "Session resumed.")), to: id)
        }
        return sessions[id] ?? session
    }

    public func sendMessage(_ request: SendMessage, from client: ClientContext) async throws {
        guard let session = sessions[request.sessionId] else {
            throw ErrorPayload(code: .notFound, message: "Session not found.")
        }
        guard session.state != .closed else {
            throw ErrorPayload(code: .sessionClosed, message: "This session is closed. Continue it first.")
        }
        append(.userMessage(.init(text: request.text, attachmentCount: request.attachments?.count ?? 0)), to: request.sessionId)
        update(request.sessionId) {
            $0.state = .running
            $0.lastMessagePreview = request.text
        }
        turnCounter += 1
        let turn = turnCounter
        let sessionId = request.sessionId
        let text = request.text
        runningTurns[sessionId]?.cancel()
        runningTurns[sessionId] = Task { [weak self] in
            await self?.runScriptedTurn(sessionId: sessionId, prompt: text, turn: turn)
        }
    }

    public func interrupt(sessionId: String) async throws {
        guard sessions[sessionId] != nil else { throw ErrorPayload(code: .notFound, message: "Session not found.") }
        runningTurns.removeValue(forKey: sessionId)?.cancel()
        for (id, pending) in pendingPermissions where pending.request.sessionId == sessionId {
            pendingPermissions.removeValue(forKey: id)
            pending.continuation.resume(returning: false)
        }
        append(.systemNotice(.init(kind: "interrupted", level: .warning, text: "Interrupted by user.")), to: sessionId)
        append(.result(.init(isError: true, subtype: "error_during_execution", durationMs: 1_200)), to: sessionId)
        update(sessionId) { $0.state = .idle }
    }

    public func closeSession(id: String) async throws {
        guard sessions[id] != nil else { throw ErrorPayload(code: .notFound, message: "Session not found.") }
        runningTurns.removeValue(forKey: id)?.cancel()
        update(id) { $0.state = .closed }
        broadcast(.sessionEnded(SessionEnded(sessionId: id, reason: .closedByUser)))
    }

    public func deleteSession(id: String) async throws {
        runningTurns.removeValue(forKey: id)?.cancel()
        sessions.removeValue(forKey: id)
        events.removeValue(forKey: id)
        for continuation in sessionSubscribers.removeValue(forKey: id)?.values ?? [:].values {
            continuation.finish()
        }
        broadcast(.sessionDeleted(id))
    }

    public func subscribe(sessionId: String, fromSeq: Int) async throws -> AsyncStream<SequencedEvent> {
        guard let backlog = events[sessionId] else { throw ErrorPayload(code: .notFound, message: "Session not found.") }
        let (stream, continuation) = AsyncStream.makeStream(of: SequencedEvent.self, bufferingPolicy: .unbounded)
        for event in backlog where event.seq >= fromSeq {
            continuation.yield(event)
        }
        let id = UUID()
        sessionSubscribers[sessionId, default: [:]][id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id, sessionId: sessionId) }
        }
        return stream
    }

    public func respondToPermission(_ response: PermissionResponse, from client: ClientContext) async throws {
        guard let pending = pendingPermissions.removeValue(forKey: response.requestId) else {
            throw ErrorPayload(code: .notFound, message: "This request was already answered or has expired.")
        }
        let outcome: SessionEvent.PermissionDecision.Outcome =
            response.allow ? (response.remember == true ? .allowedForSession : .allowed) : .denied
        broadcast(.permissionResolved(PermissionResolved(requestId: response.requestId, sessionId: pending.request.sessionId, outcome: outcome)))
        append(.permissionDecision(.init(
            requestId: response.requestId, toolName: pending.request.tool, summary: pending.request.summary, outcome: outcome
        )), to: pending.request.sessionId)
        pending.continuation.resume(returning: response.allow)
    }

    public func notifications() async -> AsyncStream<HostNotification> {
        let (stream, continuation) = AsyncStream.makeStream(of: HostNotification.self, bufferingPolicy: .unbounded)
        let id = UUID()
        notificationSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeNotificationSubscriber(id) }
        }
        return stream
    }

    // MARK: Scripted turn

    private func runScriptedTurn(sessionId: String, prompt: String, turn: Int) async {
        let started = Date()
        let script = DemoContent.script(for: prompt, cwd: sessions[sessionId]?.cwd ?? Self.homePath, turn: turn)
        for step in script {
            if Task.isCancelled { return }
            switch step {
            case .think(let text):
                let blockId = "demo-\(turn)-think"
                emit(.thinking(.init(blockId: blockId, text: "", isComplete: false)), to: sessionId)
                await pause(0.6)
                append(.thinking(.init(blockId: blockId, text: text, isComplete: true)), to: sessionId)
            case .say(let text, let index):
                let blockId = "demo-\(turn):\(index)"
                var streamed = ""
                for chunk in DemoContent.chunks(of: text) {
                    if Task.isCancelled { return }
                    streamed += chunk
                    emit(.assistantTextDelta(.init(blockId: blockId, text: chunk)), to: sessionId)
                    await pause(0.03)
                }
                append(.assistantMessage(.init(blockId: blockId, text: text)), to: sessionId)
                update(sessionId) { $0.lastMessagePreview = text }
            case .tool(let name, let input, let output, let isError, let edit):
                let toolUseId = "toolu_demo_\(turn)_\(name)_\(UUID().uuidString.prefix(6))"
                append(.toolUse(.init(toolUseId: toolUseId, name: name, input: input)), to: sessionId)
                await pause(0.5)
                if DemoContent.requiresPermission(name, mode: sessions[sessionId]?.permissionMode ?? .default) {
                    let allowed = await askPermission(sessionId: sessionId, tool: name, input: input)
                    if Task.isCancelled { return }
                    guard allowed else {
                        append(.toolResult(.init(toolUseId: toolUseId, output: "The user denied this action.", isError: true)), to: sessionId)
                        append(.assistantMessage(.init(
                            blockId: "demo-\(turn):denied",
                            text: "Understood — I won't run that. Let me know how you'd like to proceed."
                        )), to: sessionId)
                        finishTurn(sessionId: sessionId, started: started, isError: false)
                        return
                    }
                }
                await pause(0.7)
                append(.toolResult(.init(toolUseId: toolUseId, output: output, isError: isError)), to: sessionId)
                if let edit {
                    append(.fileEdit(.init(toolUseId: toolUseId, path: edit.path, kind: edit.kind, diff: edit.diff)), to: sessionId)
                }
            case .delegate(let agent, let prompt, let command, let output, let answer):
                let thread = "toolu_demo_\(turn)_delegate"
                append(.toolUse(.init(toolUseId: thread, name: ToolSummary.delegationToolName, input: [
                    "agent": .string(agent.rawValue), "prompt": .string(prompt),
                ])), to: sessionId)
                await pause(0.6)
                append(.userMessage(.init(text: prompt)), to: sessionId, thread: thread)
                await pause(0.6)
                append(.toolUse(.init(toolUseId: "\(thread)_run", name: "Bash", input: ["command": .string(command)])), to: sessionId, thread: thread)
                await pause(0.8)
                append(.toolResult(.init(toolUseId: "\(thread)_run", output: output, isError: false)), to: sessionId, thread: thread)
                await pause(0.6)
                append(.assistantMessage(.init(blockId: "\(thread)_answer", text: answer)), to: sessionId, thread: thread)
                append(.result(.init(isError: false, subtype: "success", durationMs: 2_600)), to: sessionId, thread: thread)
                await pause(0.4)
                append(.toolResult(.init(toolUseId: thread, output: answer, isError: false)), to: sessionId)
            }
        }
        finishTurn(sessionId: sessionId, started: started, isError: false)
    }

    private func finishTurn(sessionId: String, started: Date, isError: Bool) {
        let duration = Int(Date().timeIntervalSince(started) * 1_000)
        append(.result(.init(
            isError: isError, subtype: "success", durationMs: max(duration, 4_200), numTurns: 3, costUSD: 0.0213,
            usage: .init(inputTokens: 1_840, outputTokens: 512, cacheReadInputTokens: 38_400)
        )), to: sessionId)
        update(sessionId) { $0.state = .idle }
        runningTurns.removeValue(forKey: sessionId)
    }

    private func askPermission(sessionId: String, tool: String, input: JSONValue) async -> Bool {
        let request = PermissionRequest(
            id: UUID().uuidString.lowercased(),
            sessionId: sessionId,
            tool: tool,
            input: input,
            cwd: sessions[sessionId]?.cwd ?? Self.homePath,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(600),
            rememberKey: PermissionRequest.rememberKey(tool: tool, input: input)
        )
        update(sessionId) { $0.state = .awaitingPermission }
        let allowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pendingPermissions[request.id] = (request, continuation)
            broadcast(.permissionRequest(request))
        }
        if sessions[sessionId]?.state == .awaitingPermission {
            update(sessionId) { $0.state = .running }
        }
        return allowed
    }

    private func pause(_ seconds: Double) async {
        guard pace > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds * pace))
    }

    // MARK: Bookkeeping

    private func append(_ event: SessionEvent, to sessionId: String, thread: String? = nil) {
        guard events[sessionId] != nil else { return }
        let seq = (events[sessionId]?.last?.seq ?? 0) + 1
        let sequenced = SequencedEvent(seq: seq, timestamp: Date(), event: event, thread: thread)
        events[sessionId]?.append(sequenced)
        update(sessionId, broadcastChange: false) {
            $0.lastSeq = seq
            $0.updatedAt = sequenced.timestamp
        }
        for continuation in sessionSubscribers[sessionId]?.values ?? [:].values {
            continuation.yield(sequenced)
        }
    }

    private func emit(_ event: SessionEvent, to sessionId: String) {
        let seq = events[sessionId]?.last?.seq ?? 0
        let sequenced = SequencedEvent(seq: seq, timestamp: Date(), ephemeral: true, event: event)
        for continuation in sessionSubscribers[sessionId]?.values ?? [:].values {
            continuation.yield(sequenced)
        }
    }

    private func update(_ sessionId: String, broadcastChange: Bool = true, _ change: (inout SessionSummary) -> Void) {
        guard var session = sessions[sessionId] else { return }
        let before = session
        change(&session)
        sessions[sessionId] = session
        if broadcastChange, session != before {
            broadcast(.sessionUpdated(session))
        }
    }

    private func broadcast(_ notification: HostNotification) {
        for continuation in notificationSubscribers.values {
            continuation.yield(notification)
        }
    }

    private func removeSubscriber(_ id: UUID, sessionId: String) {
        sessionSubscribers[sessionId]?.removeValue(forKey: id)
    }

    private func removeNotificationSubscriber(_ id: UUID) {
        notificationSubscribers.removeValue(forKey: id)
    }
}

/// The "MockMacServer" of the test plan (prompt §8): an in-process Mac.
public typealias MockMacServer = DemoHostService

/// Accepts every key: the demo has no real security boundary.
public struct DemoAuthorizer: PeerAuthorizer {
    public init() {}
    public func authorize(publicKey: Data, hello: ClientHandshakePayload) async -> HandshakeDecision { .accept }
    public func peerConnected(deviceId: String, hello: ClientHandshakePayload) async {}
    public func peerDisconnected(deviceId: String) async {}
}

/// Connects `.demo` endpoints to an in-process `ServerEndpoint`.
public final class DemoConnector: TransportConnector {
    public let service: DemoHostService
    public let mac: PairedMac
    private let endpoint: ServerEndpoint

    /// Creates a demo Mac. `pace` scales the scripted delays (0 for tests).
    public init(pace: Double = 1) {
        let identity = IdentityKeyPair.generate()
        let service = DemoHostService(pace: pace)
        self.service = service
        endpoint = ServerEndpoint(
            identity: identity,
            macName: { DemoContent.macName },
            authorizer: DemoAuthorizer(),
            service: service
        )
        mac = PairedMac(
            id: identity.fingerprint,
            name: DemoContent.macName,
            publicKey: identity.publicKey,
            addresses: [],
            port: PilothouseProtocol.defaultPort,
            pairedAt: Date(),
            isDemo: true
        )
    }

    public func connect(to endpoint: Endpoint, timeout: Double) async throws -> any MessageTransport {
        let (client, server) = InMemoryTransport.makePair()
        let serverEndpoint = self.endpoint
        Task { await serverEndpoint.accept(server) }
        return client
    }

    /// Drops every connection, as a network loss would (UI tests of reconnection).
    public func simulateNetworkDrop() async {
        await endpoint.disconnectAll()
    }
}
