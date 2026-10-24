import PilothouseKit
import SwiftUI

/// Renders assistant Markdown: blocks via `MarkdownBlock`, inline syntax via
/// `AttributedString(markdown:)` (docs/DECISIONS.md D-050).
struct MarkdownView: View {
    let text: String
    var isStreaming = false

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isLast: index == blocks.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        default: .headline
        }
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock, isLast: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            InlineText(text, cursor: isStreaming && isLast)
                .font(headingFont(level))
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            InlineText(text, cursor: isStreaming && isLast)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(checked ? Color.accentColor : .secondary)
                            } else if ordered {
                                Text(verbatim: "\(item.number ?? index + 1).").monospacedDigit()
                            } else {
                                Text(verbatim: "•")
                            }
                        }
                        .foregroundStyle(.secondary)
                        InlineText(item.text, cursor: isStreaming && isLast && index == items.count - 1)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)
                InlineText(text, cursor: false)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                InlineText(cell, cursor: false)
                                    .font(rowIndex == 0 ? .subheadline.bold() : .subheadline)
                            }
                        }
                        if rowIndex == 0 { Divider() }
                    }
                }
                .padding(10)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        case .rule:
            Divider()
        }
    }
}

/// A paragraph with inline Markdown; falls back to plain text.
struct InlineText: View {
    let text: String
    let cursor: Bool

    init(_ text: String, cursor: Bool) {
        self.text = text
        self.cursor = cursor
    }

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var result = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)
        let codeRanges = result.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }.map(\.range)
        for range in codeRanges {
            result[range][AttributeScopes.SwiftUIAttributes.FontAttribute.self] = .system(.body, design: .monospaced)
            result[range][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Color.secondary.opacity(0.15)
        }
        if cursor {
            var caret = AttributedString(" ▍")
            caret[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Color.accentColor
            result += caret
        }
        return result
    }
}

/// A fenced code block with a language label and a copy button.
struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: language ?? "code")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Haptics.tap()
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Group {
                        if copied {
                            Label("Copied", systemImage: "checkmark")
                        } else {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Copy code"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}
