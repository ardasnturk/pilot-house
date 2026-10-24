import PilothouseKit
import SwiftUI

/// Renders one `TranscriptItem`.
struct TranscriptItemView: View {
    let item: TranscriptItem
    let workingDirectory: String?
    var thumbnails: [Data] = []

    var body: some View {
        switch item.kind {
        case .user(let text, let attachments):
            UserBubble(text: text, attachments: attachments, thumbnails: thumbnails)
        case .assistant(let text, let isStreaming):
            MarkdownView(text: text, isStreaming: isStreaming)
                .accessibilityIdentifier("assistantMessage")
        case .thinking(let text, let isComplete):
            ThinkingRow(text: text, isComplete: isComplete)
        case .tool(let call):
            ToolCardView(call: call, workingDirectory: workingDirectory)
        case .notice(let notice):
            NoticeRow(notice: notice)
        case .turnEnd(let result):
            TurnEndRow(result: result)
        case .permission(let decision):
            DecisionRow(decision: decision)
        }
    }
}

struct UserBubble: View {
    let text: String
    let attachments: Int
    var thumbnails: [Data] = []
    @State private var preview: PreviewImage?

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                if !thumbnails.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, data in
                            if let image = UIImage(data: data) {
                                Button {
                                    preview = PreviewImage(image: image)
                                } label: {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else if attachments > 0 {
                    Label("\(attachments) image(s)", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                if !text.isEmpty {
                    Text(verbatim: text)
                        .textSelection(.enabled)
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Brand.bubbleGradient,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20, style: .continuous
                )
            )
            .shadow(color: Brand.indigo.opacity(0.18), radius: 8, y: 3)
        }
        .sheet(item: $preview) { preview in
            ImagePreviewSheet(image: preview.image)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("You: \(text)"))
        .accessibilityIdentifier("userMessage")
    }
}

struct ThinkingRow: View {
    let text: String
    let isComplete: Bool
    @State private var showsText = false

    var body: some View {
        Button {
            if !text.isEmpty { showsText = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .symbolEffect(.pulse, isActive: !isComplete)
                    .accessibilityHidden(true)
                if isComplete {
                    Text("Thought")
                } else {
                    Text("Thinking…")
                }
                if !text.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .accessibilityHidden(true)
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showsText) {
            NavigationStack {
                ScrollView {
                    Text(verbatim: text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .gradientBackground(intensity: 0.4)
                .navigationTitle(Text("Thinking"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsText = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

struct NoticeRow: View {
    let notice: SessionEvent.SystemNotice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(notice.text))
                .foregroundStyle(notice.level == .info ? .secondary : .primary)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch notice.level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private var color: Color {
        switch notice.level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

struct TurnEndRow: View {
    let result: SessionEvent.TurnResult

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(.quaternary).frame(height: 1)
            Group {
                if result.isError {
                    Label("Stopped", systemImage: "stop.circle")
                } else {
                    Label {
                        Text(details)
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = [String(localized: "Done in \(result.durationMs.formattedDuration)")]
        if let cost = result.costUSD {
            parts.append(cost.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))
        }
        return parts.joined(separator: " · ")
    }
}

struct DecisionRow: View {
    let decision: SessionEvent.PermissionDecision

    var body: some View {
        Label {
            Text(verbatim: "\(decision.toolName): \(decision.summary)")
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: decision.outcome == .denied || decision.outcome == .timedOut ? "hand.raised.slash" : "hand.thumbsup")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct PreviewImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// A sent photo, full screen with pinch to zoom.
struct ImagePreviewSheet: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }.onEnded { _ in withAnimation { scale = 1 } })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
