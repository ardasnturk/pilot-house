import Foundation
import PilothouseKit
import Testing
@testable import PilothouseHost

/// `delegate_to_agent`: Claude hands a task to another agent CLI (FakeCodex).
/// Runs FakeCodex through `/bin/sh` instead of executing the freshly copied
/// script: on Linux a parallel test's fork can still hold the copy's write
/// descriptor, and exec then fails with ETXTBSY ("Text file busy").
struct FakeCodexLauncher: AgentLauncher {
    let script: String

    func launch(_ options: ClaudeLaunchOptions) async throws -> ChildProcess {
        try ChildProcess.spawn(
            executable: "/bin/sh", arguments: [script, "app-server"],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: options.workingDirectory
        )
    }

    func makeAdapter(for options: ClaudeLaunchOptions) -> any AgentAdapter {
        CodexLauncher(executable: script, environment: [:]).makeAdapter(for: options)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct DelegationTests {
    final class Harness: Sendable {
        let home: TemporaryHome
        let runtime: HostRuntime

        init(delegationAgents: [AgentKind] = [.codex]) async throws {
            home = try TemporaryHome()
            try home.makeDirectory("project")
            let tools = try home.makeDirectory(".tools")
            let claude = try Fixtures.installFakeClaude(in: tools)
            let codex = tools.appendingPathComponent("fake-codex")
            try FileManager.default.copyItem(at: Fixtures.url("fake-codex.sh"), to: codex)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
            let argsLog = home.url.appendingPathComponent("args.log")
            runtime = try HostRuntime(
                configuration: HostConfiguration(
                    homeDirectory: home.path,
                    dataDirectory: home.url.appendingPathComponent("Library/Pilothouse"),
                    delegationAgents: delegationAgents
                ),
                identity: .generate(),
                serverVersion: "test",
                status: TestStatusProvider(),
                macName: { "Test Mac" },
                agentLauncher: { kind in
                    switch kind {
                    case .claude: FakeClaudeLauncher(executable: claude, argsLog: argsLog)
                    case .codex: FakeCodexLauncher(script: codex.path)
                    default: throw ErrorPayload(code: .agentNotInstalled, message: "not installed")
                    }
                }
            )
            await runtime.start()
        }

        var sessions: SessionManager { runtime.sessions }

        func tearDown() async {
            await runtime.shutdown()
            home.remove()
        }
    }

    @Test func delegatedRunStreamsIntoItsOwnThreadAndReturnsTheAnswer() async throws {
        let harness = try await Harness()
        defer { Task { await harness.tearDown() } }
        let session = try await harness.sessions.start(StartSession(cwd: "~/project"))
        #expect(await harness.sessions.delegationAgents(for: session.id) == [.codex])
        let stream = try await harness.sessions.subscribe(session.id, fromSeq: 1)

        let result = await harness.sessions.delegate(
            sessionId: session.id, arguments: ["agent": "codex", "prompt": "Review the README"]
        )
        #expect(result == DelegationResult(text: "FAKE CODEX ANSWER", isError: false))

        let events = try await collect(stream) { events in
            events.contains { $0.thread != nil && $0.event.isResult }
        }
        let threaded = events.filter { $0.thread != nil }
        let threads = Set(threaded.compactMap(\.thread))
        #expect(threads.count == 1)
        #expect(threaded.contains { if case .userMessage(let message) = $0.event { message.text == "Review the README" } else { false } })
        #expect(threaded.contains { if case .assistantMessage(let message) = $0.event { message.text == "FAKE CODEX ANSWER" } else { false } })
        #expect(threaded.contains { if case .sessionInfo(let info) = $0.event { info.claudeSessionId == "fake-thread" } else { false } })

        // The sub-agent's result does not end the parent's turn or change its preview.
        let summary = try #require(await harness.sessions.summary(session.id))
        #expect(summary.lastMessagePreview == nil)

        // Threads are persisted, so a phone that reconnects sees the same split.
        let replay = try await collect(try await harness.sessions.subscribe(session.id, fromSeq: 1)) { events in
            events.contains { $0.thread != nil && $0.event.isResult }
        }
        #expect(Set(replay.compactMap(\.thread)) == threads)
    }

    @Test func disabledOrUnknownAgentsAreRefused() async throws {
        let harness = try await Harness(delegationAgents: [])
        defer { Task { await harness.tearDown() } }
        let session = try await harness.sessions.start(StartSession(cwd: "~/project"))
        #expect(await harness.sessions.delegationAgents(for: session.id).isEmpty)
        let result = await harness.sessions.delegate(sessionId: session.id, arguments: ["agent": "codex", "prompt": "Hi"])
        #expect(result.isError)
        #expect(result.text.contains("not enabled"))
    }

    @Test func mcpEndpointListsTheToolOnlyWhenAgentsAreEnabled() async throws {
        let endpoint = MCPPermissionEndpoint(
            resolveToken: { _ in "s1" },
            decide: { _, _, input, _ in .allow(updatedInput: input) },
            delegationAgents: { _ in [.codex, .gemini] },
            delegate: { _, arguments in DelegationResult(text: "done: \(arguments["prompt"]?.stringValue ?? "")", isError: false) }
        )
        let list = try #require(await endpoint.handleRPC(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], sessionId: "s1"))
        let names = (list["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        #expect(names == ["approve_permission", "delegate_to_agent"])
        let schema = list["result"]?["tools"]?[1]?["inputSchema"]?["properties"]?["agent"]?["enum"]
        #expect(schema == ["codex", "gemini"])

        let call = try #require(await endpoint.handleRPC([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "delegate_to_agent", "arguments": ["agent": "codex", "prompt": "X"]],
        ], sessionId: "s1"))
        #expect(call["result"]?["content"]?[0]?["text"]?.stringValue == "done: X")
        #expect(call["result"]?["isError"]?.boolValue == false)

        let plain = MCPPermissionEndpoint(resolveToken: { _ in "s1" }, decide: { _, _, input, _ in .allow(updatedInput: input) })
        let plainList = try #require(await plain.handleRPC(["jsonrpc": "2.0", "id": 3, "method": "tools/list"], sessionId: "s1"))
        #expect(plainList["result"]?["tools"]?.arrayValue?.count == 1)
    }

    @Test func claudeTaskSubAgentsAreThreaded() throws {
        var normalizer = StreamJSONNormalizer()
        let line = #"{"type":"assistant","parent_tool_use_id":"toolu_task","message":{"id":"msg_sub","content":[{"type":"text","text":"Sub-agent says hi"}]}}"#
        #expect(normalizer.consume(line: line).isEmpty)
        let (thread, events) = normalizer.consumeThreaded(line: line)
        #expect(thread == "toolu_task")
        #expect(events.count == 1)
        let main = normalizer.consumeThreaded(line: #"{"type":"assistant","parent_tool_use_id":null,"message":{"id":"msg_main","content":[{"type":"text","text":"Main"}]}}"#)
        #expect(main.thread == nil)
        #expect(main.events.count == 1)
    }
}
