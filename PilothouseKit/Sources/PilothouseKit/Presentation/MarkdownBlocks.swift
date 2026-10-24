import Foundation

/// Block-level Markdown structure for chat rendering.
///
/// SwiftUI's `AttributedString(markdown:)` handles inline syntax (emphasis,
/// code spans, links) but not blocks, so this small parser splits a reply into
/// headings, paragraphs, lists, quotes, rules, tables and fenced code; inline
/// content is rendered with `AttributedString` (docs/DECISIONS.md D-050).
public enum MarkdownBlock: Sendable, Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String)
    case list(ordered: Bool, items: [ListItem])
    case quote(String)
    case table(rows: [[String]])
    case rule

    public struct ListItem: Sendable, Hashable {
        public var text: String
        public var indent: Int
        /// `true`/`false` for task-list items (`- [x]`), `nil` otherwise.
        public var checked: Bool?
        public var number: Int?
    }

    /// Parses `text`. An unterminated code fence (still streaming) becomes a code block.
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listItems: [ListItem] = []
        var listOrdered = false
        var quote: [String] = []
        var table: [[String]] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        func flushList() {
            if !listItems.isEmpty {
                blocks.append(.list(ordered: listOrdered, items: listItems))
                listItems = []
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
        }
        func flushTable() {
            if !table.isEmpty {
                blocks.append(.table(rows: table))
                table = []
            }
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
            flushTable()
        }

        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")))
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }

            // Heading.
            if let heading = Self.heading(trimmed) {
                flushAll()
                blocks.append(heading)
                index += 1
                continue
            }

            // Horizontal rule.
            if Self.isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                index += 1
                continue
            }

            // Table row.
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count > 1 {
                flushParagraph()
                flushList()
                flushQuote()
                let cells = trimmed.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let isSeparator = cells.allSatisfy { cell in
                    !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
                }
                if !isSeparator { table.append(cells) }
                index += 1
                continue
            }

            // Block quote.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                flushTable()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                index += 1
                continue
            }

            // List item.
            if let item = Self.listItem(line) {
                flushParagraph()
                flushQuote()
                flushTable()
                let ordered = item.number != nil
                if !listItems.isEmpty, ordered != listOrdered, item.indent == 0 {
                    flushList()
                }
                if listItems.isEmpty { listOrdered = ordered }
                listItems.append(item)
                index += 1
                continue
            }

            // Continuation of a list item.
            if !listItems.isEmpty, line.hasPrefix("  ") {
                listItems[listItems.count - 1].text += " " + trimmed
                index += 1
                continue
            }

            flushList()
            flushQuote()
            flushTable()
            paragraph.append(line)
            index += 1
        }
        flushAll()
        return blocks
    }

    static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func listItem(_ line: String) -> ListItem? {
        let indentWidth = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.trimmingCharacters(in: .whitespaces)
        var text: Substring
        var number: Int?
        if let marker = body.first, "-*+".contains(marker), body.dropFirst().first == " " {
            text = body.dropFirst(2)
        } else {
            let digits = body.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let afterDigits = body.dropFirst(digits.count)
            guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")", afterDigits.dropFirst().first == " " else {
                return nil
            }
            number = Int(digits)
            text = afterDigits.dropFirst(2)
        }
        var checked: Bool?
        if text.hasPrefix("[ ] ") {
            checked = false
            text = text.dropFirst(4)
        } else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            checked = true
            text = text.dropFirst(4)
        }
        return ListItem(text: String(text), indent: indentWidth / 2, checked: checked, number: number)
    }
}
