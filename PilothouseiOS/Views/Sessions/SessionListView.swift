import PilothouseKit
import SwiftUI

/// Sessions of the active Mac (prompt §6.2.2).
struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDeletion: SessionSummary?
    @State private var actionError: String?

    var body: some View {
        @Bindable var model = model
        Group {
            if let connection = model.connection {
                list(connection)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Text(model.activeMac?.name ?? "Pilothouse"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.isPresentingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("settingsButton")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.isPresentingNewChat = true
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .disabled(model.connection?.isConnected != true)
                .accessibilityIdentifier("newChatButton")
            }
        }
        .alert(Text("Something went wrong"), isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .confirmationDialog(
            Text("Delete this session?"),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { session in
            Button("Delete", role: .destructive) {
                perform { try await model.connection?.delete(session.id) }
                if model.selectedSessionId == session.id { model.selectedSessionId = nil }
            }
        } message: { _ in
            Text("The transcript is removed from your Mac and this device. Files Claude changed are not affected.")
        }
    }

    private func list(_ connection: MacConnection) -> some View {
        @Bindable var model = model
        let open = connection.sessions.filter { $0.state != .closed }
        let closed = connection.sessions.filter { $0.state == .closed }
        return List(selection: $model.selectedSessionId) {
            Section {
                ConnectionStatusRow(connection: connection)
            }
            if connection.sessions.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No sessions yet").font(.headline)
                        Text("Tap the compose button to pick a folder on your Mac and start Claude Code there.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
            if !open.isEmpty {
                Section {
                    ForEach(open) { session in
                        row(session, connection: connection)
                    }
                } header: {
                    Text("Active")
                }
            }
            if !closed.isEmpty {
                Section {
                    ForEach(closed) { session in
                        row(session, connection: connection)
                    }
                } header: {
                    Text("Earlier")
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await connection.refreshSessions()
        }
    }

    private func row(_ session: SessionSummary, connection: MacConnection) -> some View {
        SessionRow(
            session: session,
            needsApproval: connection.pendingPermissions.contains { $0.sessionId == session.id }
        )
        .tag(session.id)
        .accessibilityIdentifier("session-\(session.title)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDeletion = session
            } label: {
                Label("Delete", systemImage: "trash")
            }
            if session.state == .closed {
                Button {
                    perform { try await connection.resume(session.id) }
                } label: {
                    Label("Continue", systemImage: "play.fill")
                }
                .tint(.accentColor)
            } else {
                Button {
                    perform { try await connection.close(session.id) }
                } label: {
                    Label("Close", systemImage: "stop.fill")
                }
                .tint(.orange)
            }
        }
        .contextMenu {
            if session.state == .closed {
                Button {
                    perform { try await connection.resume(session.id) }
                } label: {
                    Label("Continue", systemImage: "play")
                }
            } else {
                Button {
                    perform { try await connection.close(session.id) }
                } label: {
                    Label("Close Session", systemImage: "stop")
                }
            }
            Button {
                UIPasteboard.general.string = session.cwd
            } label: {
                Label("Copy Folder Path", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                pendingDeletion = session
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                actionError = (error as? ErrorPayload)?.message ?? error.localizedDescription
            }
        }
    }
}

/// One session in the list.
struct SessionRow: View {
    let session: SessionSummary
    let needsApproval: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(session.folderName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if session.agentKind != .claude {
                    AgentBadge(agent: session.agentKind)
                }
                Spacer()
                Text(session.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(session.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                stateBadge
            }
            if let preview = session.lastMessagePreview {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var stateBadge: some View {
        if needsApproval || session.state == .awaitingPermission {
            Label("Needs approval", systemImage: "hand.raised.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.orange)
        } else if session.state.isBusy {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Working"))
        }
    }
}

/// Mac name and how we are connected (local / Tailscale / offline).
struct ConnectionStatusRow: View {
    let connection: MacConnection

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.mac.name).font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    statusText
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if case .waitingToRetry = connection.state {
                Button("Retry") { connection.appBecameActive() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectionStatus")
    }

    private var color: Color {
        switch connection.state {
        case .connected: .green
        case .connecting, .waitingToRetry: .orange
        case .idle, .failed: .red
        }
    }

    @ViewBuilder private var statusText: some View {
        switch connection.state {
        case .connected(let route, _):
            Text("Connected · \(Text(route.localizedName))")
        case .connecting:
            Text("Connecting…")
        case .waitingToRetry:
            Text("Offline · retrying")
        case .idle:
            Text("Offline")
        case .failed(let message, _):
            Text(message).lineLimit(2)
        }
    }
}
