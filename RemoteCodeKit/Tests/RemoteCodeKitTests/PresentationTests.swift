import Foundation
import Testing
@testable import RemoteCodeKit

@Suite struct MarkdownBlockTests {
    @Test func parsesCommonBlocks() {
        let text = """
            # Title
            Intro with **bold** and `code`.
            Second line.

            - one
            - [x] two
              continued
            1. first
            2) second

            > quoted
            > more

            ```swift
            let x = 1
            ```
            ---
            | A | B |
            |---|:-:|
            | 1 | 2 |
            """
        let blocks = MarkdownBlock.parse(text)
        #expect(blocks.count == 8)
        #expect(blocks[0] == .heading(level: 1, text: "Title"))
        #expect(blocks[1] == .paragraph("Intro with **bold** and `code`.\nSecond line."))
        guard case .list(false, let bullets) = blocks[2] else {
            Issue.record("Expected bullet list, got \(blocks[2])")
            return
        }
        #expect(bullets.map(\.text) == ["one", "two continued"])
        #expect(bullets[1].checked == true)
        guard case .list(true, let numbered) = blocks[3] else {
            Issue.record("Expected ordered list, got \(blocks[3])")
            return
        }
        #expect(numbered.map(\.number) == [1, 2])
        #expect(blocks[4] == .quote("quoted\nmore"))
        #expect(blocks[5] == .code(language: "swift", code: "let x = 1"))
        #expect(blocks[6] == .rule)
        #expect(blocks[7] == .table(rows: [["A", "B"], ["1", "2"]]))
    }

    @Test func unterminatedFenceWhileStreaming() {
        let blocks = MarkdownBlock.parse("Here:\n```bash\nnpm test")
        #expect(blocks.last == .code(language: "bash", code: "npm test"))
    }

    @Test func notHeadingsOrLists() {
        #expect(MarkdownBlock.parse("#hashtag") == [.paragraph("#hashtag")])
        #expect(MarkdownBlock.parse("-not a list") == [.paragraph("-not a list")])
        #expect(MarkdownBlock.parse("3.14 is pi") == [.paragraph("3.14 is pi")])
    }
}

@Suite struct ToolPresentationTests {
    @Test func diffLinesAreClassified() {
        let lines = DiffBuilder.lines(of: "@@ -1,2 +1,2 @@\n one\n-two\n+three")
        #expect(lines.map(\.kind) == [.hunk, .context, .removed, .added])
        #expect(DiffBuilder.stats(of: "@@\n-a\n+b\n+c") == (added: 2, removed: 1))
    }

    @Test func previewsFromToolInput() {
        #expect(DiffBuilder.preview(tool: "Edit", input: ["old_string": "a\nb", "new_string": "c"]) == "@@\n-a\n-b\n+c")
        #expect(DiffBuilder.preview(tool: "Write", input: ["content": "x\ny\n"]) == "@@ -0,0 +1,2 @@\n+x\n+y")
        #expect(DiffBuilder.preview(tool: "MultiEdit", input: ["edits": [["old_string": "1", "new_string": "2"]]]) == "@@\n-1\n+2")
        #expect(DiffBuilder.preview(tool: "Bash", input: ["command": "ls"]) == nil)
    }

    @Test func summaries() {
        let read = ToolSummary(name: "Read", input: ["file_path": "/w/src/a.swift"], workingDirectory: "/w")
        #expect(read.title == "Read")
        #expect(read.detail == "src/a.swift")
        #expect(ToolSummary(name: "Bash", input: ["command": "npm test"]).detail == "npm test")
        #expect(ToolSummary(name: "mcp__github__create_issue", input: [:]).title == "github · create · issue")
        #expect(ToolSummary(name: "TodoWrite", input: [:]).category == .todo)
    }

    @Test func todoItems() {
        let todos: JSONValue = [
            ["content": "A", "status": "completed"],
            ["content": "B", "status": "in_progress"],
            ["content": "C", "status": "weird"],
            ["status": "pending"],
        ]
        let items = TodoItem.items(from: todos)
        #expect(items.map(\.content) == ["A", "B", "C"])
        #expect(items.map(\.status) == [.completed, .inProgress, .pending])
    }
}
