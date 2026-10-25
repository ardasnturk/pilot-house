import RemoteCodeKit
import SwiftUI

/// Pick a folder on the Mac and start a Claude Code session there (prompt §6.2.3).
struct NewChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var path: String?
    @State private var listing: DirectoryListing?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var search = ""
    @State private var showHidden = false
    @State private var selectedModel = ""
    @State private var selectedEffort = ""
    @State private var customModel = ""
    @State private var permissionMode: PermissionMode = .default
    @State private var firstMessage = ""
    @State private var isStarting = false
    @State private var startError: String?
    @State private var didApplyDefaults = false
    @State private var agent: AgentKind = .claude
    @State private var isNamingFolder = false
    @State private var newFolderName = ""
    @State private var folderError: String?

    private static let customModelTag = "__custom__"

    var body: some View {
        NavigationStack {
            List {
                if let listing {
                    Section {
                        Breadcrumb(listing: listing) { path = $0 }
                    } header: {
                        Text("Where")
                    }
                }
                if search.isEmpty {
                    shortcuts
                }
                folderSection
                optionsSection
            }
            .listStyle(.insetGrouped)
            .gradientBackground(intensity: 0.7)
            .searchable(text: $search, prompt: Text("Filter this folder"))
            .navigationTitle(Text("New Chat"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { startBar }
            .task(id: TaskKey(path: path, showHidden: showHidden)) { await load() }
            .onAppear(perform: applyDefaults)
            .alert(Text("Could not start the session"), isPresented: Binding(get: { startError != nil }, set: { if !$0 { startError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(startError ?? "")
            }
            .alert(Text("New Folder"), isPresented: $isNamingFolder) {
                TextField("Name", text: $newFolderName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("newFolderName")
                Button("Cancel", role: .cancel) {}
                Button("Create") { Task { await createFolder() } }
                    .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text("The folder is created in \(listing.map { $0.displayPath } ?? "~") on your Mac.")
            }
            .alert(Text("Could not create the folder"), isPresented: Binding(get: { folderError != nil }, set: { if !$0 { folderError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(folderError ?? "")
            }
        }
    }

    private struct TaskKey: Equatable {
        var path: String?
        var showHidden: Bool
    }

    // MARK: Sections

    @ViewBuilder private var shortcuts: some View {
        let favorites = model.preferences.favoriteFolders
        let recents = model.preferences.recentFolders.filter { !favorites.contains($0) }
        if !favorites.isEmpty {
            Section {
                ForEach(favorites, id: \.self) { folder in
                    shortcutRow(folder, symbol: "star.fill")
                }
            } header: {
                Text("Favorites")
            }
        }
        if !recents.isEmpty {
            Section {
                ForEach(recents, id: \.self) { folder in
                    shortcutRow(folder, symbol: "clock")
                }
            } header: {
                Text("Recent")
            }
        }
    }

    private func shortcutRow(_ folder: String, symbol: String) -> some View {
        Button {
            path = folder
        } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(folder.lastPathComponent)
                    Text(folder.abbreviatingHome(listing?.homePath))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol).foregroundStyle(Color.accentColor)
            }
        }
        .foregroundStyle(.primary)
    }

    @ViewBuilder private var folderSection: some View {
        Section {
            if isLoading && listing == nil {
                HStack {
                    ProgressView()
                    Text("Loading…").foregroundStyle(.secondary)
                }
            } else if let loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Try Again") { Task { await load() } }
                }
            } else if let listing {
                let entries = filtered(listing.entries)
                if entries.isEmpty {
                    Group {
                        if search.isEmpty {
                            Text("This folder is empty.")
                        } else {
                            Text("No matches.")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    FolderRow(entry: entry) {
                        if entry.isDirectory { path = entry.path }
                    }
                }
                if listing.truncated {
                    Text("Only the first entries are shown.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("Folders")
                Spacer()
                if canCreateFolders {
                    Button {
                        newFolderName = ""
                        isNamingFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(listing == nil)
                    .accessibilityIdentifier("newFolderButton")
                }
            }
        }
    }

    /// "Who" (agent cards) and "How" (permission chips, model, first message).
    @ViewBuilder private var optionsSection: some View {
        if availableAgents.count > 1 {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                    ForEach(availableAgents) { status in
                        AgentChoiceCard(status: status, isSelected: agent == status.kind) {
                            agent = status.kind
                        }
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("agentPicker")
                .onChange(of: agent) { _, _ in
                    selectedModel = agent == .claude ? model.preferences.defaultModel : ""
                    selectedEffort = defaultEffort(for: agent)
                }
                if let status = availableAgents.first(where: { $0.kind == agent }), status.loggedIn == false {
                    Label("\(agent.displayName) is not signed in on your Mac. Run it once in Terminal there.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Who")
            }
        }
        Section {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(availableModes, id: \.self) { mode in
                            Button {
                                permissionMode = mode
                            } label: {
                                Label {
                                    Text(mode.localizedName)
                                } icon: {
                                    Image(systemName: mode.symbol)
                                }
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .foregroundStyle(chipColor(mode))
                                .background(chipColor(mode).opacity(permissionMode == mode ? 0.16 : 0.06), in: Capsule())
                                .overlay(Capsule().strokeBorder(chipColor(mode).opacity(permissionMode == mode ? 0.6 : 0), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(permissionMode == mode ? .isSelected : [])
                        }
                    }
                }
                Text(permissionMode.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(permissionMode == .bypassPermissions ? .red : .secondary)
            }
            .padding(.vertical, 4)
            Picker(selection: $selectedModel) {
                if agent == .claude {
                    Text("Mac default").tag("")
                } else {
                    Text("Agent default").tag("")
                }
                ForEach(modelOptions.filter { !$0.isOlder }, id: \.id) { option in
                    Text(verbatim: option.displayName).tag(option.id)
                }
                let older = modelOptions.filter(\.isOlder)
                if !older.isEmpty {
                    Section {
                        ForEach(older, id: \.id) { option in
                            Text(verbatim: option.displayName).tag(option.id)
                        }
                    } header: {
                        Text("Earlier models")
                    }
                }
                Text("Custom…").tag(Self.customModelTag)
            } label: {
                Label("Model", systemImage: "cpu")
            }
            if selectedModel == Self.customModelTag {
                TextField("Model ID", text: $customModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if supportsEffort {
                Picker(selection: $selectedEffort) {
                    Text("Agent default").tag("")
                    ForEach(effortLevels, id: \.self) { level in
                        Text(EffortLevel.localizedName(level)).tag(level)
                    }
                } label: {
                    Label("Effort", systemImage: "gauge.with.dots.needle.67percent")
                }
                .accessibilityIdentifier("effortPicker")
                .onChange(of: selectedModel) { _, _ in
                    if !effortLevels.contains(selectedEffort) { selectedEffort = "" }
                }
            }
            TextField("First message (optional)", text: $firstMessage, axis: .vertical)
                .lineLimit(1...4)
        } header: {
            Text("How")
        }
    }

    private func chipColor(_ mode: PermissionMode) -> Color {
        if permissionMode != mode { return .secondary }
        return mode == .bypassPermissions ? .red : .accentColor
    }

    private var supportsEffort: Bool {
        !effortLevels.isEmpty && model.connection?.capabilities.contains(HostCapability.sessionSettings) == true
    }

    /// The default effort from Settings, if this agent accepts it.
    private func defaultEffort(for agent: AgentKind) -> String {
        let effort = model.preferences.defaultEffort
        let levels = availableAgents.first { $0.kind == agent }?.effortLevels(for: nil) ?? agent.effortLevels
        return levels.contains(effort) ? effort : ""
    }

    /// Installed agents the Mac reported (Claude Code alone on older Macs).
    private var availableAgents: [AgentStatus] {
        guard let connection = model.connection, connection.capabilities.contains(HostCapability.agents) else { return [] }
        return connection.status?.availableAgents ?? []
    }

    /// The agent's own model list (Mac 1.1), else the known aliases / model IDs.
    private var modelOptions: [ModelOption] {
        let status = availableAgents.first { $0.kind == agent }
        if let options = status?.modelOptions, !options.isEmpty { return options }
        let names = agent == .claude ? UserPreferences.modelSuggestions.filter { !$0.isEmpty } : status?.models ?? []
        return names.map { ModelOption(id: $0, displayName: agent == .claude ? $0.capitalized : $0) }
    }

    private var selectedModelID: String? {
        let id = selectedModel == Self.customModelTag ? customModel : selectedModel
        return id.isEmpty ? nil : id
    }

    /// Levels the chosen model takes (the agent's own list on Mac 1.1).
    private var effortLevels: [String] {
        availableAgents.first { $0.kind == agent }?.effortLevels(for: selectedModelID) ?? agent.effortLevels
    }

    private var canCreateFolders: Bool {
        model.connection?.capabilities.contains(HostCapability.createDirectory) == true
    }

    private var availableModes: [PermissionMode] {
        var modes = PermissionMode.standardModes
        if model.connection?.status?.bypassPermissionsAllowed == true { modes.append(.bypassPermissions) }
        return modes
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Toggle(isOn: $showHidden) {
                    Label("Show Hidden Files", systemImage: "eye")
                }
                if let listing {
                    Button {
                        model.preferences.toggleFavorite(listing.path)
                    } label: {
                        if model.preferences.favoriteFolders.contains(listing.path) {
                            Label("Remove from Favorites", systemImage: "star.slash")
                        } else {
                            Label("Add to Favorites", systemImage: "star")
                        }
                    }
                }
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
        }
    }

    private var startBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                Task { await start() }
            } label: {
                HStack {
                    if isStarting { ProgressView().tint(.white) }
                    Text("Start in \(listing.map { $0.displayPath } ?? "~")")
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(listing == nil || isStarting || model.connection?.isConnected != true)
            .padding()
            .accessibilityIdentifier("startSessionButton")
        }
        .background(.bar)
    }

    // MARK: Actions

    private func applyDefaults() {
        guard !didApplyDefaults else { return }
        didApplyDefaults = true
        selectedModel = model.preferences.defaultModel
        selectedEffort = defaultEffort(for: agent)
        permissionMode = model.preferences.defaultPermissionMode
    }

    private func filtered(_ entries: [FileNode]) -> [FileNode] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func load() async {
        guard let connection = model.connection else { return }
        isLoading = true
        loadError = nil
        do {
            listing = try await connection.listDirectory(path, showHidden: showHidden)
            search = ""
        } catch {
            loadError = (error as? ErrorPayload)?.message ?? error.localizedDescription
        }
        isLoading = false
    }

    /// Creates the folder on the Mac and opens it, so the session can start there.
    private func createFolder() async {
        guard let connection = model.connection, let listing else { return }
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let parent = try await connection.createDirectory(in: listing.path, name: name)
            self.listing = parent
            if let created = parent.entries.first(where: { $0.name == name && $0.isDirectory }) {
                path = created.path
            }
            Haptics.success()
        } catch {
            folderError = (error as? ErrorPayload)?.message ?? error.localizedDescription
        }
    }

    private func start() async {
        guard let connection = model.connection, let listing else { return }
        isStarting = true
        defer { isStarting = false }
        let modelName = selectedModel == Self.customModelTag ? customModel.trimmingCharacters(in: .whitespaces) : selectedModel
        do {
            let message = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            let session = try await connection.startSession(
                cwd: listing.path,
                model: modelName.isEmpty ? nil : modelName,
                permissionMode: permissionMode,
                firstMessage: message.isEmpty ? nil : message,
                agent: agent,
                effort: supportsEffort && !selectedEffort.isEmpty ? selectedEffort : nil
            )
            model.preferences.noteRecent(listing.path)
            model.selectedSessionId = session.id
            Haptics.success()
            dismiss()
        } catch {
            startError = (error as? ErrorPayload)?.message ?? error.localizedDescription
        }
    }
}

/// `~ › Developer › app` path buttons.
struct Breadcrumb: View {
    let listing: DirectoryListing
    let navigate: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    Button(crumb.name) { navigate(crumb.path) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(index == crumbs.count - 1 ? .accentColor : .secondary)
                }
            }
        }
        .defaultScrollAnchor(.trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Current folder: \(listing.displayPath)"))
    }

    private var crumbs: [(name: String, path: String)] {
        var result: [(name: String, path: String)] = [(name: "~", path: listing.homePath)]
        guard listing.path.hasPrefix(listing.homePath) else { return result }
        var current = listing.homePath
        for component in listing.path.dropFirst(listing.homePath.count).split(separator: "/") {
            current += "/\(component)"
            result.append((name: String(component), path: current))
        }
        return result
    }
}

struct FolderRow: View {
    let entry: FileNode
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .foregroundStyle(entry.isDirectory ? .primary : .secondary)
                    if entry.isGitRepository {
                        Text("Git repository")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .disabled(!entry.isDirectory)
        .accessibilityIdentifier("folder-\(entry.name)")
    }

    private var icon: String {
        if entry.isGitRepository { return "arrow.triangle.branch" }
        if entry.isDirectory { return entry.isSymbolicLink ? "folder.badge.questionmark" : "folder.fill" }
        return "doc"
    }
}

/// One selectable agent in "Who".
struct AgentChoiceCard: View {
    let status: AgentStatus
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                AgentAvatar(agent: status.kind, size: 30)
                Text(verbatim: status.kind.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if status.loggedIn == false {
                    Text("Not signed in")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Design.insetBackground.opacity(isSelected ? 0 : 1), in: RoundedRectangle(cornerRadius: Design.controlRadius, style: .continuous))
            .background(status.kind.tint.opacity(isSelected ? 0.14 : 0), in: RoundedRectangle(cornerRadius: Design.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Design.controlRadius, style: .continuous)
                    .strokeBorder(status.kind.tint, lineWidth: isSelected ? 1.5 : 0)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: status.kind.displayName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("agent-\(status.kind.rawValue)")
    }
}
