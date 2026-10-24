import Foundation
import PilothouseKit
import Testing
@testable import PilothouseHost

/// Feeds stream-json captured from Claude Code 2.1.310 through the normaliser.
@Suite struct StreamJSONNormalizerTests {
    func normalize(_ fixture: String) throws -> (events: [SessionEvent], normalizer: StreamJSONNormalizer) {
        var normalizer = StreamJSONNormalizer()
        var events: [SessionEvent] = []
        for line in try Fixtures.lines(fixture) {
            events += normalizer.consume(line: line)
        }
        return (events, normalizer)
    }

    @Test func writeAndBashTurn() throws {
        let (events, normalizer) = try normalize("stream-write-bash.jsonl")
        #expect(normalizer.claudeSessionId == "11111111-1111-4111-8111-111111111111")
        #expect(normalizer.model == "claude-haiku-5-5")
        #expect(normalizer.slashCommands.contains("review"))

        guard case .sessionInfo(let info) = events.first else {
            Issue.record("First event must be sessionInfo")
            return
        }
        #expect(info.claudeVersion == "2.1.310")
        #expect(info.cwd == "/Users/demo/project")

        let persisted = events.filter { !$0.isEphemeral }
        let tools = persisted.compactMap { event -> String? in if case .toolUse(let use) = event { use.name } else { nil } }
        #expect(tools == ["Write", "Bash"])

        let results = persisted.compactMap { event -> SessionEvent.ToolResult? in if case .toolResult(let result) = event { result } else { nil } }
        #expect(results.count == 2)
        #expect(results.last?.output == "hi")
        #expect(results.allSatisfy { !$0.isError })

        let edits = persisted.compactMap { event -> SessionEvent.FileEdit? in if case .fileEdit(let edit) = event { edit } else { nil } }
        #expect(edits.count == 1)
        #expect(edits.first?.kind == .created)
        #expect(edits.first?.path == "/Users/demo/project/hello.txt")
        #expect(edits.first?.diff.contains("+hi") == true)

        guard case .result(let result) = persisted.last else {
            Issue.record("Last persisted event must be the result")
            return
        }
        #expect(!result.isError)
        #expect(result.subtype == "success")
        #expect(result.costUSD != nil)
        #expect(result.usage?.outputTokens ?? 0 > 0)
        #expect(normalizer.streamingText.isEmpty)
    }

    @Test func deltasShareTheBlockIdOfTheFinalMessage() throws {
        let (events, _) = try normalize("stream-write-bash.jsonl")
        var streamed: [String: String] = [:]
        var final: [String: String] = [:]
        for event in events {
            switch event {
            case .assistantTextDelta(let delta): streamed[delta.blockId, default: ""] += delta.text
            case .assistantMessage(let message): final[message.blockId] = message.text
            default: break
            }
        }
        #expect(!final.isEmpty)
        for (blockId, text) in final {
            #expect(streamed[blockId] == text, "block \(blockId)")
        }
    }

    @Test func interruptedTurn() throws {
        let (events, _) = try normalize("stream-interrupted.jsonl")
        #expect(events.contains { $0.notice?.kind == "interrupted" })
        guard case .result(let result) = events.last else {
            Issue.record("Expected a final result")
            return
        }
        #expect(result.isError)
        #expect(result.subtype == "error_during_execution")
    }

    @Test func readEditTurnWithThinking() throws {
        let (events, _) = try normalize("stream-read-edit.jsonl")
        #expect(events.contains { if case .thinking(let thinking) = $0 { thinking.isComplete } else { false } })
        #expect(events.contains { if case .thinking(let thinking) = $0 { !thinking.isComplete } else { false } })
        let edit = events.compactMap { event -> SessionEvent.FileEdit? in if case .fileEdit(let edit) = event { edit } else { nil } }.first
        #expect(edit?.kind == .modified)
        #expect(edit?.diff == "@@ -1,3 +1,3 @@\n one\n-two\n+three\n four")
        let readResult = events.compactMap { event -> String? in if case .toolResult(let result) = event { result.output } else { nil } }.first
        #expect(readResult?.contains("two") == true)
    }

    @Test func subagentMessagesAreSkipped() {
        var normalizer = StreamJSONNormalizer()
        let line = #"{"type":"assistant","parent_tool_use_id":"toolu_parent","message":{"id":"m","content":[{"type":"text","text":"from a subagent"}]}}"#
        #expect(normalizer.consume(line: line).isEmpty)
    }

    @Test func garbageAndUnknownLinesAreIgnored() {
        var normalizer = StreamJSONNormalizer()
        #expect(normalizer.consume(line: "Warning: something on stdout").isEmpty)
        #expect(normalizer.consume(line: #"{"type":"brand_new_event","x":1}"#).isEmpty)
        #expect(normalizer.consume(line: "").isEmpty)
    }

    @Test func apiRetryAndAuthenticationFailures() {
        var normalizer = StreamJSONNormalizer()
        let retry = normalizer.consume(line: #"{"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"retry_delay_ms":4000,"error_status":529,"error":"overloaded"}"#)
        #expect(retry.first?.notice?.kind == "apiRetry")
        #expect(retry.first?.notice?.text.contains("529") == true)

        let auth = normalizer.consume(line: #"{"type":"system","subtype":"api_retry","attempt":3,"max_retries":10,"retry_delay_ms":1000,"error_status":401,"error":"authentication_failed"}"#)
        #expect(auth.first?.notice?.kind == "loginRequired")

        let result = normalizer.consume(line: #"{"type":"result","subtype":"success","is_error":true,"duration_ms":3,"result":"Invalid API key · Please run /login"}"#)
        #expect(result.first?.notice?.kind == "loginRequired")
        #expect(result.last?.isResult == true)
    }

    @Test func toolResultContentBlocksAreFlattened() {
        let content: JSONValue = [
            ["type": "text", "text": "line one"],
            ["type": "image", "source": ["type": "base64"]],
            ["type": "text", "text": "<tool_use_error>boom</tool_use_error>"],
        ]
        #expect(StreamJSONNormalizer.stringify(content) == "line one\n[image]\nboom")
    }

    @Test func hugeToolInputsAreTruncated() {
        var normalizer = StreamJSONNormalizer()
        let big = String(repeating: "a", count: StreamJSONNormalizer.maximumTextLength + 100)
        let line = #"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"t","name":"Write","input":{"file_path":"/x","content":"\#(big)"}}]}}"#
        guard case .toolUse(let use) = normalizer.consume(line: line).first else {
            Issue.record("Expected toolUse")
            return
        }
        #expect((use.input["content"]?.stringValue?.count ?? 0) < big.count)
    }
}
