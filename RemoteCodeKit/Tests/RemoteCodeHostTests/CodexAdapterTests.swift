import Foundation
import RemoteCodeKit
import Testing
@testable import RemoteCodeHost

/// Feeds `codex app-server` output captured from Codex CLI 0.162.1 through the adapter.
@Suite struct CodexAdapterTests {
    static let options = CodexAdapter.Options(
        workingDirectory: "/Users/demo/Developer/demo", model: nil, permissionMode: .default, threadId: nil
    )

    func requests(_ lines: [Data]) throws -> [JSONValue] {
        try lines.map { try JSONValue.parse($0) }
    }

    @Test func startupHandshakeStartsAThread() throws {
        var adapter = CodexAdapter(options: Self.options)
        let startup = try requests(adapter.startupLines())
        #expect(startup.map { $0["method"]?.stringValue } == ["initialize", "initialized", "thread/start"])
        let params = try #require(startup[2]["params"])
        #expect(params["approvalPolicy"]?.stringValue == "untrusted")
        #expect(params["sandbox"]?.stringValue == "read-only")
        #expect(params["cwd"]?.stringValue == "/Users/demo/Developer/demo")
    }

    @Test func effortGoesWithEveryTurn() throws {
        var options = Self.options
        options.threadId = "thread-1"
        options.effort = "high"
        var adapter = CodexAdapter(options: options)
        _ = adapter.startupLines()
        _ = adapter.consume(line: #"{"id":2,"result":{"thread":{"id":"thread-1"},"model":"gpt-6"}}"#)
        let turn = try #require(try requests(adapter.userMessageLines(text: "Hi", attachments: [])).first)
        #expect(turn["method"]?.stringValue == "turn/start")
        #expect(turn["params"]?["effort"]?.stringValue == "high")
    }

    @Test func resumesAnExistingThread() throws {
        var options = Self.options
        options.threadId = "thread-1"
        options.permissionMode = .acceptEdits
        var adapter = CodexAdapter(options: options)
        let resume = try requests(adapter.startupLines())[2]
        #expect(resume["method"]?.stringValue == "thread/resume")
        #expect(resume["params"]?["threadId"]?.stringValue == "thread-1")
        #expect(resume["params"]?["sandbox"]?.stringValue == "workspace-write")
    }

    @Test func capturedTurnBecomesSessionEvents() throws {
        var adapter = CodexAdapter(options: Self.options)
        _ = adapter.startupLines()
        // The first message is queued until the thread exists.
        #expect(try adapter.userMessageLines(text: "Create hello.txt", attachments: []).isEmpty)

        var events: [SessionEvent] = []
        var writes: [JSONValue] = []
        var approvals: [AgentPermissionRequest] = []
        for line in try Fixtures.lines("codex-app-server.jsonl") {
            let output = adapter.consume(line: line)
            events += output.events
            writes += try requests(output.writes)
            approvals += output.permissionRequests
        }

        #expect(adapter.threadId == "01a16d03-1439-7793-adb8-5fb4ec309f5d")
        guard case .sessionInfo(let info) = events.first else {
            Issue.record("First event must be sessionInfo")
            return
        }
        #expect(info.claudeSessionId == adapter.threadId)

        // The queued message went out as turn/start once the thread was there.
        let turnStart = try #require(writes.first { $0["method"]?.stringValue == "turn/start" })
        #expect(turnStart["params"]?["threadId"]?.stringValue == adapter.threadId)
        #expect(turnStart["params"]?["input"]?[0]?["text"]?.stringValue == "Create hello.txt")

        // Both shell commands asked for approval, with the parsed command line.
        #expect(approvals.map(\.tool) == ["Bash", "Bash"])
        #expect(approvals.map { $0.input["command"]?.stringValue } == ["printf '%s\\n' 'Hello from Remote Code' > hello.txt", "ls -la"])
        #expect(approvals[0].toolUseId == "exec-69f7316f-0a4e-4d30-a44b-d4c3c0ffce53")

        let persisted = events.filter { !$0.isEphemeral }
        let toolUses = persisted.compactMap { if case .toolUse(let use) = $0 { use } else { nil } }
        #expect(toolUses.map(\.name) == ["Bash", "Bash"])
        let results = persisted.compactMap { if case .toolResult(let result) = $0 { result } else { nil } }
        #expect(results.count == 2)
        #expect(results.allSatisfy { !$0.isError })
        #expect(results[1].output.contains("hello.txt"))

        let messages = persisted.compactMap { if case .assistantMessage(let message) = $0 { message.text } else { nil } }
        #expect(messages.last?.contains("22 bytes") == true)
        #expect(events.contains { if case .assistantTextDelta = $0 { true } else { false } })
        #expect(adapter.streamingText.isEmpty)

        guard case .result(let result) = persisted.last else {
            Issue.record("Last event must be the turn result")
            return
        }
        #expect(!result.isError)
        #expect(result.subtype == "success")
        #expect(result.durationMs > 0)
        #expect((result.usage?.outputTokens ?? 0) > 0)
        #expect(adapter.activeTurnId == nil)
    }

    @Test func approvalRepliesUseTheRequestId() throws {
        let adapter = CodexAdapter(options: Self.options)
        let request = AgentPermissionRequest(
            rpcId: 7, tool: "Bash", input: ["command": "ls"], context: ["method": "item/commandExecution/requestApproval"]
        )
        let allow = try JSONValue.parse(try #require(adapter.permissionReply(to: request, allow: true)))
        #expect(allow["id"]?.intValue == 7)
        #expect(allow["result"]?["decision"]?.stringValue == "accept")
        let deny = try JSONValue.parse(try #require(adapter.permissionReply(to: request, allow: false)))
        #expect(deny["result"]?["decision"]?.stringValue == "decline")

        let legacy = AgentPermissionRequest(rpcId: "a", tool: "Edit", input: [:], context: ["method": "applyPatchApproval"])
        let legacyReply = try JSONValue.parse(try #require(adapter.permissionReply(to: legacy, allow: true)))
        #expect(legacyReply["result"]?["decision"]?.stringValue == "approved")
    }

    @Test func unknownServerRequestsGetAnError() throws {
        var adapter = CodexAdapter(options: Self.options)
        let output = adapter.consume(line: #"{"jsonrpc":"2.0","id":9,"method":"item/tool/requestUserInput","params":{}}"#)
        #expect(output.permissionRequests.isEmpty)
        let reply = try JSONValue.parse(try #require(output.writes.first))
        #expect(reply["id"]?.intValue == 9)
        #expect(reply["error"]?["code"]?.intValue == -32601)
    }

    @Test func fileChangesBecomeDiffs() throws {
        var adapter = CodexAdapter(options: Self.options)
        let change = #"{"path":"/Users/demo/Developer/demo/a.swift","kind":{"type":"update","move_path":null},"diff":"@@ -1 +1 @@\n-a\n+b\n"}"#
        let started = adapter.consume(line: #"{"jsonrpc":"2.0","method":"item/started","params":{"item":{"type":"fileChange","id":"fc1","changes":[\#(change)],"status":"inProgress"}}}"#)
        guard case .toolUse(let use) = started.events.first else {
            Issue.record("Expected toolUse")
            return
        }
        #expect(use.name == "Edit")
        #expect(use.input["file_path"]?.stringValue == "/Users/demo/Developer/demo/a.swift")

        let approval = adapter.consume(line: #"{"jsonrpc":"2.0","id":3,"method":"item/fileChange/requestApproval","params":{"itemId":"fc1","threadId":"t","turnId":"u","startedAtMs":0}}"#)
        #expect(approval.permissionRequests.first?.input["file_path"]?.stringValue == "/Users/demo/Developer/demo/a.swift")

        let completed = adapter.consume(line: #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"type":"fileChange","id":"fc1","changes":[\#(change)],"status":"completed"}}}"#)
        guard case .fileEdit(let edit) = completed.events.first else {
            Issue.record("Expected fileEdit")
            return
        }
        #expect(edit.kind == .modified)
        #expect(edit.diff.contains("+b"))
    }

    @Test func interruptNeedsAnActiveTurn() throws {
        var adapter = CodexAdapter(options: Self.options)
        #expect(adapter.interruptLines()?.isEmpty == true)
        _ = adapter.startupLines()  // initialize = 1, thread/start = 2
        _ = adapter.consume(line: #"{"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"t1"}}}"#)
        _ = adapter.consume(line: #"{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"t1","turn":{"id":"turn1"}}}"#)
        let lines = adapter.interruptLines()
        let interrupt = try requests(try #require(lines))
        #expect(interrupt.first?["method"]?.stringValue == "turn/interrupt")
        #expect(interrupt.first?["params"]?["turnId"]?.stringValue == "turn1")

        let completed = adapter.consume(line: #"{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"t1","turn":{"id":"turn1","status":"interrupted","error":null}}}"#)
        #expect(completed.events.contains { if case .systemNotice(let notice) = $0 { notice.kind == "interrupted" } else { false } })
    }

    @Test(arguments: [
        (PermissionMode.default, "untrusted", "read-only"),
        (.acceptEdits, "on-request", "workspace-write"),
        (.plan, "on-request", "read-only"),
        (.bypassPermissions, "never", "danger-full-access"),
    ])
    func permissionModesMapToCodexPolicies(mode: PermissionMode, approval: String, sandbox: String) {
        let policy = CodexAdapter.policy(for: mode)
        #expect(policy.approval == approval)
        #expect(policy.sandbox == sandbox)
    }
}
