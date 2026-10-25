import RemoteCodeKit
import SwiftUI

/// A live Claude Code session (prompt §6.2.4).
struct ChatView: View {
    let connection: MacConnection
    let sessionId: String

    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var attachments: [ComposerAttachment] = []
    /// When the running turn started, for the timer in the composer.
    @State private var busySince: Date?
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var confirmDelete = false
    @State private var subAgent: SubAgentSelection?
    @State private var isPickingCommand = false

    private var chat: ChatState { connection.chat(for: sessionId) }
    private var session: SessionSummary? { connection.session(sessionId) }
    private var isBusy: Bool { session?.state.isBusy ?? false }
    private var isClosed: Bool { session?.state == .closed }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(chat.items) { item in
                    TranscriptItemView(item: item, workingDirectory: session?.cwd, thumbnails: chat.thumbnails[item.id] ?? [])
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
        .background(GradientBackground(intensity: 0.35))
        .onChange(of: isBusy, initial: true) { _, busy in
            busySince = busy ? (busySince ?? Date()) : nil
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .toolbar { toolbar }
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.openSubAgent, OpenSubAgentAction { subAgent = SubAgentSelection(call: $0) })
        .onChange(of: draft) { old, new in
            // A "/" typed into an empty field opens the full list of skills and commands.
            if old.isEmpty, new == "/" { isPickingCommand = true }
        }
        .sheet(isPresented: $isPickingCommand) {
            if let session {
                CommandPickerView(connection: connection, session: session) { name in
                    // Replace a lone "/" (typed to open the list), keep anything else after the command.
                    let rest = draft == "/" ? "" : draft
                    draft = "/\(name) " + rest
                }
            }
        }
        .sheet(item: $subAgent) { selection in
            SubAgentTranscriptView(
                connection: connection, sessionId: sessionId, call: selection.call, workingDirectory: session?.cwd
            )
        }
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
            if let agent = session?.agentKind, agent != .claude {
                Text("Ask \(agent.displayName) anything about this folder")
                    .font(.headline)
                Text("\(agent.displayName) runs on your Mac. You'll see every step here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Ask Claude anything about this folder")
                    .font(.headline)
                Text("Claude runs on your Mac with Claude Code. You'll see every step here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            banners
            if !chat.runningSubAgents.isEmpty {
                RunningSubAgentsBar(calls: chat.runningSubAgents, workingDirectory: session?.cwd)
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
                    modelLabel: modelLabel,
                    effort: session?.effort,
                    settingsMenu: settingsMenu,
                    onSlash: session?.agentKind == .claude ? { isPickingCommand = true } : nil,
                    placeholder: composerPlaceholder,
                    activity: activity,
                    onStop: { run { try await connection.interrupt(sessionId) } },
                    onSend: send
                )
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
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
                        if let settingsMenu {
                            settingsMenu
                        } else {
                            Label(session.model ?? String(localized: "Default model"), systemImage: "cpu")
                        }
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

    /// Model and effort pickers, when the Mac can change them (capability `sessionSettings`).
    private var settingsMenu: AnyView? {
        guard let session, connection.capabilities.contains(HostCapability.sessionSettings) else { return nil }
        return AnyView(SessionSettingsMenuContent(connection: connection, session: session) { errorMessage = $0 })
    }

    /// "Opus 5.5" rather than `claude-opus-5-5` when the Mac knows the model list.
    private var modelLabel: String? {
        guard let session else { return nil }
        let status = connection.status?.agents?.first { $0.kind == session.agentKind }
        if let model = session.model, !model.isEmpty {
            return status?.modelOption(for: model)?.displayName ?? model
        }
        return status?.defaultModelOption?.displayName ?? String(localized: "Agent default")
    }

    /// The running turn, shown inside the composer.
    private var activity: ComposerActivity? {
        guard isBusy else { return nil }
        let detail = chat.runningTool.map { tool in
            let summary = ToolSummary(name: tool.name, input: tool.input, workingDirectory: session?.cwd)
            return [String(localized: String.LocalizationValue(summary.title)), summary.detail].compactMap { $0 }.joined(separator: " · ")
        }
        return ComposerActivity(isWaitingForApproval: session?.state == .awaitingPermission, detail: detail, since: busySince ?? Date())
    }

    private var composerPlaceholder: LocalizedStringKey {
        if let agent = session?.agentKind, agent != .claude {
            return LocalizedStringKey("Message \(agent.displayName)…")
        }
        return LocalizedStringKey("Message Claude…")
    }

    private var subtitle: String {
        guard let session else { return "" }
        let path = session.cwd.abbreviatingHome(homeGuess(session.cwd))
        return "\(path) · \(session.agentKind.displayName)"
    }

    /// `/Users/<name>` prefix of a macOS path, used to abbreviate it as `~`.
    private func homeGuess(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "Users" else { return nil }
        return "/Users/\(parts[1])"
    }

    // MARK: Actions

    private func send() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || !attachments.isEmpty else { return }
        let outgoing = attachments
        // Video frames come with a line that says what they are.
        let text = ([typed] + outgoing.compactMap(\.note)).filter { !$0.isEmpty }.joined(separator: "\n\n")
        draft = ""
        attachments = []
        isSending = true
        chat.noteOutgoing(text: text, thumbnails: outgoing.map(\.thumbnail))
        Task {
            defer { isSending = false }
            do {
                try await connection.send(text, attachments: outgoing.flatMap(\.payloads), to: sessionId)
            } catch {
                draft = typed
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
