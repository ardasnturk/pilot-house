import Foundation
import Testing
@testable import PilothouseKit

/// End-to-end: `MacClient` ⇄ encrypted channel ⇄ `ServerEndpoint` ⇄ `DemoHostService`.
@Suite(.timeLimit(.minutes(1))) struct ClientServerTests {
    let device = DeviceInfo(name: "Test iPhone", platform: "iOS", appVersion: "1.0")

    func connectedClient(pace: Double = 0) async throws -> (MacClient, DemoConnector) {
        let connector = DemoConnector(pace: pace)
        let client = MacClient(mac: connector.mac, identity: .generate(), device: device, connector: connector)
        await client.start()
        for await state in client.states where state.isConnected { break }
        return (client, connector)
    }

    @Test func connectsAndReceivesHelloAck() async throws {
        let (client, _) = try await connectedClient()
        var iterator = client.pushes.makeAsyncIterator()
        guard case .helloAck(let ack) = await iterator.next() else {
            Issue.record("First push must be helloAck")
            return
        }
        #expect(ack.macName == "Demo MacBook Pro")
        guard case .connected(let route, _) = await client.state else {
            Issue.record("Not connected")
            return
        }
        #expect(route == .demo)
        await client.stop()
    }

    @Test func listsSessionsAndDirectories() async throws {
        let (client, _) = try await connectedClient()
        guard case .sessionList(let list) = try await client.request(.listSessions) else {
            Issue.record("Expected sessionList")
            return
        }
        #expect(list.sessions.count == 3)
        #expect(list.sessions.first?.id == "demo-session-login")

        guard case .directoryListing(let home) = try await client.request(.listDirectory(ListDirectory())) else {
            Issue.record("Expected listing")
            return
        }
        #expect(home.path == "/Users/demo")
        #expect(home.entries.first?.isDirectory == true)
        #expect(!home.entries.contains { $0.isHidden })
        guard case .directoryListing(let dev) = try await client.request(.listDirectory(ListDirectory(path: "~/Developer"))) else {
            Issue.record("Expected listing")
            return
        }
        #expect(dev.entries.first { $0.name == "weather-app" }?.isGitRepository == true)
        await client.stop()
    }

    @Test func serverErrorsAreThrownAsErrorPayload() async throws {
        let (client, _) = try await connectedClient()
        await #expect(throws: ErrorPayload.self) {
            try await client.request(.listDirectory(ListDirectory(path: "/etc")))
        }
        do {
            _ = try await client.request(.listDirectory(ListDirectory(path: "/etc")))
        } catch let error as ErrorPayload {
            #expect(error.code == .pathOutsideHome)
        }
        await client.stop()
    }

    @Test func subscribeReplaysBacklogFromSequence() async throws {
        let (client, _) = try await connectedClient()
        let pushes = client.pushes
        _ = try await client.request(.subscribe(Subscribe(sessionId: "demo-session-login", fromSeq: 5)))
        var seqs: [Int] = []
        for await message in pushes {
            if case .event(let event) = message, event.sessionId == "demo-session-login" {
                seqs.append(event.seq)
                if event.seq == 12 { break }
            }
        }
        #expect(seqs == Array(5...12))
        await client.stop()
    }

    @Test func fullTurnWithPermissionApproval() async throws {
        let (client, _) = try await connectedClient()
        let pushes = client.pushes
        guard case .sessionStarted(let started) = try await client.request(.startSession(StartSession(
            cwd: "~/Developer/weather-app", model: "sonnet", permissionMode: .default
        ))) else {
            Issue.record("Expected sessionStarted")
            return
        }
        let sessionId = started.session.id
        #expect(started.session.cwd == "/Users/demo/Developer/weather-app")
        _ = try await client.request(.subscribe(Subscribe(sessionId: sessionId, fromSeq: 1)))
        _ = try await client.request(.sendMessage(SendMessage(sessionId: sessionId, text: "Fix the flaky test")))

        var sawDelta = false
        var toolNames: [String] = []
        var permissions = 0
        var sawEdit = false
        var result: SessionEvent.TurnResult?
        for await message in pushes {
            switch message {
            case .permissionRequest(let request):
                permissions += 1
                #expect(request.sessionId == sessionId)
                _ = try await client.request(.permissionResponse(PermissionResponse(requestId: request.id, allow: true)))
            case .event(let payload) where payload.sessionId == sessionId:
                switch payload.payload {
                case .assistantTextDelta: sawDelta = true
                case .toolUse(let use): toolNames.append(use.name)
                case .fileEdit: sawEdit = true
                case .result(let turn): result = turn
                default: break
                }
            default:
                break
            }
            if result != nil { break }
        }
        #expect(sawDelta)
        #expect(toolNames == ["Glob", "Grep", "TodoWrite", "Edit", "Bash"])
        #expect(permissions == 2)
        #expect(sawEdit)
        #expect(result?.isError == false)
        await client.stop()
    }

    @Test func deniedPermissionStopsTheTurn() async throws {
        let (client, _) = try await connectedClient()
        let pushes = client.pushes
        guard case .sessionStarted(let started) = try await client.request(.startSession(StartSession(cwd: "~/Developer/scripts"))) else {
            Issue.record("Expected sessionStarted")
            return
        }
        let sessionId = started.session.id
        _ = try await client.request(.subscribe(Subscribe(sessionId: sessionId, fromSeq: 1)))
        _ = try await client.request(.sendMessage(SendMessage(sessionId: sessionId, text: "Go")))
        var outcome: SessionEvent.PermissionDecision.Outcome?
        var resolved = false
        for await message in pushes {
            if case .permissionRequest(let request) = message {
                _ = try await client.request(.permissionResponse(PermissionResponse(requestId: request.id, allow: false)))
            }
            if case .permissionResolved(let event) = message { resolved = event.outcome == .denied }
            if case .event(let payload) = message, case .permissionDecision(let decision) = payload.payload {
                outcome = decision.outcome
            }
            if case .event(let payload) = message, case .result = payload.payload { break }
        }
        #expect(outcome == .denied)
        #expect(resolved)
        await client.stop()
    }

    @Test func requestsFailFastWhenDisconnected() async throws {
        let connector = DemoConnector(pace: 0)
        let client = MacClient(mac: connector.mac, identity: .generate(), device: device, connector: connector)
        await #expect(throws: MacClientError.notConnected) {
            try await client.request(.listSessions)
        }
    }

    @Test func serverRequiresHelloFirst() async throws {
        let mac = IdentityKeyPair.generate()
        let service = DemoHostService(pace: 0)
        let endpoint = ServerEndpoint(identity: mac, macName: { "M" }, authorizer: DemoAuthorizer(), service: service)
        let (clientTransport, serverTransport) = InMemoryTransport.makePair()
        Task { await endpoint.accept(serverTransport) }
        let (channel, _) = try await SecureHandshake.initiate(
            over: clientTransport, identity: .generate(), macPublicKey: mac.publicKey,
            payload: ClientHandshakePayload(mode: .connect, deviceName: "P", platform: "iOS", appVersion: "1")
        )
        let request = ClientEnvelope(message: .listSessions)
        try channel.send(try PilothouseJSON.encode(request))
        let response = try PilothouseJSON.decode(ServerEnvelope.self, from: try await channel.receive())
        #expect(response.re == request.id)
        guard case .error(let error) = response.message else {
            Issue.record("Expected error")
            return
        }
        #expect(error.code == .invalidRequest)

        // A stale timestamp is refused even after hello.
        _ = try await MacClient.sayHello(over: channel, device: device)
        let stale = ClientEnvelope(ts: Date().addingTimeInterval(-3_600), message: .listSessions)
        try channel.send(try PilothouseJSON.encode(stale))
        let staleResponse = try PilothouseJSON.decode(ServerEnvelope.self, from: try await channel.receive())
        guard case .error(let staleError) = staleResponse.message else {
            Issue.record("Expected error")
            return
        }
        #expect(staleError.code == .clockSkew)
        await channel.close()
    }

    @Test func pairingStoresTheMac() async throws {
        let mac = IdentityKeyPair.generate()
        let token = "one-time-token"
        let authorizer = TestAuthorizer { _, hello in
            hello.mode == .connect || hello.pairingToken == token
                ? .accept : .reject(ErrorPayload(code: .pairingTokenInvalid, message: "Invalid code"))
        }
        let endpoint = ServerEndpoint(identity: mac, macName: { "Studio" }, authorizer: authorizer, service: DemoHostService(pace: 0))
        struct Connector: TransportConnector {
            let endpoint: ServerEndpoint
            func connect(to endpoint: Endpoint, timeout: Double) async throws -> any MessageTransport {
                guard case .hostPort(let host, _) = endpoint, host == "192.168.1.9" else {
                    throw TransportError.connectionFailed("unreachable")
                }
                let (client, server) = InMemoryTransport.makePair()
                let serverEndpoint = self.endpoint
                Task { await serverEndpoint.accept(server) }
                return client
            }
        }
        let payload = PairingPayload(
            name: "Studio", publicKey: mac.publicKey, localAddresses: ["10.9.9.9", "192.168.1.9"],
            tailscaleAddresses: [], magicDNSName: nil, port: 47823, token: token, expiresAt: Date().addingTimeInterval(60)
        )
        let paired = try await MacClient.pair(payload: payload, identity: .generate(), device: device, connector: Connector(endpoint: endpoint))
        #expect(paired.id == mac.fingerprint)
        // The name in helloAck (from the host service) wins over the QR code.
        #expect(paired.name == "Demo MacBook Pro")
        #expect(paired.lastSuccessfulHost == "192.168.1.9")

        var wrong = payload
        wrong.token = "guess"
        await #expect(throws: ErrorPayload.self) {
            try await MacClient.pair(payload: wrong, identity: .generate(), device: device, connector: Connector(endpoint: endpoint))
        }
    }
}

@Suite struct ConnectionPlanningTests {
    @Test func candidatesFollowPreferenceOrder() {
        let mac = PairedMac(
            id: "m", name: "Mac", publicKey: Data(count: 32),
            addresses: [
                HostAddress(host: "mac.tail.ts.net", kind: .magicDNS),
                HostAddress(host: "100.64.1.1", kind: .tailscale),
                HostAddress(host: "192.168.1.5", kind: .local),
            ],
            port: 47823, pairedAt: Date(), lastSuccessfulHost: "100.64.1.1", lastSuccessfulPort: 47824
        )
        let candidates = ConnectionPlanner.candidates(for: mac, bonjour: [.bonjour(name: "Mac", type: "_pilothouse._tcp", domain: "local.")])
        #expect(candidates.map(\.endpoint) == [
            .hostPort(host: "100.64.1.1", port: 47824),
            .bonjour(name: "Mac", type: "_pilothouse._tcp", domain: "local."),
            .hostPort(host: "192.168.1.5", port: 47823),
            .hostPort(host: "100.64.1.1", port: 47823),
            .hostPort(host: "mac.tail.ts.net", port: 47823),
        ])
        #expect(candidates.map(\.route) == [.tailscale, .local, .local, .tailscale, .tailscale])
    }

    @Test func preferenceFiltersRoutes() {
        let mac = PairedMac(
            id: "m", name: "Mac", publicKey: Data(count: 32),
            addresses: [HostAddress(host: "192.168.1.5", kind: .local), HostAddress(host: "100.64.1.1", kind: .tailscale)],
            port: 1, pairedAt: Date()
        )
        let bonjour: [Endpoint] = [.bonjour(name: "Mac", type: "_pilothouse._tcp", domain: "local.")]
        #expect(ConnectionPlanner.candidates(for: mac, bonjour: bonjour, preference: .localOnly).allSatisfy { $0.route == .local })
        #expect(ConnectionPlanner.candidates(for: mac, bonjour: bonjour, preference: .tailscaleOnly).map(\.endpoint) == [.hostPort(host: "100.64.1.1", port: 1)])
        #expect(ConnectionPlanner.candidates(for: mac, bonjour: bonjour).count == 3)
    }

    @Test func backoffGrowsAndCaps() {
        var backoff = Backoff(base: 1, cap: 8)
        let delays = (0..<6).map { _ in backoff.nextDelay(random: 1) }
        #expect(delays == [1, 2, 4, 8, 8, 8])
        backoff.reset()
        #expect(backoff.nextDelay(random: 0) == 0.5)
    }
}

@Suite struct ConcurrencyUtilityTests {
    @Test func asyncQueueDeliversInOrderAndFinishes() async throws {
        let queue = AsyncQueue<Int>()
        for value in 0..<5 { await queue.push(value) }
        await queue.finish()
        var values: [Int] = []
        while let value = try? await queue.pop() { values.append(value) }
        #expect(values == [0, 1, 2, 3, 4])
    }

    @Test func timeoutReturnsEvenIfOperationIgnoresCancellation() async {
        let start = Date()
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(seconds: 0.2) {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func timeoutPassesResultThrough() async throws {
        #expect(try await withTimeout(seconds: 5) { 42 } == 42)
    }
}
