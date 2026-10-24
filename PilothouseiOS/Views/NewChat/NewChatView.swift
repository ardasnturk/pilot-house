import PilothouseKit
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
    @State private var customModel = ""
    @State private var permissionMode: PermissionMode = .default
    @State private var firstMessage = ""
    @State private var isStarting = false
    @State private var startError: String?
    @State private var didApplyDefaults = false

    private static let customModelTag = "__custom__"

    var body: some View {
        NavigationStack {
            List {
                if let listing {
                    Section {
                        Breadcrumb(listing: listing) { path = $0 }
                    }
                }
                if search.isEmpty {
                    shortcuts
                }
                folderSection
                optionsSection
            }
            .listStyle(.insetGrouped)
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
            Text("Folders")
        }
    }

    private var optionsSection: some View {
        Section {
            Picker(selection: $selectedModel) {
                Text("Mac default").tag("")
                ForEach(UserPreferences.modelSuggestions.filter { !$0.isEmpty }, id: \.self) { name in
                    Text(name.capitalized).tag(name)
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
            Picker(selection: $permissionMode) {
                ForEach(availableModes, id: \.self) { mode in
                    Text(mode.localizedName).tag(mode)
                }
            } label: {
                Label("Permissions", systemImage: permissionMode.symbol)
            }
            Text(permissionMode.localizedDescription)
                .font(.footnote)
                .foregroundStyle(permissionMode == .bypassPermissions ? .red : .secondary)
            TextField("First message (optional)", text: $firstMessage, axis: .vertical)
                .lineLimit(1...4)
        } header: {
            Text("Session")
        }
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
                firstMessage: message.isEmpty ? nil : message
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
