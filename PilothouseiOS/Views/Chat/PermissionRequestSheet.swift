import PilothouseKit
import SwiftUI

/// Bottom sheet for a permission request (prompt §6.2.4): what Claude wants to
/// do, a preview, and Allow / Deny / Always allow in this session.
struct PermissionRequestSheet: View {
    let request: PermissionRequest
    let session: SessionSummary?
    let connection: MacConnection
    let onLater: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var summary: ToolSummary {
        ToolSummary(name: request.tool, input: request.input, workingDirectory: request.cwd)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    preview
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) { buttons }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") {
                        onLater()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isWorking)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: summary.symbol)
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 44, height: 44)
                .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude wants to use \(request.tool)")
                    .font(.headline)
                if let session {
                    Text(verbatim: "\(session.title) · \(session.folderName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(request.expiresAt.timeIntervalSince(context.date)))
                    Text("Denied automatically in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var preview: some View {
        switch summary.category {
        case .shell:
            if let command = request.input["command"]?.stringValue {
                ShellCommandView(command: command)
            }
            if let description = request.input["description"]?.stringValue {
                Text(verbatim: description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .edit, .write:
            if let path = summary.detail {
                Label(path, systemImage: "doc")
                    .font(.subheadline.monospaced())
            }
            if let diff = DiffBuilder.preview(tool: request.tool, input: request.input) {
                DiffView(diff: diff)
            }
        case .web:
            if let detail = summary.detail {
                Label(detail, systemImage: "globe")
                    .font(.subheadline.monospaced())
            }
        default:
            OutputBlock(text: request.input.jsonString(pretty: true), isError: false)
        }
        Label(request.cwd, systemImage: "folder")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    answer(allow: false, remember: false)
                } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityIdentifier("denyButton")

                Button {
                    answer(allow: true, remember: false)
                } label: {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("allowButton")
            }
            .controlSize(.large)
            Button {
                answer(allow: true, remember: true)
            } label: {
                Text("Always allow \(rememberDescription) in this session")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
            .accessibilityIdentifier("alwaysAllowButton")
        }
        .disabled(isWorking || !connection.isConnected)
        .padding()
        .background(.bar)
    }

    /// `npm` commands / Edit.
    private var rememberDescription: String {
        let key = request.rememberKey
        if key.hasPrefix("Bash("), key.hasSuffix(")") {
            let program = key.dropFirst(5).dropLast()
            return String(localized: "“\(String(program))” commands")
        }
        return key
    }

    private func answer(allow: Bool, remember: Bool) {
        isWorking = true
        Task {
            do {
                try await connection.respond(to: request, allow: allow, remember: remember)
                dismiss()
            } catch {
                errorMessage = (error as? ErrorPayload)?.message ?? error.localizedDescription
            }
            isWorking = false
        }
    }
}
