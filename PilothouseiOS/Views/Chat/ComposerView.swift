import PhotosUI
import PilothouseKit
import SwiftUI

/// What the agent is doing, shown inside the composer while a turn runs (D-104).
struct ComposerActivity: Equatable {
    var isWaitingForApproval: Bool
    /// "Edit · Sources/App.swift" for the running tool, if any.
    var detail: String?
    var since: Date
}

/// Multi-line message field with slash-command suggestions, photo and video
/// attachments, the model chip and, while the agent works, its status and Stop.
struct ComposerView: View {
    @Binding var text: String
    @Binding var attachments: [ComposerAttachment]
    let slashCommands: [String]
    let isEnabled: Bool
    /// Agent and model shown inside the field, e.g. "Codex · gpt-6.1-sol".
    var modelLabel: String?
    /// Effort level shown after the model (`AgentKind.effortLevels`).
    var effort: String?
    /// Menu opened by tapping the model chip (model and effort pickers).
    var settingsMenu: AnyView?
    /// Opens the list of skills and commands (the `/` button).
    var onSlash: (() -> Void)?
    var placeholder: LocalizedStringKey = "Message Claude…"
    /// Set while a turn runs: shown inside the field, Send becomes Stop.
    var activity: ComposerActivity?
    var onStop: () -> Void = {}
    let onSend: () -> Void

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isPickingPhotos = false
    @State private var isUsingCamera = false
    @State private var isLoadingAttachments = false
    @State private var attachmentError: String?
    @FocusState private var isFocused: Bool

    private var suggestions: [String] {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return [] }
        let query = text.dropFirst().lowercased()
        return slashCommands.filter { query.isEmpty || $0.lowercased().hasPrefix(query) }.prefix(6).map { $0 }
    }

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var canSend: Bool { isEnabled && hasContent && !isLoadingAttachments }

    private var imageCount: Int { attachments.reduce(0) { $0 + $1.payloads.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(suggestions, id: \.self) { command in
                            Button {
                                text = "/\(command) "
                            } label: {
                                Text(verbatim: "/\(command)")
                                    .font(.callout.monospaced())
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .accessibilityLabel(Text("Slash command suggestions"))
            }
            if let attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let activity {
                    activityRow(activity)
                }
                if !attachments.isEmpty || isLoadingAttachments {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(attachments) { attachment in
                                AttachmentChip(attachment: attachment) {
                                    attachments.removeAll { $0.id == attachment.id }
                                }
                            }
                            if isLoadingAttachments {
                                ProgressView()
                                    .frame(width: 60, height: 60)
                            }
                        }
                        .padding(.top, 8)
                        .padding(.horizontal, 6)
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    addMenu
                    if let onSlash {
                        circleButton(symbol: "slash.circle", action: onSlash)
                            .disabled(!isEnabled)
                            .accessibilityLabel(Text("Skills and commands"))
                            .accessibilityIdentifier("slashButton")
                    }

                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(1...8)
                        .focused($isFocused)
                        .submitLabel(.return)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("composerField")

                    if let modelLabel, text.isEmpty, activity == nil {
                        if let settingsMenu {
                            Menu {
                                settingsMenu
                            } label: {
                                modelChip(modelLabel, symbol: "chevron.up.chevron.down")
                            }
                            .padding(.bottom, 6)
                            .accessibilityLabel(Text("Model: \(modelLabel)"))
                            .accessibilityValue(effort.map { Text(EffortLevel.localizedName($0)) } ?? Text(verbatim: ""))
                            .accessibilityIdentifier("modelChip")
                        } else {
                            modelChip(modelLabel, symbol: nil)
                                .padding(.bottom, 6)
                        }
                    }

                    sendOrStop
                }
            }
            .padding(6)
            .floatingSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                if activity != nil {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Brand.bubbleGradient, lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
        }
        .photosPicker(
            isPresented: $isPickingPhotos,
            selection: $photoSelection,
            maxSelectionCount: 6,
            matching: .any(of: [.images, .videos])
        )
        .fullScreenCover(isPresented: $isUsingCamera) {
            CameraPicker { image in
                if let attachment = AttachmentMaker.image(image) { add([attachment]) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoSelection) { _, items in
            Task { await loadPicked(items) }
        }
    }

    // MARK: Pieces

    private var addMenu: some View {
        Menu {
            Button {
                isPickingPhotos = true
            } label: {
                Label("Photos and Videos", systemImage: "photo.on.rectangle")
            }
            if CameraPicker.isAvailable {
                Button {
                    isUsingCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
                .background(Design.insetBackground, in: Circle())
        }
        .disabled(!isEnabled)
        .accessibilityLabel(Text("Attach photos or videos"))
        .accessibilityIdentifier("attachButton")
    }

    private func circleButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
                .background(Design.insetBackground, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    /// Stop while the agent works and nothing new is typed; Send otherwise
    /// (a message sent during a turn is queued by the agent).
    @ViewBuilder private var sendOrStop: some View {
        if activity != nil, !hasContent {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.red, in: Circle())
            }
            .accessibilityLabel(Text("Stop"))
            .accessibilityIdentifier("stopButton")
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background {
                        if canSend {
                            Circle().fill(Brand.bubbleGradient)
                        } else {
                            Circle().fill(Color.secondary.opacity(0.4))
                        }
                    }
            }
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(Text("Send"))
            .accessibilityIdentifier("sendButton")
        }
    }

    private func activityRow(_ activity: ComposerActivity) -> some View {
        HStack(spacing: 8) {
            WorkingDots()
            VStack(alignment: .leading, spacing: 1) {
                if activity.isWaitingForApproval {
                    Text("Waiting for your approval")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                } else {
                    Text("Working")
                        .font(.footnote.weight(.semibold))
                }
                if let detail = activity.detail {
                    Text(verbatim: detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            TimelineView(.periodic(from: activity.since, by: 1)) { context in
                Text(verbatim: Duration.seconds(max(0, context.date.timeIntervalSince(activity.since)))
                    .formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workingIndicator")
    }

    private func modelChip(_ label: String, symbol: String?) -> some View {
        Chip(text: chipText(label), symbol: symbol)
    }

    private func chipText(_ label: String) -> Text {
        guard let effort else { return Text(verbatim: label) }
        return Text(verbatim: "\(label) · ") + Text(EffortLevel.localizedName(effort))
    }

    // MARK: Loading

    private func loadPicked(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        photoSelection = []
        attachmentError = nil
        isLoadingAttachments = true
        defer { isLoadingAttachments = false }
        var loaded: [ComposerAttachment] = []
        var failed = false
        for item in items {
            if let attachment = await AttachmentMaker.load(item) {
                loaded.append(attachment)
            } else {
                failed = true
            }
        }
        add(loaded)
        if failed {
            attachmentError = String(localized: "Some photos or videos could not be loaded.")
        }
    }

    private func add(_ new: [ComposerAttachment]) {
        for attachment in new {
            guard imageCount + attachment.payloads.count <= AttachmentMaker.maximumImages else {
                attachmentError = String(localized: "That's the most images one message can carry.")
                return
            }
            attachments.append(attachment)
        }
    }
}

/// Three dots pulsing one after the other, in the brand gradient.
struct WorkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.15)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: 3) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Brand.bubbleGradient)
                        .frame(width: 6, height: 6)
                        .opacity(index == phase ? 1 : 0.35)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
