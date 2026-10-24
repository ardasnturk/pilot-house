import PilothouseKit
import SwiftUI

/// The `/` menu: every skill and slash command of the session, searchable,
/// skills and commands in separate sections (D-098).
struct CommandPickerView: View {
    enum Filter: Hashable { case all, skills, commands }

    let connection: MacConnection
    let session: SessionSummary
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var commands: [CommandInfo] = []
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if session.agentKind != .claude {
                    Label("\(session.agentKind.displayName) does not report its commands to Pilothouse.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                } else if isLoading && commands.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if commands.isEmpty {
                    Text("Claude reports its skills and commands when the session starts. Send a first message, then open this list again.")
                        .foregroundStyle(.secondary)
                }
                if filter != .commands, !skills.isEmpty {
                    Section {
                        ForEach(skills) { row($0) }
                    } header: {
                        Text("Skills · \(skills.count)")
                    }
                }
                if filter != .skills, !plainCommands.isEmpty {
                    Section {
                        ForEach(plainCommands) { row($0) }
                    } header: {
                        Text("Commands · \(plainCommands.count)")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search skills and commands"))
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker(selection: $filter) {
                    Text("All").tag(Filter.all)
                    Text("Skills").tag(Filter.skills)
                    Text("Commands").tag(Filter.commands)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityIdentifier("commandFilter")
            }
            .navigationTitle(Text("Skills and Commands"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var matching: [CommandInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        let needle = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        guard !needle.isEmpty else { return commands }
        return commands
            .filter { $0.name.lowercased().contains(needle) || ($0.description?.lowercased().contains(needle) ?? false) }
            .sorted { lhs, rhs in
                // Names that start with the query first.
                let left = lhs.name.lowercased().hasPrefix(needle), right = rhs.name.lowercased().hasPrefix(needle)
                return left != right ? left : lhs.name < rhs.name
            }
    }

    private var skills: [CommandInfo] { matching.filter { $0.kind == .skill } }
    private var plainCommands: [CommandInfo] { matching.filter { $0.kind == .command } }

    private func row(_ command: CommandInfo) -> some View {
        Button {
            choose(command.name)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "/\(command.name)")
                        .font(.body.monospaced().weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    sourceChip(command)
                }
                if let description = command.description {
                    Text(verbatim: description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("command-\(command.name)")
    }

    @ViewBuilder private func sourceChip(_ command: CommandInfo) -> some View {
        switch command.source {
        case .personal: Chip(text: Text("Personal"), tint: .accentColor)
        case .project: Chip(text: Text("Project"), tint: .green)
        case .plugin: Chip(text: Text(verbatim: command.plugin ?? "Plugin"), tint: .indigo)
        case .builtin: Chip(text: Text("Built-in"))
        }
    }

    private func load() async {
        guard session.agentKind == .claude else {
            isLoading = false
            return
        }
        defer { isLoading = false }
        if connection.capabilities.contains(HostCapability.commandCatalog) {
            do {
                commands = try await connection.listCommands(sessionId: session.id)
            } catch {
                self.error = (error as? ErrorPayload)?.message ?? error.localizedDescription
            }
        } else {
            // Older Macs: names only, no way to tell skills apart.
            commands = session.slashCommands.map { CommandInfo(name: $0, kind: .command, source: .builtin) }
        }
    }
}
