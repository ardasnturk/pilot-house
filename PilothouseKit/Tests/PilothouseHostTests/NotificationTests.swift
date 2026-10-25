import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PilothouseKit
import Synchronization
import Testing
@testable import PilothouseHost

private func summary(_ state: SessionState, lastSeq: Int, id: String = "s1", cwd: String = "/Users/me/Projects/app") -> SessionSummary {
    SessionSummary(id: id, cwd: cwd, title: "app", createdAt: Date(), updatedAt: Date(), state: state, lastSeq: lastSeq)
}

private func result(isError: Bool = false, subtype: String = "success") -> SessionEvent {
    .result(.init(isError: isError, subtype: subtype, durationMs: 10, text: "done"))
}

@Suite struct NotificationRulesTests {
    let session = summary(.idle, lastSeq: 3)

    @Test func finishedTurnFromPhoneUsesLastAssistantMessage() throws {
        let events: [SessionEvent] = [
            .userMessage(.init(text: "hi", attachmentCount: 0)),
            .assistantMessage(.init(blockId: "a", text: "First")),
            .assistantMessage(.init(blockId: "b", text: "All tests pass.")),
            result(),
        ]
        let alert = try #require(NotificationRules.alert(for: events, session: session, fromPhone: true))
        #expect(alert.kind == .turnFinished)
        #expect(alert.folderName == "app")
        #expect(alert.detail == "All tests pass.")
    }

    @Test func turnsFromTheMacAreNotAnnounced() {
        #expect(NotificationRules.alert(for: [result()], session: session, fromPhone: false) == nil)
    }

    @Test func interruptedTurnsAreSilent() {
        let events: [SessionEvent] = [
            result(isError: true, subtype: "error_during_execution"),
            .systemNotice(.init(kind: "interrupted", level: .warning, text: "Interrupted.")),
        ]
        #expect(NotificationRules.alert(for: events, session: session, fromPhone: true) == nil)
    }

    @Test func crashesAreFailuresEvenForMacTurns() throws {
        let events: [SessionEvent] = [
            .systemNotice(.init(kind: "processExited", level: .error, text: "Claude Code stopped unexpectedly (exit 1).")),
        ]
        let alert = try #require(NotificationRules.alert(for: events, session: session, fromPhone: false))
        #expect(alert.kind == .sessionFailed)
        #expect(alert.detail == "Claude Code stopped unexpectedly (exit 1).")
    }

    @Test func errorResultsAreFailures() throws {
        let alert = try #require(NotificationRules.alert(for: [result(isError: true, subtype: "error_max_turns")], session: session, fromPhone: true))
        #expect(alert.kind == .sessionFailed)
    }

    @Test func turnsWithoutResultAreSilent() {
        #expect(NotificationRules.alert(for: [.userMessage(.init(text: "hi", attachmentCount: 0))], session: session, fromPhone: true) == nil)
    }

    @Test func bodyIsMinimalUnlessDetailsAreEnabled() {
        let alert = HostAlert(kind: .turnFinished, sessionId: "s1", folderName: "app", detail: "Line one\nline two")
        #expect(AlertContent.english(for: alert, includeDetail: false).body == "Task finished · app")
        #expect(AlertContent.english(for: alert, includeDetail: true).body == "Task finished · app\nLine one line two")
        let long = HostAlert(kind: .turnFinished, sessionId: "s1", folderName: "app", detail: String(repeating: "x", count: 500))
        let body = AlertContent.english(for: long, includeDetail: true).body
        #expect(body.count == "Task finished · app\n".count + AlertContent.maximumDetailLength)
        #expect(body.hasSuffix("…"))
    }
}

/// Records delivered alerts.
final class RecordingSink: AlertSink {
    private let alerts = Mutex<[HostAlert]>([])
    var delivered: [HostAlert] { alerts.withLock { $0 } }

    func deliver(_ alert: HostAlert, includeDetail: Bool) async throws {
        alerts.withLock { $0.append(alert) }
    }

    func waitForCount(_ count: Int) async -> [HostAlert] {
        for _ in 0..<500 where delivered.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return delivered
    }
}

@Suite struct NotificationServiceTests {
    /// A service whose event source replays `events` with seq 1, 2, …
    func makeService(events: [SessionEvent], sink: RecordingSink, preferences: NotificationPreferences = .init(enabled: true)) async -> (NotificationService, NotificationHub) {
        let hub = NotificationHub()
        let service = NotificationService(hub: hub, settleDelay: .zero) { _, fromSeq in
            AsyncStream { continuation in
                for (index, event) in events.enumerated() where index + 1 >= fromSeq {
                    continuation.yield(SequencedEvent(seq: index + 1, timestamp: Date(), event: event))
                }
            }
        }
        await service.configure(preferences, sinks: [sink])
        return (service, hub)
    }

    @Test func phoneTurnProducesTaskFinished() async throws {
        let sink = RecordingSink()
        let events: [SessionEvent] = [.userMessage(.init(text: "hi", attachmentCount: 0)), result()]
        let (service, _) = await makeService(events: events, sink: sink)
        await service.handle(.sessionStarted(summary(.starting, lastSeq: 0)))
        await service.noteTurnFromPhone("s1")
        await service.handle(.sessionUpdated(summary(.running, lastSeq: 1)))
        await service.handle(.sessionUpdated(summary(.idle, lastSeq: 2)))
        let delivered = await sink.waitForCount(1)
        #expect(delivered.map(\.kind) == [.turnFinished])
        #expect(delivered.first?.sessionId == "s1")
    }

    @Test func subAgentEventsDoNotDecideTheTurnAlert() async throws {
        // A delegated sub-agent was interrupted and failed; the main turn still finished.
        let (stream, continuation) = AsyncStream.makeStream(of: SequencedEvent.self)
        let events: [(SessionEvent, String?)] = [
            (.userMessage(.init(text: "hi", attachmentCount: 0)), nil),
            (.systemNotice(.init(kind: "interrupted", level: .warning, text: "Interrupted.")), "toolu_sub"),
            (.systemNotice(.init(kind: "loginRequired", level: .error, text: "Codex is not signed in.")), "toolu_sub"),
            (.assistantMessage(.init(blockId: "sub", text: "sub-agent text")), "toolu_sub"),
            (.assistantMessage(.init(blockId: "main", text: "Main answer")), nil),
            (result(), nil),
        ]
        for (index, (event, thread)) in events.enumerated() {
            continuation.yield(SequencedEvent(seq: index + 1, timestamp: Date(), event: event, thread: thread))
        }
        let collected = await NotificationService.collect(stream, through: events.count, timeout: .seconds(2))
        #expect(collected.count == 3)
        let alert = try #require(NotificationRules.alert(for: collected, session: summary(.idle, lastSeq: 6), fromPhone: true))
        #expect(alert.kind == .turnFinished)
        #expect(alert.detail == "Main answer")
    }

    @Test func macTurnIsNotAnnounced() async throws {
        let sink = RecordingSink()
        let (service, _) = await makeService(events: [result()], sink: sink)
        await service.handle(.sessionUpdated(summary(.idle, lastSeq: 0)))
        await service.handle(.sessionUpdated(summary(.running, lastSeq: 0)))
        await service.handle(.sessionUpdated(summary(.idle, lastSeq: 1)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(sink.delivered.isEmpty)
    }

    @Test func permissionRequestsUseTheSessionFolder() async throws {
        let sink = RecordingSink()
        let (service, _) = await makeService(events: [], sink: sink)
        await service.handle(.sessionUpdated(summary(.running, lastSeq: 1)))
        let request = PermissionRequest(
            id: "r1", sessionId: "s1", tool: "Bash", input: .object([:]), cwd: "/Users/me/Projects/app/sub",
            createdAt: Date(), expiresAt: Date(), rememberKey: "Bash"
        )
        await service.handle(.permissionRequest(request))
        #expect(sink.delivered == [HostAlert(kind: .permissionRequested, sessionId: "s1", folderName: "app", detail: "Bash")])
    }

    @Test func preferencesFilterKinds() async throws {
        let sink = RecordingSink()
        let (service, _) = await makeService(
            events: [], sink: sink, preferences: .init(enabled: true, kinds: [.turnFinished])
        )
        await service.post(HostAlert(kind: .permissionRequested, sessionId: "s1", folderName: "app"))
        await service.post(HostAlert(kind: .turnFinished, sessionId: "s1", folderName: "app"))
        await service.configure(.off, sinks: [sink])
        await service.post(HostAlert(kind: .turnFinished, sessionId: "s1", folderName: "app"))
        #expect(sink.delivered.map(\.kind) == [.turnFinished])
    }

    @Test func listensToTheHub() async throws {
        let sink = RecordingSink()
        let (service, hub) = await makeService(events: [], sink: sink)
        await service.start()
        await hub.post(.permissionRequest(PermissionRequest(
            id: "r1", sessionId: "s2", tool: "Edit", input: .object([:]), cwd: "/tmp/demo",
            createdAt: Date(), expiresAt: Date(), rememberKey: "Edit"
        )))
        let delivered = await sink.waitForCount(1)
        #expect(delivered.first?.folderName == "demo")
        await service.stop()
    }
}

/// Answers every request with the configured status and records the request.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable {
        var url: URL?
        var method: String?
        var headers: [String: String]
        var body: Data
    }

    static let status = Mutex(200)
    static let captured = Mutex<[Captured]>([])

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.captured.withLock {
            $0.append(Captured(url: request.url, method: request.httpMethod, headers: request.allHTTPHeaderFields ?? [:], body: body))
        }
        let status = Self.status.withLock { $0 }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(status == 200 ? "{\"id\":\"x\"}".utf8 : "{\"error\":\"unauthorized\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serialised because `StubURLProtocol` keeps global state.
@Suite(.serialized) struct NtfyPublisherTests {
    @Test func publishesJSONWithClickLinkAndToken() async throws {
        StubURLProtocol.captured.withLock { $0 = [] }
        StubURLProtocol.status.withLock { $0 = 200 }
        let configuration = try #require(NtfyConfiguration(server: "https://ntfy.example.com/", topic: "abc123", token: "tk_secret"))
        let publisher = NtfyPublisher(configuration: configuration, macId: "MAC-1", session: StubURLProtocol.session())
        try await publisher.deliver(
            HostAlert(kind: .turnFinished, sessionId: "1234-abcd", folderName: "app", detail: "secret summary"),
            includeDetail: false
        )
        let request = try #require(StubURLProtocol.captured.withLock { $0.first })
        #expect(request.url?.absoluteString == "https://ntfy.example.com")
        #expect(request.method == "POST")
        #expect(request.headers["Authorization"] == "Bearer tk_secret")
        let json = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(json["topic"] as? String == "abc123")
        #expect(json["title"] as? String == "Remote Code")
        #expect(json["message"] as? String == "Task finished · app")
        #expect(json["click"] as? String == "pilothouse://session/1234-abcd?mac=MAC-1")
        #expect(json["priority"] as? Int == 3)
    }

    @Test func rejectedRequestsThrow() async throws {
        StubURLProtocol.captured.withLock { $0 = [] }
        StubURLProtocol.status.withLock { $0 = 403 }
        defer { StubURLProtocol.status.withLock { $0 = 200 } }
        let configuration = try #require(NtfyConfiguration(server: "https://ntfy.sh", topic: "abc123"))
        let publisher = NtfyPublisher(configuration: configuration, session: StubURLProtocol.session())
        await #expect(throws: NtfyError.self) {
            try await publisher.publish(NtfyMessage(topic: "ignored", message: "hi"))
        }
        let request = try #require(StubURLProtocol.captured.withLock { $0.first })
        #expect(request.headers["Authorization"] == nil)
        let json = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(json["topic"] as? String == "abc123")
        #expect(json["click"] == nil)
    }

    @Test func configurationValidation() {
        #expect(NtfyConfiguration(server: "ntfy.sh", topic: "abc") == nil)
        #expect(NtfyConfiguration(server: "ftp://ntfy.sh", topic: "abc") == nil)
        #expect(NtfyConfiguration(server: "https://ntfy.sh", topic: "a b") == nil)
        #expect(NtfyConfiguration(server: "https://ntfy.sh", topic: "abc", token: "")?.token == nil)
        #expect(NtfyConfiguration(server: "https://ntfy.sh", topic: "abc")?.topicURL.absoluteString == "https://ntfy.sh/abc")
        let topic = NtfyConfiguration.randomTopic()
        #expect(topic.count == 32)
        #expect(NtfyConfiguration.isValidTopic(topic))
        #expect(topic != NtfyConfiguration.randomTopic())
    }
}

@Suite struct SessionLinkTests {
    @Test func roundTrips() throws {
        let link = SessionLink(sessionId: "0b5e-41aa", macId: "abc_DEF-1")
        #expect(link.url.absoluteString == "pilothouse://session/0b5e-41aa?mac=abc_DEF-1")
        #expect(SessionLink(url: link.url) == link)
        #expect(SessionLink(url: try #require(URL(string: "pilothouse://session/abc"))) == SessionLink(sessionId: "abc"))
    }

    @Test func rejectsOtherLinks() throws {
        #expect(SessionLink(url: try #require(URL(string: "pilothouse://pair?d=xyz"))) == nil)
        #expect(SessionLink(url: try #require(URL(string: "pilothouse://session/"))) == nil)
        #expect(SessionLink(url: try #require(URL(string: "pilothouse://session/a/b"))) == nil)
        #expect(SessionLink(url: try #require(URL(string: "https://session/abc"))) == nil)
        #expect(SessionLink(url: try #require(URL(string: "pilothouse://session/a%20b"))) == nil)
    }
}

/// The real session manager and FakeClaude produce the hub traffic the service expects.
@Suite(.serialized, .timeLimit(.minutes(1))) struct NotificationServiceIntegrationTests {
    @Test func phoneTurnAgainstFakeClaude() async throws {
        let harness = try await SessionManagerTests.Harness()
        defer { Task { await harness.tearDown() } }
        let sink = RecordingSink()
        await harness.runtime.notifications.configure(.init(enabled: true), sinks: [sink])

        let session = try await harness.sessions.start(StartSession(cwd: "~/project"))
        // A turn from the Mac itself is not announced …
        try await harness.sessions.send(SendMessage(sessionId: session.id, text: "From the Mac"))
        try await Task.sleep(for: .seconds(2))
        #expect(sink.delivered.isEmpty)
        // … one from the phone is.
        await harness.runtime.notifications.noteTurnFromPhone(session.id)
        try await harness.sessions.send(SendMessage(sessionId: session.id, text: "From the phone"))
        let delivered = await sink.waitForCount(1)
        #expect(delivered == [HostAlert(kind: .turnFinished, sessionId: session.id, folderName: "project", detail: "Hello from FakeClaude")])
    }
}

/// Publishes one message to a **real** ntfy server. Opt-in because it uses the network:
///
///     PILOTHOUSE_NTFY_LIVE=1 swift test --filter LiveNtfyTests
///
/// `PILOTHOUSE_NTFY_SERVER` overrides the server (default https://ntfy.sh);
/// the topic is fresh and random on every run.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PILOTHOUSE_NTFY_LIVE"] != nil), .timeLimit(.minutes(1)))
struct LiveNtfyTests {
    @Test func publishesToARealServer() async throws {
        let server = ProcessInfo.processInfo.environment["PILOTHOUSE_NTFY_SERVER"] ?? NtfyConfiguration.defaultServer
        let configuration = try #require(NtfyConfiguration(server: server, topic: NtfyConfiguration.randomTopic()))
        let publisher = NtfyPublisher(configuration: configuration, macId: "live-test")
        let message = publisher.message(
            for: HostAlert(kind: .turnFinished, sessionId: "live-test", folderName: "pilothouse"), includeDetail: false
        )
        let status = try await publisher.publish(message)
        #expect(status == 200)
        print("Published to \(configuration.topicURL.absoluteString) (HTTP \(status))")

        // Read it back from the topic's JSON poll endpoint.
        let poll = configuration.topicURL.appendingPathComponent("json")
        var components = try #require(URLComponents(url: poll, resolvingAgainstBaseURL: false))
        components.queryItems = [URLQueryItem(name: "poll", value: "1"), URLQueryItem(name: "since", value: "all")]
        let pollURL = try #require(components.url)
        var lines: [Substring] = []
        for _ in 0..<10 where lines.isEmpty {
            let (data, _) = try await URLSession.shared.data(from: pollURL)
            lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            if lines.isEmpty { try await Task.sleep(for: .milliseconds(500)) }
        }
        let line = try #require(lines.first)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(json["message"] as? String == "Task finished · pilothouse")
        #expect(json["click"] as? String == "pilothouse://session/live-test?mac=live-test")
    }
}
