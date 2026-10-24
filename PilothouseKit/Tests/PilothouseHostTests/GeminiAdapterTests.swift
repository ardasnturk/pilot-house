import Foundation
import PilothouseKit
import Testing
@testable import PilothouseHost

/// ACP v1 messages as Gemini CLI 0.24 sends them (shapes from the ACP schema;
/// the startup responses are from a real `gemini --experimental-acp` run).
@Suite struct GeminiAdapterTests {
    static let options = GeminiAdapter.Options(
        workingDirectory: "/Users/demo/app", model: nil, permissionMode: .default, sessionId: nil, authMethod: "oauth-personal"
    )

    func parse(_ lines: [Data]) throws -> [JSONValue] {
        try lines.map { try JSONValue.parse($0) }
    }

    /// Runs the handshake and returns the adapter with an open session `s1`.
    func connected(queuing text: String? = nil) throws -> (GeminiAdapter, [JSONValue]) {
        var adapter = GeminiAdapter(options: Self.options)
        var writes = try parse(adapter.startupLines())
        if let text { #expect(try adapter.userMessageLines(text: text, attachments: []).isEmpty) }
        let initialize = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"authMethods":[{"id":"oauth-personal","name":"Log in with Google"}],"agentCapabilities":{"loadSession":false}}}"#
        writes += try parse(adapter.consume(line: initialize).writes)
        writes += try parse(adapter.consume(line: #"{"jsonrpc":"2.0","id":2,"result":null}"#).writes)
        let output = adapter.consume(line: #"{"jsonrpc":"2.0","id":3,"result":{"sessionId":"s1"}}"#)
        writes += try parse(output.writes)
        guard case .sessionInfo(let info)? = output.events.first else {
            Issue.record("Expected sessionInfo")
            return (adapter, writes)
        }
        #expect(info.claudeSessionId == "s1")
        return (adapter, writes)
    }

    @Test func handshakeAuthenticatesThenOpensASession() throws {
        let (adapter, writes) = try connected(queuing: "Hello")
        #expect(writes.map { $0["method"]?.stringValue } == ["initialize", "authenticate", "session/new", "session/prompt"])
        #expect(writes[1]["params"]?["methodId"]?.stringValue == "oauth-personal")
        #expect(writes[2]["params"]?["cwd"]?.stringValue == "/Users/demo/app")
        #expect(writes[3]["params"]?["prompt"]?[0]?["text"]?.stringValue == "Hello")
        #expect(adapter.isPrompting)
    }

    @Test func authenticationFailureBecomesALoginNotice() throws {
        var adapter = GeminiAdapter(options: Self.options)
        _ = adapter.startupLines()
        _ = adapter.consume(line: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{}}}"#)
        let output = adapter.consume(line: #"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Internal error","data":{"details":"This account requires setting the GOOGLE_CLOUD_PROJECT env var."}}}"#)
        guard case .systemNotice(let notice)? = output.events.first else {
            Issue.record("Expected a notice")
            return
        }
        #expect(notice.kind == "loginRequired")
        #expect(notice.text.contains("GOOGLE_CLOUD_PROJECT"))
    }

    @Test func promptTurnWithToolCallPermissionAndDiff() throws {
        var (adapter, _) = try connected()
        _ = try adapter.userMessageLines(text: "Write hello.txt", attachments: [])
        var events: [SessionEvent] = []
        func feed(_ line: String) -> AgentOutput {
            let output = adapter.consume(line: line)
            events += output.events
            return output
        }
        _ = feed(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Planning"}}}}"#)
        _ = feed(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"I'll create "}}}}"#)
        _ = feed(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"the file."}}}}"#)
        _ = feed(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"w1","title":"WriteFile hello.txt","kind":"edit","status":"pending","locations":[{"path":"/Users/demo/app/hello.txt"}]}}}"#)
        let permission = feed(#"{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"w1","title":"WriteFile hello.txt","kind":"edit","locations":[{"path":"/Users/demo/app/hello.txt"}]},"options":[{"optionId":"proceed_once","name":"Allow","kind":"allow_once"},{"optionId":"proceed_always","name":"Always","kind":"allow_always"},{"optionId":"cancel","name":"Reject","kind":"reject_once"}]}}"#)
        let request = try #require(permission.permissionRequests.first)
        #expect(request.tool == "Edit")
        #expect(request.input["file_path"]?.stringValue == "/Users/demo/app/hello.txt")
        let allow = try JSONValue.parse(try #require(adapter.permissionReply(to: request, allow: true)))
        #expect(allow["result"]?["outcome"]?["optionId"]?.stringValue == "proceed_once")
        let deny = try JSONValue.parse(try #require(adapter.permissionReply(to: request, allow: false)))
        #expect(deny["result"]?["outcome"]?["optionId"]?.stringValue == "cancel")

        _ = feed(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"w1","status":"completed","content":[{"type":"diff","path":"/Users/demo/app/hello.txt","oldText":null,"newText":"Hello"}]}}}"#)
        _ = feed(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done."}}}}"#)
        _ = feed(#"{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}"#)

        let persisted = events.filter { !$0.isEphemeral }
        let messages = persisted.compactMap { if case .assistantMessage(let message) = $0 { message.text } else { nil } }
        #expect(messages == ["I'll create the file.", "Done."])
        #expect(persisted.contains { if case .thinking(let thinking) = $0 { thinking.text == "Planning" } else { false } })
        let edit = persisted.compactMap { if case .fileEdit(let edit) = $0 { edit } else { nil } }.first
        #expect(edit?.kind == .created)
        #expect(edit?.diff.contains("+Hello") == true)
        guard case .result(let result)? = persisted.last else {
            Issue.record("Expected the turn result last")
            return
        }
        #expect(result.subtype == "success")
        #expect(!adapter.isPrompting)
        #expect(adapter.streamingText.isEmpty)
    }

    @Test func cancelWhilePrompting() throws {
        var (adapter, _) = try connected()
        #expect(adapter.interruptLines()?.isEmpty == true)
        _ = try adapter.userMessageLines(text: "Long task", attachments: [])
        let lines = adapter.interruptLines()
        let cancel = try parse(try #require(lines))
        #expect(cancel.first?["method"]?.stringValue == "session/cancel")
        let done = adapter.consume(line: #"{"jsonrpc":"2.0","id":4,"result":{"stopReason":"cancelled"}}"#)
        #expect(done.events.contains { if case .systemNotice(let notice) = $0 { notice.kind == "interrupted" } else { false } })
    }

    @Test func executeToolsBecomeBash() {
        let (name, input) = GeminiAdapter.tool(from: ["kind": "execute", "title": "ls -la", "rawInput": ["command": "ls -la"]])
        #expect(name == "Bash")
        #expect(input["command"]?.stringValue == "ls -la")
    }
}
