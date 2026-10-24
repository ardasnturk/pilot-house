import Foundation

/// One line of a unified diff, classified for colouring.
public struct DiffLine: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case hunk
        case added
        case removed
        case context
    }

    public var id: Int
    public var kind: Kind
    public var text: String
}

/// Diff helpers for Edit/Write tool cards.
public enum DiffBuilder {
    /// Splits a unified diff into classified lines.
    public static func lines(of diff: String) -> [DiffLine] {
        diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, raw in
            let line = String(raw)
            let kind: DiffLine.Kind
            if line.hasPrefix("@@") {
                kind = .hunk
            } else if line.hasPrefix("+") {
                kind = .added
            } else if line.hasPrefix("-") {
                kind = .removed
            } else {
                kind = .context
            }
            return DiffLine(id: index, kind: kind, text: line)
        }
    }

    /// A diff synthesised from a tool's *input*, used before the tool ran
    /// (permission cards) or when the CLI reported no structured patch.
    public static func preview(tool: String, input: JSONValue) -> String? {
        switch tool {
        case "Edit":
            guard let old = input["old_string"]?.stringValue, let new = input["new_string"]?.stringValue else { return nil }
            return replacement(old: old, new: new)
        case "MultiEdit":
            let edits = input["edits"]?.arrayValue ?? []
            let parts = edits.compactMap { edit -> String? in
                guard let old = edit["old_string"]?.stringValue, let new = edit["new_string"]?.stringValue else { return nil }
                return replacement(old: old, new: new)
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        case "Write":
            guard let content = input["content"]?.stringValue else { return nil }
            var lines = content.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            return (["@@ -0,0 +1,\(lines.count) @@"] + lines.map { "+\($0)" }).joined(separator: "\n")
        default:
            return nil
        }
    }

    private static func replacement(old: String, new: String) -> String {
        let removed = old.components(separatedBy: "\n").map { "-\($0)" }
        let added = new.components(separatedBy: "\n").map { "+\($0)" }
        return (["@@"] + removed + added).joined(separator: "\n")
    }

    /// `+added −removed` counts for a card header.
    public static func stats(of diff: String) -> (added: Int, removed: Int) {
        lines(of: diff).reduce(into: (0, 0)) { counts, line in
            switch line.kind {
            case .added: counts.0 += 1
            case .removed: counts.1 += 1
            default: break
            }
        }
    }
}

/// Human-oriented description of a tool call for card headers.
public struct ToolSummary: Sendable, Hashable {
    public enum Category: Sendable, Hashable {
        case read
        case edit
        case write
        case shell
        case search
        case web
        case todo
        case agent
        case other
    }

    public var category: Category
    /// SF Symbol name.
    public var symbol: String
    /// Short verb-like title, e.g. "Read", "Edit", "Run".
    public var title: String
    /// The most relevant argument (path, command, pattern, URL).
    public var detail: String?

    public init(name: String, input: JSONValue, workingDirectory: String? = nil) {
        func relative(_ path: String?) -> String? {
            guard let path else { return nil }
            if let base = workingDirectory, path.hasPrefix(base + "/") {
                return String(path.dropFirst(base.count + 1))
            }
            return path
        }
        switch name {
        case "Read":
            self = ToolSummary(category: .read, symbol: "doc.text", title: "Read", detail: relative(input["file_path"]?.stringValue))
        case "Edit", "MultiEdit":
            self = ToolSummary(category: .edit, symbol: "pencil", title: "Edit", detail: relative(input["file_path"]?.stringValue))
        case "Write":
            self = ToolSummary(category: .write, symbol: "doc.badge.plus", title: "Write", detail: relative(input["file_path"]?.stringValue))
        case "NotebookEdit":
            self = ToolSummary(category: .edit, symbol: "book.pages", title: "Edit notebook", detail: relative(input["notebook_path"]?.stringValue))
        case "Bash", "BashOutput":
            self = ToolSummary(category: .shell, symbol: "terminal", title: "Run", detail: input["command"]?.stringValue ?? input["description"]?.stringValue)
        case "Grep":
            self = ToolSummary(category: .search, symbol: "text.magnifyingglass", title: "Search", detail: input["pattern"]?.stringValue)
        case "Glob":
            self = ToolSummary(category: .search, symbol: "folder.badge.questionmark", title: "Find files", detail: input["pattern"]?.stringValue)
        case "WebFetch":
            self = ToolSummary(category: .web, symbol: "globe", title: "Fetch", detail: input["url"]?.stringValue)
        case "WebSearch":
            self = ToolSummary(category: .web, symbol: "magnifyingglass", title: "Web search", detail: input["query"]?.stringValue)
        case "TodoWrite":
            self = ToolSummary(category: .todo, symbol: "checklist", title: "Tasks", detail: nil)
        case "Task", "Agent":
            self = ToolSummary(category: .agent, symbol: "person.2", title: "Sub-agent", detail: input["description"]?.stringValue)
        default:
            let display = name.hasPrefix("mcp__") ? name.split(separator: "_", omittingEmptySubsequences: true).dropFirst().joined(separator: " · ") : name
            self = ToolSummary(category: .other, symbol: "wrench.and.screwdriver", title: display, detail: nil)
        }
    }

    public init(category: Category, symbol: String, title: String, detail: String?) {
        self.category = category
        self.symbol = symbol
        self.title = title
        self.detail = detail
    }
}

/// An entry of a `TodoWrite` list.
public struct TodoItem: Sendable, Hashable, Identifiable {
    public enum Status: String, Sendable, Hashable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public var id: Int
    public var content: String
    public var status: Status

    public static func items(from todos: JSONValue?) -> [TodoItem] {
        (todos?.arrayValue ?? []).enumerated().compactMap { index, todo in
            guard let content = todo["content"]?.stringValue else { return nil }
            let status = Status(rawValue: todo["status"]?.stringValue ?? "") ?? .pending
            return TodoItem(id: index, content: content, status: status)
        }
    }
}
