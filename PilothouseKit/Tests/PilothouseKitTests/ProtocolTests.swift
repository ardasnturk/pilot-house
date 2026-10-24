import Foundation
import Testing
@testable import PilothouseKit

@Suite struct ProtocolTests {
    func roundTrip(_ message: ClientMessage) throws -> ClientMessage {
        let data = try PilothouseJSON.encode(ClientEnvelope(message: message))
        return try PilothouseJSON.decode(ClientEnvelope.self, from: data).message
    }

    func roundTrip(_ message: ServerMessage) throws -> ServerMessage {
        let data = try PilothouseJSON.encode(ServerEnvelope(re: "req-1", message: message))
        let decoded = try PilothouseJSON.decode(ServerEnvelope.self, from: data)
        #expect(decoded.re == "req-1")
        return decoded.message
    }

    @Test(arguments: [
        ClientMessage.hello(Hello(appVersion: "1.0", deviceName: "iPhone", platform: "iOS")),
        .listDirectory(ListDirectory(path: "~/Developer", showHidden: true)),
        .listSessions,
        .startSession(StartSession(cwd: "/Users/a", model: "sonnet", permissionMode: .acceptEdits, firstMessage: "Hi")),
        .resumeSession(SessionRef(sessionId: "s1")),
        .sendMessage(SendMessage(sessionId: "s1", text: "Hello", attachments: [MessageAttachment(mediaType: "image/png", data: Data([1, 2, 3]))])),
        .interrupt(SessionRef(sessionId: "s1")),
        .closeSession(SessionRef(sessionId: "s1")),
        .deleteSession(SessionRef(sessionId: "s1")),
        .subscribe(Subscribe(sessionId: "s1", fromSeq: 42)),
        .unsubscribe(SessionRef(sessionId: "s1")),
        .permissionResponse(PermissionResponse(requestId: "r1", allow: true, remember: true)),
        .macStatus,
    ])
    func clientMessagesRoundTrip(_ message: ClientMessage) throws {
        #expect(try roundTrip(message) == message)
    }

    @Test func serverMessagesRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_792_800_000.125)
        let session = SessionSummary(
            id: "s1", cwd: "/Users/a/p", title: "Title", lastMessagePreview: "Preview", createdAt: date, updatedAt: date,
            model: "opus", permissionMode: .plan, state: .running, lastSeq: 7, slashCommands: ["review"]
        )
        let request = PermissionRequest(
            id: "r1", sessionId: "s1", tool: "Bash", input: ["command": "ls -la"], cwd: "/Users/a",
            createdAt: date, expiresAt: date.addingTimeInterval(600), rememberKey: "Bash(ls)"
        )
        let messages: [ServerMessage] = [
            .helloAck(HelloAck(macName: "Mac", macId: "id", serverVersion: "1.0", pendingPermissions: [request])),
            .ok,
            .directoryListing(DirectoryListing(
                path: "/Users/a", homePath: "/Users/a", parentPath: nil, isGitRepository: false,
                entries: [FileNode(name: "p", path: "/Users/a/p", isDirectory: true, isGitRepository: true, modifiedAt: date)]
            )),
            .sessionList(SessionList(sessions: [session])),
            .sessionStarted(SessionPayload(session: session)),
            .sessionUpdated(SessionPayload(session: session)),
            .sessionDeleted(SessionRef(sessionId: "s1")),
            .event(EventPayload(sessionId: "s1", event: SequencedEvent(seq: 3, timestamp: date, event: .toolUse(.init(toolUseId: "t", name: "Read", input: ["file_path": "/x"]))))),
            .permissionRequest(request),
            .permissionResolved(PermissionResolved(requestId: "r1", sessionId: "s1", outcome: .allowedForSession)),
            .sessionEnded(SessionEnded(sessionId: "s1", reason: .closedByUser)),
            .macStatus(MacStatus(
                macName: "Mac", sleepPrevented: true, lidClosedModeEnabled: false,
                claude: ClaudeCLIStatus(installed: true, path: "/opt/homebrew/bin/claude", version: "2.1.310"),
                tailscale: TailscaleStatus(installed: true, running: true, ipv4: "100.64.0.1"),
                addresses: [HostAddress(host: "192.168.1.2", kind: .local)], port: 47823, activeSessionCount: 1,
                bypassPermissionsAllowed: false
            )),
            .error(ErrorPayload(code: .notFound, message: "Nope")),
        ]
        for message in messages {
            #expect(try roundTrip(message) == message, "\(message.typeName)")
        }
    }

    @Test func envelopeHasDocumentedShape() throws {
        let envelope = ClientEnvelope(id: "abc", ts: Date(timeIntervalSince1970: 0), message: .subscribe(Subscribe(sessionId: "s", fromSeq: 5)))
        let object = try #require(try JSONSerialization.jsonObject(with: PilothouseJSON.encode(envelope)) as? [String: Any])
        #expect(Set(object.keys) == ["v", "id", "ts", "type", "payload"])
        #expect(object["v"] as? Int == 1)
        #expect(object["type"] as? String == "subscribe")
        #expect(object["ts"] as? String == "1970-01-01T00:00:00.000Z")
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(payload["sessionId"] as? String == "s")
        #expect(payload["fromSeq"] as? Int == 5)
    }

    @Test func versionMismatchIsReportedAsSuch() throws {
        let json = #"{"v":99,"id":"x","ts":"2026-01-01T00:00:00Z","type":"listSessions","payload":{}}"#
        #expect(throws: ProtocolError.unsupportedVersion(99)) {
            try PilothouseJSON.decode(ClientEnvelope.self, from: Data(json.utf8))
        }
        #expect(EnvelopeInspector.version(of: Data(json.utf8)) == 99)
        #expect(EnvelopeInspector.messageId(of: Data(json.utf8)) == "x")
    }

    @Test func unknownMessageTypeIsRejected() {
        let json = #"{"v":1,"id":"x","ts":"2026-01-01T00:00:00Z","type":"selfDestruct","payload":{}}"#
        #expect(throws: ProtocolError.unknownMessageType("selfDestruct")) {
            try PilothouseJSON.decode(ClientEnvelope.self, from: Data(json.utf8))
        }
    }

    @Test func sessionEventsAreFlatObjectsWithTypeDiscriminator() throws {
        let event = SessionEvent.fileEdit(.init(toolUseId: "t1", path: "/a.swift", kind: .modified, diff: "@@ -1 +1 @@\n-a\n+b"))
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        #expect(object["type"] as? String == "fileEdit")
        #expect(object["path"] as? String == "/a.swift")
        #expect(object["kind"] as? String == "modified")
        #expect(try JSONDecoder().decode(SessionEvent.self, from: JSONEncoder().encode(event)) == event)
    }

    @Test func unknownSessionEventDegradesToNotice() throws {
        let decoded = try JSONDecoder().decode(SessionEvent.self, from: Data(#"{"type":"hologram","x":1}"#.utf8))
        guard case .systemNotice(let notice) = decoded else {
            Issue.record("Expected a notice, got \(decoded)")
            return
        }
        #expect(notice.kind == "unknownEvent")
    }

    @Test func ephemeralClassification() {
        #expect(SessionEvent.assistantTextDelta(.init(blockId: "b", text: "x")).isEphemeral)
        #expect(SessionEvent.thinking(.init(blockId: "b", text: "", isComplete: false)).isEphemeral)
        #expect(!SessionEvent.thinking(.init(blockId: "b", text: "done", isComplete: true)).isEphemeral)
        #expect(!SessionEvent.assistantMessage(.init(blockId: "b", text: "x")).isEphemeral)
    }

    @Test func lenientEnumsAcceptFutureValues() throws {
        #expect(try JSONDecoder().decode(PermissionMode.self, from: Data(#""manual""#.utf8)) == .default)
        #expect(try JSONDecoder().decode(PermissionMode.self, from: Data(#""quantum""#.utf8)) == .default)
        #expect(try JSONDecoder().decode(SessionState.self, from: Data(#""hibernating""#.utf8)) == .idle)
    }

    @Test func datesKeepMillisecondPrecision() throws {
        let date = Date(timeIntervalSince1970: 1_792_800_000.456)
        let data = try PilothouseJSON.encode(["d": date])
        let decoded = try PilothouseJSON.decode([String: Date].self, from: data)
        let value = try #require(decoded["d"])
        #expect(abs(value.timeIntervalSince1970 - date.timeIntervalSince1970) < 0.001)
    }
}

@Suite struct ModelTests {
    @Test func jsonValueRoundTripsAndAccessors() throws {
        let json = #"{"a":[1,2.5,"x",true,null],"b":{"c":"d"}}"#
        let value = try JSONValue.parse(json)
        #expect(value["a"]?[0]?.intValue == 1)
        #expect(value["a"]?[1]?.doubleValue == 2.5)
        #expect(value["a"]?[2]?.stringValue == "x")
        #expect(value["a"]?[3]?.boolValue == true)
        #expect(value["a"]?[4]?.isNull == true)
        #expect(value["b"]?["c"]?.stringValue == "d")
        #expect(try JSONValue.parse(value.jsonString()) == value)
        #expect(value.jsonString() == #"{"a":[1,2.5,"x",true,null],"b":{"c":"d"}}"#)
    }

    @Test func jsonValueTruncatesLongStrings() {
        let value: JSONValue = ["content": .string(String(repeating: "x", count: 100)), "n": 3]
        let truncated = value.truncatingStrings(maxLength: 10)
        let content = truncated["content"]?.stringValue ?? ""
        #expect(content.hasPrefix("xxxxxxxxxx\n…"))
        #expect(content.contains("90 more characters"))
        #expect(truncated["n"] == 3)
    }

    @Test(arguments: [
        ("100.64.0.1", HostAddress.Kind.tailscale),
        ("100.127.255.254", .tailscale),
        ("100.128.0.1", .local),
        ("192.168.1.10", .local),
        ("fd7a:115c:a1e0::1", .tailscale),
        ("macbook.tail1234.ts.net", .magicDNS),
        ("macbook.local", .local),
    ])
    func addressClassification(_ host: String, _ expected: HostAddress.Kind) {
        #expect(HostAddress.classify(host) == expected)
    }

    @Test func rememberKeys() {
        #expect(PermissionRequest.rememberKey(tool: "Bash", input: ["command": "  npm test -- --watch"]) == "Bash(npm)")
        #expect(PermissionRequest.rememberKey(tool: "Bash", input: ["command": ""]) == "Bash")
        #expect(PermissionRequest.rememberKey(tool: "Edit", input: ["file_path": "/a"]) == "Edit")
        #expect(PermissionRequest.summary(tool: "Write", input: ["file_path": "/a/b.txt"]) == "/a/b.txt")
    }

    @Test func fingerprintsAreStableAndReadable() {
        let key = Data(repeating: 9, count: 32)
        #expect(KeyFingerprint.identifier(for: key) == KeyFingerprint.identifier(for: key))
        #expect(KeyFingerprint.identifier(for: key).count == 22)
        let code = KeyFingerprint.displayCode(for: key)
        #expect(code.count == 14)
        #expect(code.split(separator: "-").count == 3)
        #expect(!code.contains("0") && !code.contains("O") && !code.contains("1") && !code.contains("I"))
    }

    @Test func base64URLRoundTrip() {
        for length in 0..<40 {
            let data = Data((0..<length).map { UInt8(($0 * 37 + 11) % 256) })
            let encoded = Base64URL.encode(data)
            #expect(!encoded.contains("=") && !encoded.contains("+") && !encoded.contains("/"))
            #expect(Base64URL.decode(encoded) == data)
        }
        #expect(Base64URL.decode("a") == nil)
    }

    @Test func directoryDisplayPath() {
        let listing = DirectoryListing(path: "/Users/a/Dev/x", homePath: "/Users/a", parentPath: "/Users/a/Dev", isGitRepository: true, entries: [])
        #expect(listing.displayPath == "~/Dev/x")
        let home = DirectoryListing(path: "/Users/a", homePath: "/Users/a", parentPath: nil, isGitRepository: false, entries: [])
        #expect(home.displayPath == "~")
    }
}
