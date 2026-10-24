import PilothouseKit
import SwiftUI

/// A live Claude Code session (prompt §6.2.4).
struct ChatView: View {
    let connection: MacConnection
    let sessionId: String

    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var attachments: [MessageAttachment] = []
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var confirmDelete = false

    private var chat: ChatState { connection.chat(for: sessionId) }
    private var session: SessionSummary? { connection.session(sessionId) }
    private var isBusy: Bool { session?.state.isBusy ?? false }
    private var isClosed: Bool { session?.state == .closed }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(chat.items) { item in
                    TranscriptItemView(item: item, workingDirectory: session?.cwd)
                        .id(item.id)
                }
                if chat.items.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .toolbar { toolbar }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sessionId) {
            await connection.open(sessionId)
        }
        .alert(Text("Something went wrong"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(Text("Delete this session?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                run {
                    try await connection.delete(sessionId)
                    model.selectedSessionId = nil
                }
            }
        } message: {
            Text("The transcript is removed from your Mac and this device. Files Claude changed are not affected.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Ask Claude anything about this folder")
                .font(.headline)
            Text("Claude runs on your Mac with Claude Code. You'll see every step here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            banners
            if isBusy {
                WorkingIndicator(
                    state: session?.state ?? .running,
                    runningTool: chat.runningTool,
                    workingDirectory: session?.cwd
                ) {
                    run { try await connection.interrupt(sessionId) }
                }
            }
            if isClosed {
                Button {
                    run { try await connection.resume(sessionId) }
                } label: {
                    Label("Continue This Session", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!connection.isConnected)
            } else {
                ComposerView(
                    text: $draft,
                    attachments: $attachments,
                    slashCommands: session?.slashCommands ?? chat.info?.slashCommands ?? [],
                    isEnabled: connection.isConnected && !isSending,
                    onSend: send
                )
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    @ViewBuilder private var banners: some View {
        if !connection.isConnected {
            Banner(symbol: "wifi.slash", tint: .orange) {
                Text("Offline — showing the saved transcript. Claude keeps working on your Mac.")
            }
        } else if let notice = connection.resumedWhileAwayNotice {
            Banner(symbol: "checkmark.circle", tint: .accentColor) {
                Text(notice)
            }
            .onTapGesture { connection.resumedWhileAwayNotice = nil }
            .task {
                try? await Task.sleep(for: .seconds(6))
                connection.resumedWhileAwayNotice = nil
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(session?.title ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .accessibilityElement(children: .combine)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let session {
                    Section {
                        Label(session.cwd, systemImage: "folder")
                        Label(session.model ?? String(localized: "Default model"), systemImage: "cpu")
                        Label {
                            Text(session.permissionMode.localizedName)
                        } icon: {
                            Image(systemName: session.permissionMode.symbol)
                        }
                    }
                }
                if let text = chat.lastAssistantText {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("Copy Last Reply", systemImage: "doc.on.doc")
                    }
                }
                if isClosed {
                    Button {
                        run { try await connection.resume(sessionId) }
                    } label: {
                        Label("Continue Session", systemImage: "play")
                    }
                } else {
                    Button {
                        run { try await connection.close(sessionId) }
                    } label: {
                        Label("Close Session", systemImage: "stop")
                    }
                }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete Session", systemImage: "trash")
                }
            } label: {
                Label("Session", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("sessionMenu")
        }
    }

    private var subtitle: String {
        guard let session else { return "" }
        let path = session.cwd.abbreviatingHome(homeGuess(session.cwd))
        if let model = session.model {
            return "\(path) · \(model)"
        }
        return path
    }

    /// `/Users/<name>` prefix of a macOS path, used to abbreviate it as `~`.
    private func homeGuess(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "Users" else { return nil }
        return "/Users/\(parts[1])"
    }

    // MARK: Actions

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let outgoing = attachments
        draft = ""
        attachments = []
        isSending = true
        Task {
            defer { isSending = false }
            do {
                try await connection.send(text, attachments: outgoing, to: sessionId)
            } catch {
                draft = text
                attachments = outgoing
                errorMessage = (error as? ErrorPayload)?.message ?? error.localizedDescription
            }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                errorMessage = (error as? ErrorPayload)?.message ?? error.localizedDescription
            }
        }
    }
}

/// A small coloured info strip above the composer.
struct Banner<Content: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            content
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// "Working…" with the current tool and a Stop button.
struct WorkingIndicator: View {
    let state: SessionState
    let runningTool: ToolCall?
    let workingDirectory: String?
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                if state == .awaitingPermission {
                    Text("Waiting for your approval…")
                        .font(.subheadline.weight(.medium))
                } else {
                    Text("Working…")
                        .font(.subheadline.weight(.medium))
                }
                if let tool = runningTool {
                    let summary = ToolSummary(name: tool.name, input: tool.input, workingDirectory: workingDirectory)
                    Text(verbatim: [summary.title, summary.detail].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button(role: .destructive, action: onStop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .accessibilityIdentifier("stopButton")
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}
