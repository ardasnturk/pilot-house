import Foundation
import PilothouseKit
import Testing
@testable import PilothouseHost
#if canImport(Glibc)
import Glibc
#endif

@Suite struct HTTPParserTests {
    @Test func parsesContentLengthAndKeepAlive() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:5\r\nContent-Length: 4\r\nX-Case: A\r\n\r\nbodyGET /mcp HTTP/1.1\r\n\r\n".utf8))
        let first = try #require(try parser.next())
        #expect(first.method == "POST")
        #expect(first.path == "/mcp")
        #expect(first.headers["x-case"] == "A")
        #expect(first.body == Data("body".utf8))
        let second = try #require(try parser.next())
        #expect(second.method == "GET")
        #expect(try parser.next() == nil)
    }

    @Test func waitsForCompleteBodies() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345".utf8))
        #expect(try parser.next() == nil)
        parser.append(Data("67890".utf8))
        #expect(try parser.next()?.body == Data("1234567890".utf8))
    }

    @Test func decodesChunkedBodies() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;ext=1\r\npedia\r\n0\r\n\r\n".utf8))
        #expect(try parser.next()?.body == Data("Wikipedia".utf8))
    }

    @Test func rejectsOversizedBodies() {
        var parser = HTTPRequestParser()
        parser.append(Data("POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".utf8))
        #expect(throws: HTTPRequestParser.ParseError.tooLarge) { try parser.next() }
    }

    @Test func serialisesResponses() {
        let data = HTTPResponse(status: 202, headers: [:], body: Data()).serialized(keepAlive: true)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 202 Accepted\r\n"))
        #expect(text.contains("Content-Length: 0\r\n"))
        #expect(text.contains("Connection: keep-alive\r\n"))
    }
}

@Suite struct MCPPermissionEndpointTests {
    let endpoint = MCPPermissionEndpoint(
        resolveToken: { $0 == "good" ? "session-1" : nil },
        decide: { sessionId, tool, input, toolUseId in
            #expect(sessionId == "session-1")
            #expect(toolUseId == "toolu_1")
            return tool == "Bash" ? .allow(updatedInput: input) : .deny(message: "no")
        }
    )

    func post(_ body: String, headers: [String: String] = [:]) async -> HTTPResponse {
        var allHeaders = ["host": "127.0.0.1:4000", "authorization": "Bearer good", "content-type": "application/json"]
        allHeaders.merge(headers) { _, new in new }
        return await endpoint.handle(HTTPRequest(method: "POST", path: "/mcp", headers: allHeaders, body: Data(body.utf8)))
    }

    func json(_ response: HTTPResponse) throws -> JSONValue {
        try JSONValue.parse(response.body)
    }

    @Test func initializeAndListTools() async throws {
        let initialize = try json(await post(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#))
        #expect(initialize["result"]?["protocolVersion"]?.stringValue == "2025-11-25")
        #expect(initialize["result"]?["serverInfo"]?["name"]?.stringValue == "pilothouse")

        let fallback = try json(await post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        #expect(fallback["result"]?["protocolVersion"]?.stringValue == "2025-06-18")

        let tools = try json(await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        #expect(tools["result"]?["tools"]?[0]?["name"]?.stringValue == "approve_permission")
    }

    @Test func callReturnsDocumentedPermissionResult() async throws {
        let allowed = try json(await post(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"approve_permission","arguments":{"tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"toolu_1"}}}"#))
        let text = try #require(allowed["result"]?["content"]?[0]?["text"]?.stringValue)
        let decision = try JSONValue.parse(text)
        #expect(decision["behavior"]?.stringValue == "allow")
        #expect(decision["updatedInput"]?["command"]?.stringValue == "ls")

        let denied = try json(await post(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"approve_permission","arguments":{"tool_name":"Write","input":{},"tool_use_id":"toolu_1"}}}"#))
        let deniedText = try #require(denied["result"]?["content"]?[0]?["text"]?.stringValue)
        #expect(try JSONValue.parse(deniedText)["behavior"]?.stringValue == "deny")
    }

    @Test func notificationsAndUnknownMethods() async throws {
        let notification = await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(notification.status == 202)
        let unknown = try json(await post(#"{"jsonrpc":"2.0","id":"server-discover-probe-1","method":"server/discover"}"#))
        #expect(unknown["error"]?["code"]?.intValue == -32601)
        #expect(unknown["id"]?.stringValue == "server-discover-probe-1")
        let parseError = try json(await post("{nope"))
        #expect(parseError["error"]?["code"]?.intValue == -32700)
    }

    @Test func securityChecks() async {
        #expect(await post("{}", headers: ["authorization": "Bearer bad"]).status == 401)
        #expect(await post("{}", headers: ["authorization": ""]).status == 401)
        #expect(await post("{}", headers: ["origin": "https://evil.example"]).status == 403)
        #expect(await post("{}", headers: ["host": "evil.example:4000"]).status == 403)
        let get = await endpoint.handle(HTTPRequest(method: "GET", path: "/mcp", headers: ["authorization": "Bearer good"], body: Data()))
        #expect(get.status == 405)
        let wrongPath = await endpoint.handle(HTTPRequest(method: "POST", path: "/other", headers: ["authorization": "Bearer good"], body: Data()))
        #expect(wrongPath.status == 404)
    }
}

@Suite struct PermissionBrokerTests {
    @Test func respondResolvesAndBroadcasts() async throws {
        let hub = NotificationHub()
        let broker = PermissionBroker(hub: hub)
        let notifications = await hub.stream()
        let decision = Task { await broker.request(sessionId: "s", tool: "Bash", input: ["command": "make"], cwd: "/x") }
        var iterator = notifications.makeAsyncIterator()
        guard case .permissionRequest(let request) = await iterator.next() else {
            Issue.record("Expected a broadcast request")
            return
        }
        #expect(request.rememberKey == "Bash(make)")
        #expect(await broker.pendingRequests.count == 1)
        try await broker.respond(PermissionResponse(requestId: request.id, allow: true, remember: true))
        #expect(await decision.value.1 == .allow(remember: true))
        guard case .permissionResolved(let resolved) = await iterator.next() else {
            Issue.record("Expected resolution")
            return
        }
        #expect(resolved.outcome == .allowedForSession)
        await #expect(throws: ErrorPayload.self) {
            try await broker.respond(PermissionResponse(requestId: request.id, allow: false))
        }
    }

    @Test func unansweredRequestsAreDeniedAfterTimeout() async {
        let broker = PermissionBroker(hub: NotificationHub(), timeout: .milliseconds(200))
        let (_, decision) = await broker.request(sessionId: "s", tool: "Edit", input: [:], cwd: "/x")
        #expect(decision == .timedOut)
    }

    @Test func cancelAllOnlyAffectsOneSession() async throws {
        let broker = PermissionBroker(hub: NotificationHub())
        let first = Task { await broker.request(sessionId: "a", tool: "Bash", input: [:], cwd: "/") }
        let second = Task { await broker.request(sessionId: "b", tool: "Bash", input: [:], cwd: "/") }
        while await broker.pendingRequests.count < 2 { await Task.yield() }
        await broker.cancelAll(sessionId: "a")
        #expect(await first.value.1 == .cancelled)
        #expect(await broker.pendingRequests.map(\.sessionId) == ["b"])
        await broker.cancelAll(sessionId: "b")
        _ = await second.value
    }
}

@Suite(.timeLimit(.minutes(1))) struct ChildProcessTests {
    @Test func runsInWorkingDirectoryWithEnvironment() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let output = try await ChildProcess.runToCompletion(
            executable: "/bin/sh",
            arguments: ["-c", "pwd; printf '%s' \"$GREETING\""],
            environment: ["PATH": "/usr/bin:/bin", "GREETING": "merhaba"],
            workingDirectory: home.path
        )
        #expect(output.status == .exited(0))
        #expect(output.stdoutString == "\(home.path)\nmerhaba")
    }

    @Test func reportsExitCodesAndStderr() async throws {
        let output = try await ChildProcess.runToCompletion(
            executable: "/bin/sh", arguments: ["-c", "echo oops >&2; exit 7"], environment: ["PATH": "/usr/bin:/bin"]
        )
        #expect(output.status == .exited(7))
        #expect(String(decoding: output.stderr, as: UTF8.self) == "oops\n")
    }

    @Test func missingWorkingDirectoryFailsCleanly() async throws {
        let output = try await ChildProcess.runToCompletion(
            executable: "/bin/echo", arguments: ["x"], environment: [:], workingDirectory: "/definitely/not/here"
        )
        #expect(output.status == .exited(126))
    }

    @Test func stdinRoundTripsThroughCat() async throws {
        let process = try ChildProcess.spawn(executable: "/bin/cat", arguments: [], environment: [:], workingDirectory: "/")
        let lines = process.stdout.lines()
        try await process.write(Data("one\ntwo\n".utf8))
        process.closeStdin()
        var received: [String] = []
        for await line in lines { received.append(line) }
        #expect(received == ["one", "two"])
        #expect(await process.waitForExit() == .exited(0))
    }

    @Test func signalsReachTheWholeProcessGroup() async throws {
        // The shell starts a grandchild; SIGTERM to the group must stop both.
        let process = try ChildProcess.spawn(
            executable: "/bin/sh", arguments: ["-c", "sleep 30 & echo $!; wait"], environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/"
        )
        var lines = process.stdout.lines().makeAsyncIterator()
        let grandchild = try #require(await lines.next().flatMap { Int32($0) })
        process.send(signal: SIGTERM)
        _ = await process.waitForExit(timeout: 5)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!isAlive(grandchild), "grandchild should be gone")
    }

    /// `kill(pid, 0)` also succeeds for zombies, which a container's PID 1 may
    /// never reap; on Linux look at the process state instead.
    func isAlive(_ pid: Int32) -> Bool {
        #if os(Linux)
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
            let close = stat.lastIndex(of: ")")
        else { return false }
        let state = stat[stat.index(close, offsetBy: 2)]
        return state != "Z" && state != "X"
        #else
        return kill(pid, 0) == 0
        #endif
    }

    @Test func terminateEscalatesToSigkill() async throws {
        let process = try ChildProcess.spawn(
            executable: "/bin/sh", arguments: ["-c", "trap '' TERM; echo ready; while :; do sleep 1; done"],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/"
        )
        var lines = process.stdout.lines().makeAsyncIterator()
        _ = await lines.next()
        let start = Date()
        let status = await process.terminate(grace: 1)
        #expect(status == .signaled(SIGKILL))
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func runToCompletionTimesOut() async throws {
        let output = try await ChildProcess.runToCompletion(
            executable: "/bin/sh", arguments: ["-c", "sleep 30"], environment: ["PATH": "/usr/bin:/bin"], timeout: 0.5
        )
        #expect(output.timedOut)
        #expect(output.status == .signaled(SIGKILL))
    }

    @Test func lineSplitterHandlesPartialChunks() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("ab".utf8)).isEmpty)
        #expect(splitter.append(Data("c\r\nde\n".utf8)) == ["abc", "de"])
        #expect(splitter.append(Data("tail".utf8)).isEmpty)
        #expect(splitter.flush() == "tail")
    }
}

@Suite struct CommandAndEnvironmentTests {
    @Test func argumentsForNewAndResumedSessions() {
        var options = ClaudeLaunchOptions(
            sessionId: "abc", resume: false, model: "opus", permissionMode: .acceptEdits, workingDirectory: "/w",
            permissionServer: PermissionServerInfo(port: 5555, token: "tok")
        )
        let fresh = ClaudeCommand.arguments(for: options)
        #expect(Array(fresh.prefix(7)) == ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"])
        #expect(fresh.contains("--session-id") && !fresh.contains("--resume"))
        #expect(fresh.split(separator: "--model").count == 2)
        #expect(fresh.contains("acceptEdits"))
        #expect(fresh.last == "mcp__pilothouse__approve_permission")

        options.resume = true
        options.model = nil
        options.permissionServer = nil
        let resumed = ClaudeCommand.arguments(for: options)
        #expect(resumed.contains("--resume") && !resumed.contains("--session-id"))
        #expect(!resumed.contains("--model") && !resumed.contains("--mcp-config"))
        #expect(!resumed.contains("--effort"))

        options.effort = "xhigh"
        let withEffort = ClaudeCommand.arguments(for: options)
        #expect(withEffort.firstIndex(of: "--effort").map { withEffort[$0 + 1] } == "xhigh")
    }

    @Test func mcpConfigurationShape() throws {
        let config = try JSONValue.parse(ClaudeCommand.mcpConfiguration(PermissionServerInfo(port: 6000, token: "secret")))
        let server = try #require(config["mcpServers"]?["pilothouse"])
        #expect(server["type"]?.stringValue == "http")
        #expect(server["url"]?.stringValue == "http://127.0.0.1:6000/mcp")
        #expect(server["headers"]?["Authorization"]?.stringValue == "Bearer secret")
        #expect(server["timeout"]?.intValue == ClaudeCommand.mcpTimeoutMilliseconds)
    }

    @Test func apiKeyOnlyWhenExplicitlyEnabled() {
        let base = ["PATH": "/bin", "ANTHROPIC_API_KEY": "from-shell", "CLAUDECODE": "1"]
        let subscription = ClaudeCommand.environment(base: base, apiKey: nil)
        #expect(subscription["ANTHROPIC_API_KEY"] == nil)
        #expect(subscription["CLAUDECODE"] == nil)
        #expect(subscription["PATH"] == "/bin")
        #expect(ClaudeCommand.environment(base: base, apiKey: "sk-test")["ANTHROPIC_API_KEY"] == "sk-test")
    }

    @Test func userMessageLines() throws {
        let plain = try JSONValue.parse(ClaudeCommand.userMessageLine(text: "hi", attachments: []))
        #expect(plain["type"]?.stringValue == "user")
        #expect(plain["message"]?["content"]?.stringValue == "hi")

        let withImage = try JSONValue.parse(ClaudeCommand.userMessageLine(
            text: "what is this?", attachments: [MessageAttachment(mediaType: "image/png", data: Data([1, 2]))]
        ))
        let blocks = try #require(withImage["message"]?["content"]?.arrayValue)
        #expect(blocks[0]["type"]?.stringValue == "image")
        #expect(blocks[0]["source"]?["data"]?.stringValue == "AQI=")
        #expect(blocks[1]["text"]?.stringValue == "what is this?")
        #expect(String(decoding: try ClaudeCommand.userMessageLine(text: "x", attachments: []), as: UTF8.self).hasSuffix("}\n"))
    }

    @Test func loginShellEnvironmentParsing() {
        let raw = Data("motd noise\n__PILOTHOUSE_ENV_BEGIN__PATH=/opt/homebrew/bin:/usr/bin\0HOME=/Users/a\0WEIRD=a=b\0__PILOTHOUSE_ENV_END__trailing".utf8)
        let parsed = LoginShellEnvironment.parse(raw)
        #expect(parsed?["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(parsed?["WEIRD"] == "a=b")
        #expect(LoginShellEnvironment.parse(Data("no markers".utf8)) == nil)
    }

    @Test func loginShellCaptureWorksWithSh() async {
        let environment = await LoginShellEnvironment.capture(shell: "/bin/sh", base: ["PATH": "/usr/bin:/bin"], home: NSTemporaryDirectory())
        #expect(environment["PATH"] != nil)
    }

    @Test func tailscaleStatusParsing() {
        let json = """
            {"Version":"1.90.1","BackendState":"Running","Self":{"DNSName":"macbook.tail1234.ts.net.","TailscaleIPs":["100.101.102.103","fd7a:115c:a1e0::1"],"Online":true},
             "MagicDNSSuffix":"tail1234.ts.net","CurrentTailnet":{"Name":"arda@example.com","MagicDNSSuffix":"tail1234.ts.net","MagicDNSEnabled":true}}
            """
        let status = TailscaleProbe.parse(Data(json.utf8))
        #expect(status.running)
        #expect(status.ipv4 == "100.101.102.103")
        #expect(status.ipv6 == "fd7a:115c:a1e0::1")
        #expect(status.magicDNSName == "macbook.tail1234.ts.net")
        #expect(status.addresses.map(\.kind) == [.magicDNS, .tailscale, .tailscale])

        let stopped = TailscaleProbe.parse(Data(#"{"BackendState":"NeedsLogin","Self":{"TailscaleIPs":[]}}"#.utf8))
        #expect(!stopped.running)
        #expect(stopped.addresses.isEmpty)
        #expect(stopped.backendState == "NeedsLogin")
    }

    @Test func networkInterfacesHaveNoLoopback() {
        let addresses = NetworkInterfaces.localAddresses()
        #expect(!addresses.contains("127.0.0.1"))
    }
}
