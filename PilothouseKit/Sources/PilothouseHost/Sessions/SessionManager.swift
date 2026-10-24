import Foundation
import PilothouseKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Settings that shape how sessions run. Owned by the Mac app's settings.
public struct HostConfiguration: Sendable, Equatable {
    public var homeDirectory: String
    /// `~/Library/Application Support/Pilothouse`
    public var dataDirectory: URL
    /// Logs of sessions untouched for longer are deleted (prompt §4.5: 30 days).
    public var retentionDays: Int
    public var allowBypassPermissions: Bool
    public var defaultModel: String?
    public var defaultPermissionMode: PermissionMode
    /// Agents Claude may hand tasks to with `delegate_to_agent`.
    public var delegationAgents: [AgentKind]

    public init(
        homeDirectory: String = NSHomeDirectory(),
        dataDirectory: URL,
        retentionDays: Int = 30,
        allowBypassPermissions: Bool = false,
        defaultModel: String? = nil,
        defaultPermissionMode: PermissionMode = .default,
        delegationAgents: [AgentKind] = []
    ) {
        self.homeDirectory = homeDirectory
        self.dataDirectory = dataDirectory
        self.retentionDays = retentionDays
        self.allowBypassPermissions = allowBypassPermissions
        self.defaultModel = defaultModel
        self.defaultPermissionMode = defaultPermissionMode
        self.delegationAgents = delegationAgents
    }

    public var sessionsDirectory: URL { dataDirectory.appendingPathComponent("sessions", isDirectory: true) }
}

/// Owns every session: its record, its event log, its CLI process and its
/// subscribers. See docs/DECISIONS.md D-002 and D-005 for the process model.
public actor SessionManager {
    public static let maximumAttachments = 10
    /// After SIGINT the CLI normally exits within a second; force it after this.
    public static let interruptGrace: Double = 8
    /// A delegated sub-agent task is stopped after this long.
    public static let delegationTimeout: Double = 60 * 60

    private struct LiveSession {
        var record: SessionRecord
        let log: EventLog
        var process: ChildProcess?
        var generation = 0
        var spawning: Task<Void, Error>?
        var adapter: any AgentAdapter = ClaudeAdapter()
        var subscribers: [UUID: AsyncStream<SequencedEvent>.Continuation] = [:]
        var token: String?
        var interruptRequested = false
        var closing = false
        /// The CLI was interrupted or closed: it must not receive new input,
        /// the next message waits for it to exit and starts a fresh process.
        var retiring = false
        var sawInterruptNotice = false
        var pendingPermissions = 0
        var stderrTail: [String] = []
    }

    private var configuration: HostConfiguration
    private let store: SessionStore
    private let broker: PermissionBroker
    private let hub: NotificationHub
    private let fileBrowser: FileBrowser
    private let launcher: @Sendable (AgentKind) async throws -> any AgentLauncher
    private let log = PilothouseLog("SessionManager")
    private var sessions: [String: LiveSession] = [:]
    private var tokens: [String: String] = [:]
    private var permissionPort: Int?
    private var bootstrapped = false

    /// A sub-agent CLI started by `delegate_to_agent`, by thread (tool-use ID).
    private struct Delegation {
        let parentId: String
        let agent: AgentKind
        let process: ChildProcess
        var adapter: any AgentAdapter
        var lastAnswer = ""
        var finish: CheckedContinuation<DelegationResult, Never>?
    }

    private var delegations: [String: Delegation] = [:]
    /// `delegate_to_agent` tool uses seen in a session's output and not yet
    /// claimed by a delegation, so the sub-agent's thread is that tool use.
    private var unclaimedDelegateCalls: [String: [(toolUseId: String, input: JSONValue)]] = [:]

    /// Claude Code only (tests and older call sites).
    public init(
        configuration: HostConfiguration,
        broker: PermissionBroker,
        hub: NotificationHub,
        launcher: @escaping @Sendable () async throws -> any ClaudeLauncher
    ) {
        self.init(configuration: configuration, broker: broker, hub: hub, agentLauncher: { kind in
            guard kind == .claude else {
                throw ErrorPayload(code: .agentNotInstalled, message: "\(kind.displayName) is not available on this Mac.")
            }
            return try await launcher()
        })
    }

    /// - Parameter agentLauncher: resolves the launcher of an agent on demand;
    ///   throws `ErrorPayload(.claudeNotInstalled / .agentNotInstalled)` when it is missing.
    public init(
        configuration: HostConfiguration,
        broker: PermissionBroker,
        hub: NotificationHub,
        agentLauncher launcher: @escaping @Sendable (AgentKind) async throws -> any AgentLauncher
    ) {
        self.configuration = configuration
        self.broker = broker
        self.hub = hub
        self.launcher = launcher
        store = SessionStore(url: configuration.dataDirectory.appendingPathComponent("sessions.json"))
        fileBrowser = FileBrowser(sandbox: PathSandbox(homeDirectory: configuration.homeDirectory))
    }

    /// Loads stored sessions, repairs state left by a crash and applies retention.
    public func bootstrap(now: Date = Date()) async {
        guard !bootstrapped else { return }
        bootstrapped = true
        try? PrivateFiles.ensureDirectory(configuration.sessionsDirectory)
        let cutoff = now.addingTimeInterval(-Double(max(1, configuration.retentionDays)) * 86_400)
        for var record in await store.all {
            let log = EventLog(url: logURL(record.summary.id))
            if record.summary.updatedAt < cutoff {
                log.delete()
                await store.remove(record.summary.id)
                continue
            }
            if record.summary.state.isBusy {
                record.summary.state = .idle
                await store.upsert(record)
                sessions[record.summary.id] = LiveSession(record: record, log: log)
                append(.systemNotice(.init(
                    kind: "hostRestarted", level: .warning,
                    text: "Pilothouse was restarted while Claude was working; the last turn may be incomplete."
                )), to: record.summary.id)
            } else {
                sessions[record.summary.id] = LiveSession(record: record, log: log)
            }
        }
    }

    public func updateConfiguration(_ configuration: HostConfiguration) {
        self.configuration = configuration
    }

    /// Port of the local permission MCP server (`nil` disables permission forwarding).
    public func setPermissionServerPort(_ port: Int?) {
        permissionPort = port
    }

    // MARK: Queries

    public func summaries() -> [SessionSummary] {
        sessions.values.map(\.record.summary).sorted { $0.updatedAt > $1.updatedAt }
    }

    public func summary(_ id: String) -> SessionSummary? {
        sessions[id]?.record.summary
    }

    /// Sessions with a running CLI or a turn in progress.
    public func activeSessions() -> [SessionSummary] {
        sessions.values.filter { $0.process != nil || $0.record.summary.state.isBusy }.map(\.record.summary)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func sessionId(forToken token: String) -> String? {
        tokens[token]
    }

    // MARK: Commands

    public func start(_ request: StartSession) async throws -> SessionSummary {
        let agent = request.agent ?? .claude
        _ = try await launcher(agent)
        let cwd = try fileBrowser.validateWorkingDirectory(request.cwd)
        let mode = request.permissionMode ?? configuration.defaultPermissionMode
        if mode == .bypassPermissions && !configuration.allowBypassPermissions {
            throw ErrorPayload(
                code: .modeNotAllowed,
                message: "“Bypass permissions” is turned off. Enable it in Pilothouse settings on your Mac first."
            )
        }
        let id = UUID().uuidString.lowercased()
        let now = Date()
        let model = request.model.flatMap { $0.isEmpty ? nil : $0 } ?? configuration.defaultModel
        let isHome = cwd.path == fileBrowser.sandbox.home.path
        let summary = SessionSummary(
            id: id,
            cwd: cwd.path,
            title: isHome ? "~" : cwd.lastPathComponent,
            createdAt: now,
            updatedAt: now,
            model: model,
            permissionMode: mode,
            state: .starting,
            agent: agent
        )
        let record = SessionRecord(summary: summary, requestedModel: model)
        sessions[id] = LiveSession(record: record, log: EventLog(url: logURL(id)))
        await store.upsert(record)
        await hub.post(.sessionStarted(summary))
        do {
            try await ensureProcess(id)
        } catch {
            setState(.idle, for: id)
            append(.systemNotice(.init(kind: "launchFailed", level: .error, text: "Could not start \(agent.displayName): \(error)")), to: id)
            await persistAndPublish(id)
            throw error
        }
        if let first = request.firstMessage, !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await send(SendMessage(sessionId: id, text: first))
        } else {
            setState(.idle, for: id)
            await persistAndPublish(id)
        }
        return sessions[id]?.record.summary ?? summary
    }

    public func send(_ request: SendMessage) async throws {
        guard let session = sessions[request.sessionId] else { throw Self.notFound }
        guard session.record.summary.state != .closed else {
            throw ErrorPayload(code: .sessionClosed, message: "This session is closed. Continue it first.")
        }
        let attachments = request.attachments ?? []
        try Self.validate(attachments)
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else {
            throw ErrorPayload(code: .invalidRequest, message: "The message is empty.")
        }
        try await ensureProcess(request.sessionId)
        do {
            try await writeUserMessage(text: text, attachments: attachments, to: request.sessionId)
        } catch {
            // The CLI died between turns; start it again once.
            await dropProcess(request.sessionId)
            try await ensureProcess(request.sessionId)
            try await writeUserMessage(text: text, attachments: attachments, to: request.sessionId)
        }
        append(.userMessage(.init(text: text, attachmentCount: attachments.count)), to: request.sessionId)
        update(request.sessionId) { record in
            record.summary.state = .running
            record.summary.lastMessagePreview = text.isEmpty ? "📎" : text
            if !record.hasUserMessages, !text.isEmpty {
                record.summary.title = Self.title(from: text)
            }
            record.hasUserMessages = true
        }
        await persistAndPublish(request.sessionId)
    }

    /// Stops the running turn: over the agent's protocol when it has a way to
    /// (Codex), otherwise SIGINT to the process group (Claude Code, D-002).
    public func interrupt(_ id: String) async throws {
        guard let session = sessions[id] else { throw Self.notFound }
        guard let process = session.process, session.record.summary.state.isBusy else { return }
        await stopDelegations(of: id, reason: "The user stopped the turn.")
        if let lines = sessions[id]?.adapter.interruptLines() {
            for line in lines { try? await process.write(line) }
            await broker.cancelAll(sessionId: id)
            return
        }
        sessions[id]?.interruptRequested = true
        sessions[id]?.retiring = true
        process.send(signal: SIGINT)
        await broker.cancelAll(sessionId: id)
        let generation = session.generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.interruptGrace))
            await self?.forceStopIfStillRunning(id, generation: generation)
        }
    }

    /// Ends the CLI (SIGTERM, then SIGKILL after 5 s) and marks the session closed.
    public func close(_ id: String) async throws {
        guard let session = sessions[id] else { throw Self.notFound }
        let process = session.process
        if process != nil {
            sessions[id]?.closing = true
            sessions[id]?.retiring = true
        }
        await stopDelegations(of: id, reason: "The session was closed.")
        setState(.closed, for: id)
        append(.systemNotice(.init(kind: "closed", level: .info, text: "Session closed.")), to: id)
        await persistAndPublish(id)
        await hub.post(.sessionEnded(SessionEnded(sessionId: id, reason: .closedByUser)))
        await broker.cancelAll(sessionId: id)
        if let process {
            Task { await process.terminate(grace: 5) }
        }
    }

    /// Re-opens a closed session; starts the CLI with `--resume`.
    public func resume(_ id: String) async throws -> SessionSummary {
        guard let session = sessions[id] else { throw Self.notFound }
        if session.record.summary.state == .closed {
            setState(.idle, for: id)
            append(.systemNotice(.init(kind: "resumed", level: .info, text: "Session continued.")), to: id)
            await persistAndPublish(id)
        }
        try await ensureProcess(id)
        return sessions[id]?.record.summary ?? session.record.summary
    }

    public func delete(_ id: String) async throws {
        guard sessions[id] != nil else { throw Self.notFound }
        await stopDelegations(of: id, reason: "The session was deleted.")
        guard let session = sessions.removeValue(forKey: id) else { throw Self.notFound }
        if let token = session.token { tokens.removeValue(forKey: token) }
        for continuation in session.subscribers.values { continuation.finish() }
        await broker.cancelAll(sessionId: id)
        if let process = session.process {
            Task { await process.terminate(grace: 5) }
        }
        session.log.delete()
        await store.remove(id)
        await hub.post(.sessionDeleted(id))
    }

    /// Persisted events from `fromSeq`, a snapshot of streaming text, then live events.
    public func subscribe(_ id: String, fromSeq: Int) throws -> AsyncStream<SequencedEvent> {
        guard let session = sessions[id] else { throw Self.notFound }
        let backlog = try session.log.events(from: fromSeq)
        let (stream, continuation) = AsyncStream.makeStream(of: SequencedEvent.self, bufferingPolicy: .unbounded)
        for event in backlog { continuation.yield(event) }
        let lastSeq = (try? session.log.lastSeq) ?? 0
        for (blockId, text) in session.adapter.streamingText where !text.isEmpty {
            continuation.yield(SequencedEvent(
                seq: lastSeq, timestamp: Date(), ephemeral: true,
                event: .assistantTextDelta(.init(blockId: blockId, text: text, replace: true))
            ))
        }
        let subscriberId = UUID()
        sessions[id]?.subscribers[subscriberId] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(subscriberId, from: id) }
        }
        return stream
    }

    /// Stops every CLI (app quit). Sessions stay resumable.
    public func shutdown() async {
        let running = sessions.compactMap { id, session -> (String, ChildProcess)? in
            session.process.map { (id, $0) }
        }
        for (id, _) in running {
            sessions[id]?.closing = true
            if sessions[id]?.record.summary.state.isBusy == true { setState(.idle, for: id) }
            await persistAndPublish(id)
        }
        await withTaskGroup(of: Void.self) { group in
            for (_, process) in running {
                group.addTask { await process.terminate(grace: 5) }
            }
        }
    }

    // MARK: Permissions

    /// Answers an approval that the agent asked for over its own protocol.
    private func answer(_ request: AgentPermissionRequest, session id: String, generation: Int) async {
        let result = await decidePermission(sessionId: id, tool: request.tool, input: request.input, toolUseId: request.toolUseId)
        guard let session = sessions[id], session.generation == generation, let process = session.process else { return }
        let allow = if case .allow = result { true } else { false }
        if let reply = session.adapter.permissionReply(to: request, allow: allow) {
            try? await process.write(reply)
        }
    }

    /// Called by the MCP endpoint for every permission prompt of a session's CLI.
    public func decidePermission(sessionId: String, tool: String, input: JSONValue, toolUseId: String?) async -> PermissionToolResult {
        guard let session = sessions[sessionId], session.process != nil, session.record.summary.state != .closed else {
            return .deny(message: "The Pilothouse session is no longer active.")
        }
        let key = PermissionRequest.rememberKey(tool: tool, input: input)
        if session.record.alwaysAllowed.contains(key) {
            append(.permissionDecision(.init(
                requestId: "auto-\(UUID().uuidString.lowercased())", toolName: tool,
                summary: PermissionRequest.summary(tool: tool, input: input), outcome: .allowedForSession
            )), to: sessionId)
            return .allow(updatedInput: input)
        }

        sessions[sessionId]?.pendingPermissions += 1
        setState(.awaitingPermission, for: sessionId)
        await persistAndPublish(sessionId)
        let (request, decision) = await broker.request(sessionId: sessionId, tool: tool, input: input, cwd: session.record.summary.cwd)

        guard sessions[sessionId] != nil else {
            return .deny(message: "The Pilothouse session was deleted.")
        }
        sessions[sessionId]?.pendingPermissions -= 1
        let outcome: SessionEvent.PermissionDecision.Outcome
        let result: PermissionToolResult
        switch decision {
        case .allow(let remember):
            outcome = remember ? .allowedForSession : .allowed
            result = .allow(updatedInput: input)
            if remember {
                update(sessionId) { record in
                    if !record.alwaysAllowed.contains(request.rememberKey) { record.alwaysAllowed.append(request.rememberKey) }
                }
            }
        case .deny:
            outcome = .denied
            result = .deny(message: "The user denied this action in Pilothouse.")
        case .timedOut:
            outcome = .timedOut
            result = .deny(message: "Nobody answered this permission request in Pilothouse within 10 minutes, so it was denied.")
        case .cancelled:
            outcome = .cancelled
            result = .deny(message: "The permission request was cancelled.")
        }
        append(.permissionDecision(.init(requestId: request.id, toolName: tool, summary: request.summary, outcome: outcome)), to: sessionId)
        if sessions[sessionId]?.pendingPermissions == 0, sessions[sessionId]?.record.summary.state == .awaitingPermission {
            setState(.running, for: sessionId)
        }
        await persistAndPublish(sessionId)
        return result
    }

    // MARK: Process lifecycle

    private func currentProcess(_ id: String) -> ChildProcess? {
        sessions[id]?.process
    }

    private func ensureProcess(_ id: String) async throws {
        guard let session = sessions[id] else { throw Self.notFound }
        if let process = session.process {
            guard session.retiring else { return }
            await retire(process, of: id, generation: session.generation)
            guard sessions[id] != nil else { throw Self.notFound }
            if sessions[id]?.process != nil { return }
        }
        if let spawning = session.spawning {
            try await spawning.value
            return
        }
        let task = Task { try await self.spawn(id) }
        sessions[id]?.spawning = task
        defer { sessions[id]?.spawning = nil }
        try await task.value
    }

    private func spawn(_ id: String) async throws {
        guard let session = sessions[id] else { throw Self.notFound }
        let summary = session.record.summary
        let launcher = try await launcher(summary.agentKind)
        let token = Self.randomToken()
        let options = ClaudeLaunchOptions(
            sessionId: id,
            resume: session.record.established,
            model: session.record.requestedModel,
            permissionMode: summary.permissionMode,
            workingDirectory: summary.cwd,
            permissionServer: permissionPort.map { PermissionServerInfo(port: $0, token: token) },
            agent: summary.agentKind,
            agentSessionId: session.record.agentSessionId
        )
        let process = try await launcher.launch(options)
        var adapter = launcher.makeAdapter(for: options)
        let startup = adapter.startupLines()
        guard sessions[id] != nil else {
            Task { await process.terminate(grace: 1) }
            throw Self.notFound
        }
        let generation = session.generation + 1
        sessions[id]?.generation = generation
        sessions[id]?.process = process
        sessions[id]?.token = token
        sessions[id]?.adapter = adapter
        sessions[id]?.stderrTail = []
        sessions[id]?.interruptRequested = false
        sessions[id]?.closing = false
        sessions[id]?.retiring = false
        sessions[id]?.sawInterruptNotice = false
        tokens[token] = id
        log.info("Started \(summary.agentKind.displayName) (pid \(process.pid)) for session \(id), resume: \(options.resume)")
        for line in startup { try? await process.write(line) }

        let stdoutLines = process.stdout.lines()
        let reader = Task { [weak self] in
            for await line in stdoutLines {
                await self?.handleLine(line, session: id, generation: generation)
            }
        }
        let stderrLines = process.stderr.lines()
        Task { [weak self] in
            for await line in stderrLines {
                await self?.handleStderr(line, session: id, generation: generation)
            }
        }
        Task { [weak self] in
            let status = await process.waitForExit()
            _ = try? await withTimeout(seconds: 3) { await reader.value }
            await self?.processExited(id, generation: generation, status: status)
        }
    }

    /// Waits for an interrupted or closed CLI to exit and for its exit to be
    /// processed (its last lines included), killing it if it lingers.
    private func retire(_ process: ChildProcess, of id: String, generation: Int) async {
        if await process.waitForExit(timeout: 10) == nil {
            await process.terminate(grace: 2)
        }
        for _ in 0..<100 where sessions[id]?.generation == generation && sessions[id]?.process != nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if sessions[id]?.generation == generation, sessions[id]?.process != nil {
            sessions[id]?.process = nil
            if let token = sessions[id]?.token { tokens.removeValue(forKey: token) }
            sessions[id]?.token = nil
        }
    }

    private func dropProcess(_ id: String) async {
        guard let session = sessions[id], let process = session.process else { return }
        sessions[id]?.process = nil
        sessions[id]?.generation += 1
        if let token = session.token { tokens.removeValue(forKey: token) }
        await process.terminate(grace: 1)
    }

    private func handleLine(_ line: String, session id: String, generation: Int) {
        guard sessions[id]?.generation == generation else { return }
        guard let output = sessions[id]?.adapter.consume(line: line) else { return }
        let events = output.events
        for event in events {
            append(event, to: id, thread: output.thread)
            if output.thread == nil, case .toolUse(let use) = event, use.name == ClaudeCommand.delegationToolFullName {
                unclaimedDelegateCalls[id, default: []].append((use.toolUseId, use.input))
            }
        }
        if !output.writes.isEmpty, let process = sessions[id]?.process {
            Task { for write in output.writes { try? await process.write(write) } }
        }
        for request in output.permissionRequests {
            Task { await self.answer(request, session: id, generation: generation) }
        }
        if output.thread == nil, events.contains(where: { if case .result = $0 { return true } else { return false } })
            || events.contains(where: { if case .assistantMessage = $0 { return true } else { return false } })
        {
            Task { await self.persistAndPublish(id) }
        }
    }

    private func handleStderr(_ line: String, session id: String, generation: Int) {
        guard sessions[id]?.generation == generation, !line.isEmpty else { return }
        sessions[id]?.stderrTail.append(line)
        if let count = sessions[id]?.stderrTail.count, count > 40 {
            sessions[id]?.stderrTail.removeFirst(count - 40)
        }
        log.debug("claude[\(id.prefix(8))] stderr: \(line)")
    }

    private func processExited(_ id: String, generation: Int, status: ExitStatus) async {
        guard let session = sessions[id], session.generation == generation else { return }
        sessions[id]?.process = nil
        if let token = session.token { tokens.removeValue(forKey: token) }
        sessions[id]?.token = nil
        await broker.cancelAll(sessionId: id)
        log.info("Claude Code for session \(id) exited: \(status)")

        if session.closing {
            sessions[id]?.closing = false
            return
        }
        if session.interruptRequested {
            sessions[id]?.interruptRequested = false
            if !session.sawInterruptNotice {
                append(.systemNotice(.init(kind: "interrupted", level: .warning, text: "Interrupted.")), to: id)
            }
        } else if !status.isSuccess {
            let tail = session.stderrTail.suffix(8).joined(separator: "\n")
            if tail.contains("No conversation found") {
                update(id) { $0.established = false }
                append(.systemNotice(.init(
                    kind: "resumeFailed", level: .warning,
                    text: "Claude Code could not find the earlier conversation. Your next message starts a fresh one in this session."
                )), to: id)
            } else if StreamJSONNormalizer.looksLikeLoginProblem(tail) {
                append(StreamJSONNormalizer.loginRequiredNotice, to: id)
            } else {
                let detail = tail.isEmpty ? "" : "\n\(tail)"
                append(.systemNotice(.init(
                    kind: "processExited", level: .error,
                    text: "Claude Code stopped unexpectedly (\(status)).\(detail)"
                )), to: id)
            }
        }
        if sessions[id]?.record.summary.state.isBusy == true {
            setState(.idle, for: id)
        }
        await persistAndPublish(id)
    }

    private func forceStopIfStillRunning(_ id: String, generation: Int) async {
        guard let session = sessions[id], session.generation == generation, let process = session.process else { return }
        log.info("Claude Code did not exit after SIGINT; terminating")
        await process.terminate(grace: 2)
    }

    // MARK: Delegation (`delegate_to_agent`)

    /// Agents the session's Claude may delegate to.
    public func delegationAgents(for sessionId: String) -> [AgentKind] {
        guard let session = sessions[sessionId], session.record.summary.agentKind == .claude else { return [] }
        return configuration.delegationAgents.filter { $0 != .claude }
    }

    /// Runs `arguments.prompt` with another agent CLI in the session's folder and
    /// returns its final answer. Its events go to the session's log under the
    /// thread of the `delegate_to_agent` tool use, so the phone can follow it.
    public func delegate(sessionId: String, arguments: JSONValue) async -> DelegationResult {
        guard let parent = sessions[sessionId], parent.record.summary.state != .closed else {
            return DelegationResult(text: "The Pilothouse session is no longer active.", isError: true)
        }
        let agent = AgentKind(arguments["agent"]?.stringValue ?? "")
        let prompt = arguments["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard delegationAgents(for: sessionId).contains(agent) else {
            return DelegationResult(text: "\(agent.displayName) is not enabled for delegation on this Mac.", isError: true)
        }
        guard !prompt.isEmpty else { return DelegationResult(text: "The prompt is empty.", isError: true) }

        let thread = claimDelegateCall(sessionId: sessionId, arguments: arguments) ?? "delegate-\(UUID().uuidString.lowercased())"
        let summary = parent.record.summary
        let options = ClaudeLaunchOptions(
            sessionId: UUID().uuidString.lowercased(), resume: false,
            model: arguments["model"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            permissionMode: summary.permissionMode, workingDirectory: summary.cwd, permissionServer: nil, agent: agent
        )
        let process: ChildProcess
        var adapter: any AgentAdapter
        do {
            let launcher = try await launcher(agent)
            process = try await launcher.launch(options)
            adapter = launcher.makeAdapter(for: options)
        } catch {
            let text = (error as? ErrorPayload)?.message ?? "\(error)"
            append(.systemNotice(.init(kind: "launchFailed", level: .error, text: "Could not start \(agent.displayName): \(text)")), to: sessionId, thread: thread)
            return DelegationResult(text: "Could not start \(agent.displayName): \(text)", isError: true)
        }
        log.info("Delegating to \(agent.displayName) (pid \(process.pid)) for session \(sessionId), thread \(thread)")
        append(.userMessage(.init(text: prompt)), to: sessionId, thread: thread)
        var lines = adapter.startupLines()
        lines += (try? adapter.userMessageLines(text: prompt, attachments: [])) ?? []
        delegations[thread] = Delegation(parentId: sessionId, agent: agent, process: process, adapter: adapter)
        for line in lines { try? await process.write(line) }

        let stdoutLines = process.stdout.lines()
        Task { [weak self] in
            for await line in stdoutLines {
                await self?.handleDelegationLine(line, thread: thread)
            }
            await self?.finishDelegation(thread, with: nil)
        }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.delegationTimeout))
            await self?.finishDelegation(thread, with: DelegationResult(
                text: "\(agent.displayName) did not finish within \(Int(Self.delegationTimeout / 60)) minutes and was stopped.", isError: true
            ))
        }
        let result = await withCheckedContinuation { continuation in
            if delegations[thread] != nil {
                delegations[thread]?.finish = continuation
            } else {
                continuation.resume(returning: DelegationResult(text: "\(agent.displayName) stopped.", isError: true))
            }
        }
        timeout.cancel()
        Task { await process.terminate(grace: 2) }
        return result
    }

    /// The `delegate_to_agent` tool use whose input matches, if Claude's
    /// stream-json reported it before the MCP call arrived.
    private func claimDelegateCall(sessionId: String, arguments: JSONValue) -> String? {
        guard var calls = unclaimedDelegateCalls[sessionId], !calls.isEmpty else { return nil }
        let index = calls.firstIndex { $0.input["prompt"] == arguments["prompt"] } ?? 0
        let call = calls.remove(at: index)
        unclaimedDelegateCalls[sessionId] = calls
        return call.toolUseId
    }

    private func handleDelegationLine(_ line: String, thread: String) {
        guard let parentId = delegations[thread]?.parentId,
            let output = delegations[thread]?.adapter.consume(line: line),
            let process = delegations[thread]?.process
        else { return }
        for event in output.events {
            append(event, to: parentId, thread: thread)
            if case .assistantMessage(let message) = event {
                delegations[thread]?.lastAnswer = message.text
            }
        }
        if !output.writes.isEmpty {
            Task { for write in output.writes { try? await process.write(write) } }
        }
        for request in output.permissionRequests {
            Task { await self.answerDelegation(request, thread: thread) }
        }
        for event in output.events {
            if case .result(let result) = event {
                let answer = delegations[thread]?.lastAnswer ?? ""
                let text = answer.isEmpty ? (result.text ?? "The agent finished without an answer.") : answer
                finishDelegation(thread, with: DelegationResult(text: text, isError: result.isError))
            }
        }
    }

    private func answerDelegation(_ request: AgentPermissionRequest, thread: String) async {
        guard let parentId = delegations[thread]?.parentId else { return }
        var input = request.input
        if var object = input.objectValue {
            object["agent"] = .string(delegations[thread]?.agent.displayName ?? "")
            input = .object(object)
        }
        let result = await decidePermission(sessionId: parentId, tool: request.tool, input: input, toolUseId: request.toolUseId)
        guard let delegation = delegations[thread] else { return }
        let allow = if case .allow = result { true } else { false }
        if let reply = delegation.adapter.permissionReply(to: request, allow: allow) {
            try? await delegation.process.write(reply)
        }
    }

    /// Resumes the waiting `delegate` call once (`nil` = the process ended).
    private func finishDelegation(_ thread: String, with result: DelegationResult?) {
        guard let delegation = delegations.removeValue(forKey: thread) else { return }
        let outcome = result ?? DelegationResult(
            text: delegation.lastAnswer.isEmpty ? "\(delegation.agent.displayName) stopped before it finished." : delegation.lastAnswer,
            isError: delegation.lastAnswer.isEmpty
        )
        if result == nil || outcome.isError {
            append(.systemNotice(.init(
                kind: outcome.isError ? "delegationFailed" : "delegationFinished", level: outcome.isError ? .warning : .info,
                text: outcome.isError ? outcome.text : "\(delegation.agent.displayName) finished."
            )), to: delegation.parentId, thread: thread)
        }
        delegation.finish?.resume(returning: outcome)
        if result != nil {
            Task { await delegation.process.terminate(grace: 2) }
        }
    }

    private func stopDelegations(of parentId: String, reason: String) async {
        for (thread, delegation) in delegations where delegation.parentId == parentId {
            finishDelegation(thread, with: DelegationResult(text: reason, isError: true))
        }
        unclaimedDelegateCalls.removeValue(forKey: parentId)
    }

    /// Sends a user message through the session's adapter.
    private func writeUserMessage(text: String, attachments: [MessageAttachment], to id: String) async throws {
        guard let process = currentProcess(id) else { throw Self.notFound }
        guard let lines = try sessions[id]?.adapter.userMessageLines(text: text, attachments: attachments) else { return }
        for line in lines { try await process.write(line) }
    }

    // MARK: Events

    /// Persists (unless ephemeral) and broadcasts one event; updates the record.
    /// Events of a sub-agent `thread` never change the session's own state.
    private func append(_ event: SessionEvent, to id: String, thread: String? = nil) {
        guard let session = sessions[id] else { return }
        let sequenced: SequencedEvent
        if event.isEphemeral {
            sequenced = SequencedEvent(seq: (try? session.log.lastSeq) ?? 0, timestamp: Date(), ephemeral: true, event: event, thread: thread)
        } else {
            do {
                sequenced = try session.log.append(event, thread: thread)
            } catch {
                log.error("Could not write event log for \(id): \(error)")
                return
            }
            update(id) { record in
                record.summary.lastSeq = sequenced.seq
                record.summary.updatedAt = sequenced.timestamp
                guard thread == nil else { return }
                switch event {
                case .sessionInfo(let info):
                    if let model = info.model { record.summary.model = model }
                    if record.summary.agentKind != .claude, !info.claudeSessionId.isEmpty {
                        record.agentSessionId = info.claudeSessionId
                    }
                    if !info.slashCommands.isEmpty { record.summary.slashCommands = info.slashCommands }
                case .assistantMessage(let message):
                    record.summary.lastMessagePreview = message.text
                    record.established = true
                case .toolUse:
                    record.established = true
                case .result:
                    record.established = true
                    if record.summary.state.isBusy { record.summary.state = .idle }
                default:
                    break
                }
            }
            if case .systemNotice(let notice) = event, notice.kind == "interrupted" {
                sessions[id]?.sawInterruptNotice = true
            }
        }
        for continuation in sessions[id]?.subscribers.values ?? [:].values {
            continuation.yield(sequenced)
        }
    }

    private func update(_ id: String, _ change: (inout SessionRecord) -> Void) {
        guard var record = sessions[id]?.record else { return }
        change(&record)
        sessions[id]?.record = record
    }

    private func setState(_ state: SessionState, for id: String) {
        update(id) { $0.summary.state = state }
    }

    private func persistAndPublish(_ id: String) async {
        guard let record = sessions[id]?.record else { return }
        await store.upsert(record)
        await hub.post(.sessionUpdated(record.summary))
    }

    private func removeSubscriber(_ subscriberId: UUID, from id: String) {
        sessions[id]?.subscribers.removeValue(forKey: subscriberId)
    }

    // MARK: Helpers

    static let notFound = ErrorPayload(code: .notFound, message: "This session no longer exists on the Mac.")

    private func logURL(_ id: String) -> URL {
        configuration.sessionsDirectory.appendingPathComponent("\(id).jsonl")
    }

    static func title(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(59)) + "…" : trimmed
    }

    static func validate(_ attachments: [MessageAttachment]) throws {
        guard attachments.count <= maximumAttachments else {
            throw ErrorPayload(code: .invalidRequest, message: "At most \(maximumAttachments) images per message.")
        }
        for attachment in attachments {
            guard MessageAttachment.supportedMediaTypes.contains(attachment.mediaType) else {
                throw ErrorPayload(code: .invalidRequest, message: "Unsupported attachment type \(attachment.mediaType).")
            }
            guard attachment.data.count <= MessageAttachment.maxBytes else {
                throw ErrorPayload(code: .invalidRequest, message: "Images must be smaller than 5 MB.")
            }
        }
    }

    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Base64URL.encode(Data(bytes))
    }
}
