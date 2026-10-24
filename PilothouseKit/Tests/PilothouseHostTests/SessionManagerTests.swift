import Foundation
import PilothouseKit
import Testing
@testable import PilothouseHost

/// Session lifecycle against FakeClaude (a shell script speaking stream-json),
/// including the real loopback MCP permission server reached via curl.
@Suite(.serialized, .timeLimit(.minutes(2))) struct SessionManagerTests {
    final class Harness: Sendable {
        let home: TemporaryHome
        let runtime: HostRuntime
        let argsLog: URL

        init(retentionDays: Int = 30, allowBypass: Bool = false, permissionTimeout: Duration = .seconds(600)) async throws {
            home = try TemporaryHome()
            try home.makeDirectory("project")
            let tools = try home.makeDirectory(".tools")
            let fake = try Fixtures.installFakeClaude(in: tools)
            let argsLog = home.url.appendingPathComponent("args.log")
            self.argsLog = argsLog
            let configuration = HostConfiguration(
                homeDirectory: home.path,
                dataDirectory: home.url.appendingPathComponent("Library/Pilothouse"),
                retentionDays: retentionDays,
                allowBypassPermissions: allowBypass
            )
            runtime = try HostRuntime(
                configuration: configuration,
                identity: .generate(),
                serverVersion: "test",
                status: TestStatusProvider(),
                macName: { "Test Mac" },
                permissionTimeout: permissionTimeout,
                launcher: { FakeClaudeLauncher(executable: fake, argsLog: argsLog) }
            )
            await runtime.start()
        }

        var sessions: SessionManager { runtime.sessions }

        func launchedArguments() -> [String] {
            ((try? String(contentsOf: argsLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func tearDown() async {
            await runtime.shutdown()
            home.remove()
        }
    }

    @Test func modelAndEffortChangeRestartsTheCLIWithNewFlags() async throws {
        let harness = try await Harness()
        defer { Task { await harness.tearDown() } }
        let summary = try await harness.sessions.start(StartSession(cwd: "~/project", model: "sonnet", effort: "high"))
        #expect(summary.effort == "high")
        var stream = try await harness.sessions.subscribe(summary.id, fromSeq: 1)
        try await harness.sessions.send(SendMessage(sessionId: summary.id, text: "Hi"))
        _ = try await collect(stream) { $0.resultCount == 1 }

        let updated = try await harness.sessions.updateSettings(UpdateSessionSettings(sessionId: summary.id, model: "opus", effort: "max"))
        #expect(updated.model == "opus")
        #expect(updated.effort == "max")
        stream = try await harness.sessions.subscribe(summary.id, fromSeq: updated.lastSeq + 1)
        try await harness.sessions.send(SendMessage(sessionId: summary.id, text: "Again"))
        _ = try await collect(stream) { $0.resultCount == 1 }
        #expect(harness.launchedArguments() == [
            "session=\(summary.id) resume=no model=sonnet mode=default effort=high",
            "session=\(summary.id) resume=yes model=opus mode=default effort=max",
        ])

        // Back to the defaults: no flags at all.
        let reset = try await harness.sessions.updateSettings(UpdateSessionSettings(sessionId: summary.id, model: "", effort: ""))
        #expect(reset.effort == nil)
        await #expect(throws: ErrorPayload.self) {
            try await harness.sessions.updateSettings(UpdateSessionSettings(sessionId: summary.id, effort: "turbo"))
        }
    }

    @Test func startStreamsAndPersistsATurn() async throws {
        let harness = try await Harness()
        let summary = try await harness.sessions.start(StartSession(cwd: "~/project", model: "sonnet"))
        #expect(summary.cwd == harness.home.path + "/project")
        #expect(summary.title == "project")
        // Subscribe before sending: streaming deltas are live-only.
        let stream = try await harness.sessions.subscribe(summary.id, fromSeq: 1)
        try await harness.sessions.send(SendMessage(sessionId: summary.id, text: "Say hello"))
        #expect(await harness.sessions.summary(summary.id)?.title == "Say hello")
        let events = try await collect(stream) { $0.resultCount == 1 }

        let types = events.persisted.map(\.event.typeName)
        #expect(types.contains("sessionInfo"))
        #expect(types.contains("userMessage"))
        #expect(types.contains("assistantMessage"))
        #expect(types.last == "result")
        #expect(events.contains { $0.ephemeral && $0.event.typeName == "assistantTextDelta" })
        #expect(events.persisted.map(\.seq) == Array(1...events.persisted.count))

        let after = try #require(await harness.sessions.summary(summary.id))
        #expect(after.state == .idle)
        #expect(after.lastMessagePreview == "Hello from FakeClaude")
        #expect(after.model == "fake-sonnet")
        #expect(after.slashCommands == ["review", "compact"])
        #expect(harness.launchedArguments().first == "session=\(summary.id) resume=no model=sonnet mode=default")

        // Replay from the middle.
        let replay = try await harness.sessions.subscribe(summary.id, fromSeq: 3)
        let replayed = try await collect(replay) { $0.last?.seq == after.lastSeq }
        #expect(replayed.first?.seq == 3)
        await harness.tearDown()
    }

    @Test func interruptStopsTheTurnAndTheNextMessageResumes() async throws {
        let harness = try await Harness()
        let summary = try await harness.sessions.start(StartSession(cwd: "~/project", firstMessage: "Hello"))
        let stream = try await harness.sessions.subscribe(summary.id, fromSeq: 1)
        var iterator = stream.makeAsyncIterator()
        func next(until predicate: (SequencedEvent) -> Bool) async -> SequencedEvent? {
            while let event = await iterator.next() {
                if predicate(event) { return event }
            }
            return nil
        }
        _ = await next { $0.event.isResult }

        try await harness.sessions.send(SendMessage(sessionId: summary.id, text: "Do something SLOW"))
        _ = await next { $0.ephemeral }  // streaming started
        #expect(await harness.sessions.summary(summary.id)?.state == .running)
        try await harness.sessions.interrupt(summary.id)
        let notice = await next { $0.event.notice?.kind == "interrupted" }
        #expect(notice != nil)
        let result = await next { $0.event.isResult }
        if case .result(let turn)? = result?.event { #expect(turn.subtype == "error_during_execution") }

        // Wait for the process exit to be processed, then continue the conversation.
        for _ in 0..<100 where await harness.sessions.activeSessions().contains(where: { $0.id == summary.id }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await harness.sessions.summary(summary.id)?.state == .idle)
        try await harness.sessions.send(SendMessage(sessionId: summary.id, text: "ECHOARGS"))
        let echoed = await next {
            if case .assistantMessage(let message) = $0.event { return message.text.hasPrefix("session=") }
            return false
        }
        if case .assistantMessage(let message)? = echoed?.event {
            #expect(message.text == "session=\(summary.id) resume=yes model=default mode=default")
        }
        await harness.tearDown()
    }

    @Test func closeAndResume() async throws {
        let harness = try await Harness()
        let summary = try await harness.sessions.start(StartSession(cwd: "~/project", firstMessage: "Hello"))
        let stream = try await harness.sessions.subscribe(summary.id, fromSeq: 1)
        _ = try await collect(stream) { $0.resultCount == 1 }
        try await harness.sessions.close(summary.id)
        #expect(await harness.sessions.summary(summary.id)?.state == .closed)
        await #expect(throws: ErrorPayload.self) {
            try await harness.sessions.send(SendMessage(sessionId: summary.id, text: "still there?"))
        }
        for _ in 0..<100 where !(await harness.sessions.activeSessions().isEmpty) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let resumed = try await harness.sessions.resume(summary.id)
        #expect(resumed.state == .idle)
        for _ in 0..<100 where harness.launchedArguments().count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(harness.launchedArguments().last?.contains("resume=yes") == true)
        await harness.tearDown()
    }

    @Test func messageRightAfterStopIsNotLost() async throws {
        let harness = try await Harness()
        let summary = try await harness.sessions.start(StartSession(cwd: "~/project"))
        let stream = try await harness.sessions.subscribe(summary.id, fromSeq: 1)
        try await harness.sessions.send(SendMessage(sessionId: summary.id, text: "SLOW"))
        var iterator = stream.makeAsyncIterator()
        while let event = await iterator.next(), !event.ephemeral {}
        try await harness.sessions.interrupt(summary.id)
        // No waiting: the next message must reach a fresh CLI.
        try await harness.sessions.send(SendMessage(sessionId: summary.id, text: "Hello again"))
        var greeted = false
        while let event = await iterator.next() {
            if case .assistantMessage(let message) = event.event, message.text == "Hello from FakeClaude" {
                greeted = true
                break
            }
        }
        #expect(greeted)
        #expect(harness.launchedArguments().count == 2)
        await harness.tearDown()
    }

    @Test func resumeRightAfterCloseStartsAFreshProcess() async throws {
        let harness = try await Harness()
        let summary = try await harness.sessions.start(StartSession(cwd: "~/project"))
        let stream = try await harness.sessions.subscribe(summary.id, fromSeq: 1)
        try await harness.sessions.send(SendMessage(sessionId: summary.id, text: "Hello"))
        _ = try await collect(stream) { $0.resultCount == 1 }
        try await harness.sessions.close(summary.id)
        _ = try await harness.sessions.resume(summary.id)
        try await harness.sessions.send(SendMessage(sessionId: summary.id, text: "ECHOARGS"))
        let events = try await collect(stream) { $0.resultCount == 1 }
        let echoed = events.compactMap { event -> String? in
            if case .assistantMessage(let message) = event.event { message.text } else { nil }
        }
        #expect(echoed.contains("session=\(summary.id) resume=yes model=default mode=default"))
        await harness.tearDown()
    }

    @Test func crashAndLoginProblemsBecomeNotices() async throws {
        let harness = try await Harness()
        let summary = try await harness.sessions.start(StartSession(cwd: "~/project", firstMessage: "CRASH please"))
        let stream = try await harness.sessions.subscribe(summary.id, fromSeq: 1)
        let crashed = try await collect(stream) { events in events.contains { $0.event.notice?.kind == "processExited" } }
        let notice = try #require(crashed.compactMap(\.event.notice).first { $0.kind == "processExited" })
        #expect(notice.text.contains("exit code 3"))
        #expect(notice.text.contains("simulated crash"))
        #expect(await harness.sessions.summary(summary.id)?.state == .idle)

        try await harness.sessions.send(SendMessage(sessionId: summary.id, text: "LOGIN"))
        let login = try await collect(stream) { events in events.contains { $0.event.notice?.kind == "loginRequired" } }
        #expect(login.last?.event.notice?.text.contains("claude") == true)
        await harness.tearDown()
    }

    @Test func permissionRequestsReachThePhoneAndAreRemembered() async throws {
        let harness = try await Harness()
        let notifications = await harness.runtime.hub.stream()
        let summary = try await harness.sessions.start(StartSession(cwd: "~/project"))
        let stream = try await harness.sessions.subscribe(summary.id, fromSeq: 1)
        try await harness.sessions.send(SendMessage(sessionId: summary.id, text: "PERMISSION"))

        var iterator = notifications.makeAsyncIterator()
        var request: PermissionRequest?
        while let notification = await iterator.next() {
            if case .permissionRequest(let incoming) = notification {
                request = incoming
                break
            }
        }
        let pending = try #require(request)
        #expect(pending.tool == "Bash")
        #expect(pending.input["command"]?.stringValue == "echo hi")
        #expect(pending.sessionId == summary.id)
        #expect(await harness.sessions.summary(summary.id)?.state == .awaitingPermission)
        try await harness.runtime.broker.respond(PermissionResponse(requestId: pending.id, allow: true, remember: true))

        let first = try await collect(stream) { $0.resultCount == 1 }
        let decision = first.compactMap { event -> SessionEvent.PermissionDecision? in
            if case .permissionDecision(let decision) = event.event { decision } else { nil }
        }.first
        #expect(decision?.outcome == .allowedForSession)
        #expect(first.contains { if case .toolResult(let result) = $0.event { result.output == "hi" } else { false } })

        // Second time the remembered rule answers without asking.
        try await harness.sessions.send(SendMessage(sessionId: summary.id, text: "PERMISSION again"))
        let second = try await collect(stream) { $0.resultCount == 1 }
        #expect(second.contains { if case .permissionDecision(let decision) = $0.event { decision.outcome == .allowedForSession } else { false } })
        #expect(await harness.runtime.broker.pendingRequests.isEmpty)
        await harness.tearDown()
    }

    @Test func deniedAndTimedOutPermissions() async throws {
        let harness = try await Harness(permissionTimeout: .milliseconds(500))
        let summary = try await harness.sessions.start(StartSession(cwd: "~/project"))
        let stream = try await harness.sessions.subscribe(summary.id, fromSeq: 1)
        try await harness.sessions.send(SendMessage(sessionId: summary.id, text: "PERMISSION"))
        let events = try await collect(stream) { $0.resultCount == 1 }
        #expect(events.contains { if case .permissionDecision(let decision) = $0.event { decision.outcome == .timedOut } else { false } })
        #expect(events.contains { if case .toolResult(let result) = $0.event { result.isError } else { false } })
        await harness.tearDown()
    }

    @Test func fileEditsBecomeDiffs() async throws {
        let harness = try await Harness()
        let summary = try await harness.sessions.start(StartSession(cwd: "~/project", firstMessage: "EDIT"))
        let stream = try await harness.sessions.subscribe(summary.id, fromSeq: 1)
        let events = try await collect(stream) { $0.resultCount == 1 }
        let edit = events.compactMap { event -> SessionEvent.FileEdit? in if case .fileEdit(let edit) = event.event { edit } else { nil } }.first
        #expect(edit?.diff == "@@ -1,3 +1,3 @@\n one\n-two\n+three\n four")
        await harness.tearDown()
    }

    @Test func validationErrors() async throws {
        let harness = try await Harness()
        await #expect(throws: ErrorPayload.self) { try await harness.sessions.start(StartSession(cwd: "/etc")) }
        await #expect(throws: ErrorPayload.self) { try await harness.sessions.start(StartSession(cwd: "~/missing")) }
        do {
            _ = try await harness.sessions.start(StartSession(cwd: "~/project", permissionMode: .bypassPermissions))
            Issue.record("bypassPermissions must be refused")
        } catch let error as ErrorPayload {
            #expect(error.code == .modeNotAllowed)
        }
        let summary = try await harness.sessions.start(StartSession(cwd: "~"))
        #expect(summary.title == "~")
        await #expect(throws: ErrorPayload.self) {
            try await harness.sessions.send(SendMessage(sessionId: summary.id, text: "  "))
        }
        await #expect(throws: ErrorPayload.self) {
            try await harness.sessions.send(SendMessage(
                sessionId: summary.id, text: "x",
                attachments: [MessageAttachment(mediaType: "application/zip", data: Data())]
            ))
        }
        await #expect(throws: ErrorPayload.self) { try await harness.sessions.interrupt("nope") }
        await harness.tearDown()
    }

    @Test func deleteRemovesTheLog() async throws {
        let harness = try await Harness()
        let summary = try await harness.sessions.start(StartSession(cwd: "~/project", firstMessage: "Hello"))
        let stream = try await harness.sessions.subscribe(summary.id, fromSeq: 1)
        _ = try await collect(stream) { $0.resultCount == 1 }
        let logPath = harness.home.path + "/Library/Pilothouse/sessions/\(summary.id).jsonl"
        #expect(FileManager.default.fileExists(atPath: logPath))
        try await harness.sessions.delete(summary.id)
        #expect(!FileManager.default.fileExists(atPath: logPath))
        #expect(await harness.sessions.summaries().isEmpty)
        await harness.tearDown()
    }

    @Test func retentionAndCrashRecoveryOnBootstrap() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let data = home.url.appendingPathComponent("Library/Pilothouse")
        let store = SessionStore(url: data.appendingPathComponent("sessions.json"))
        let old = Date().addingTimeInterval(-40 * 86_400)
        await store.upsert(SessionRecord(summary: SessionSummary(id: "old", cwd: home.path, title: "Old", createdAt: old, updatedAt: old)))
        await store.upsert(SessionRecord(summary: SessionSummary(id: "busy", cwd: home.path, title: "Busy", createdAt: Date(), updatedAt: Date(), state: .running)))
        let oldLog = EventLog(url: data.appendingPathComponent("sessions/old.jsonl"))
        _ = try oldLog.append(.userMessage(.init(text: "x")))
        oldLog.close()

        let manager = SessionManager(
            configuration: HostConfiguration(homeDirectory: home.path, dataDirectory: data, retentionDays: 30),
            broker: PermissionBroker(hub: NotificationHub()),
            hub: NotificationHub(),
            launcher: { throw ErrorPayload(code: .claudeNotInstalled, message: "none") }
        )
        await manager.bootstrap()
        let ids = await manager.summaries().map(\.id)
        #expect(ids == ["busy"])
        #expect(await manager.summary("busy")?.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: data.appendingPathComponent("sessions/old.jsonl").path))

        do {
            _ = try await manager.start(StartSession(cwd: "~"))
            Issue.record("Expected claudeNotInstalled")
        } catch let error as ErrorPayload {
            #expect(error.code == .claudeNotInstalled)
        }
    }
}

@Suite struct PairingTests {
    @Test func tokensAreSingleUseAndExpire() async {
        let pairing = PairingManager()
        let now = Date()
        let (token, expiresAt) = await pairing.createToken(now: now)
        #expect(expiresAt.timeIntervalSince(now) == 300)
        #expect(await !pairing.consume("wrong", now: now))
        #expect(await pairing.consume(token, now: now))
        #expect(await !pairing.consume(token, now: now))
        let (late, _) = await pairing.createToken(now: now)
        #expect(await !pairing.consume(late, now: now.addingTimeInterval(301)))
    }

    @Test func constantTimeComparison() {
        #expect(PairingManager.constantTimeEquals("abc", "abc"))
        #expect(!PairingManager.constantTimeEquals("abc", "abd"))
        #expect(!PairingManager.constantTimeEquals("abc", "abcd"))
    }

    @Test func registryPairsConnectsAndRevokes() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let hub = NotificationHub()
        let pairing = PairingManager()
        let url = home.url.appendingPathComponent("devices.json")
        let registry = DeviceRegistry(url: url, pairing: pairing, hub: hub)
        let phone = IdentityKeyPair.generate()
        let connect = ClientHandshakePayload(mode: .connect, deviceName: "iPhone", platform: "iOS", appVersion: "1")

        guard case .reject(let unknown) = await registry.authorize(publicKey: phone.publicKey, hello: connect) else {
            Issue.record("Unknown device must be rejected")
            return
        }
        #expect(unknown.code == .unauthorized)

        let (token, _) = await pairing.createToken()
        let pair = ClientHandshakePayload(mode: .pair, pairingToken: token, deviceName: "iPhone", platform: "iOS", appVersion: "1")
        guard case .accept = await registry.authorize(publicKey: phone.publicKey, hello: pair) else {
            Issue.record("Pairing with a valid token must succeed")
            return
        }
        guard case .reject(let reused) = await registry.authorize(publicKey: IdentityKeyPair.generate().publicKey, hello: pair) else {
            Issue.record("Token reuse must fail")
            return
        }
        #expect(reused.code == .pairingTokenInvalid)
        guard case .accept = await registry.authorize(publicKey: phone.publicKey, hello: connect) else {
            Issue.record("Paired device must connect")
            return
        }
        #expect(await DeviceRegistry(url: url, pairing: pairing, hub: hub).all.count == 1)

        let notifications = await hub.stream()
        await registry.revoke(phone.fingerprint)
        var iterator = notifications.makeAsyncIterator()
        guard case .disconnectDevice(let deviceId, let reason) = await iterator.next() else {
            Issue.record("Revocation must disconnect the device")
            return
        }
        #expect(deviceId == phone.fingerprint)
        #expect(reason.code == .deviceRevoked)
        guard case .reject = await registry.authorize(publicKey: phone.publicKey, hello: connect) else {
            Issue.record("Revoked device must be rejected")
            return
        }
    }
}

/// The whole Mac stack minus Network.framework: `MacClient` → Noise channel →
/// `ServerEndpoint` → `MacHostService` → `SessionManager` → FakeClaude → MCP → phone.
@Suite(.timeLimit(.minutes(1))) struct FullStackTests {
    struct LoopbackConnector: TransportConnector {
        let endpoint: ServerEndpoint
        func connect(to endpoint: Endpoint, timeout: Double) async throws -> any MessageTransport {
            let (client, server) = InMemoryTransport.makePair()
            let serverEndpoint = self.endpoint
            Task { await serverEndpoint.accept(server) }
            return client
        }
    }

    @Test func pairStartChatApproveAndRevoke() async throws {
        let harness = try await SessionManagerTests.Harness()
        let runtime = harness.runtime
        let connector = LoopbackConnector(endpoint: runtime.endpoint)
        let phone = IdentityKeyPair.generate()
        let device = DeviceInfo(name: "Arda's iPhone", platform: "iOS", appVersion: "1.0")

        let payload = await runtime.makePairingPayload(macName: "Test Mac", localAddresses: ["192.168.1.2"], tailscale: .notInstalled, port: 47823)
        let mac = try await MacClient.pair(payload: payload, identity: phone, device: device, connector: connector)
        #expect(mac.id == runtime.identity.fingerprint)
        #expect(await runtime.devices.all.map(\.name) == ["Arda's iPhone"])

        let client = MacClient(mac: mac, identity: phone, device: device, connector: connector)
        await client.start()
        for await state in client.states where state.isConnected { break }
        let pushes = client.pushes

        guard case .directoryListing(let listing) = try await client.request(.listDirectory(ListDirectory())) else {
            Issue.record("Expected a listing")
            return
        }
        #expect(listing.entries.contains { $0.name == "project" && $0.isDirectory })

        guard case .sessionStarted(let started) = try await client.request(.startSession(StartSession(cwd: "~/project"))) else {
            Issue.record("Expected sessionStarted")
            return
        }
        let sessionId = started.session.id
        _ = try await client.request(.subscribe(Subscribe(sessionId: sessionId, fromSeq: 1)))
        _ = try await client.request(.sendMessage(SendMessage(sessionId: sessionId, text: "PERMISSION")))

        var approved = false
        var finished = false
        for await message in pushes {
            switch message {
            case .permissionRequest(let request):
                _ = try await client.request(.permissionResponse(PermissionResponse(requestId: request.id, allow: true)))
                approved = true
            case .event(let event) where event.sessionId == sessionId:
                if case .result = event.payload { finished = true }
            default:
                break
            }
            if finished { break }
        }
        #expect(approved)

        // Revoking the phone drops it immediately and it cannot reconnect.
        await runtime.devices.revoke(phone.fingerprint)
        for await state in client.states {
            if case .failed(_, let code) = state {
                #expect(code == .deviceRevoked || code == .unauthorized)
                break
            }
        }
        await client.stop()
        await harness.tearDown()
    }
}
