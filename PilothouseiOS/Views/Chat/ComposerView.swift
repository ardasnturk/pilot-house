import PhotosUI
import PilothouseKit
import SwiftUI

/// Multi-line message field with slash-command suggestions and image attachments.
struct ComposerView: View {
    @Binding var text: String
    @Binding var attachments: [MessageAttachment]
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
    let onSend: () -> Void

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var attachmentError: String?
    @FocusState private var isFocused: Bool

    private var suggestions: [String] {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return [] }
        let query = text.dropFirst().lowercased()
        return slashCommands.filter { query.isEmpty || $0.lowercased().hasPrefix(query) }.prefix(6).map { $0 }
    }

    private var canSend: Bool {
        isEnabled && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

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
            if !attachments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                        AttachmentChip(attachment: attachment) {
                            attachments.remove(at: index)
                        }
                    }
                }
            }
            if let attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photoSelection, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(Design.insetBackground, in: Circle())
                }
                .disabled(!isEnabled)
                .accessibilityLabel(Text("Attach images"))

                if let onSlash {
                    Button(action: onSlash) {
                        Image(systemName: "slash.circle")
                            .font(.body.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .background(Design.insetBackground, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
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

                if let modelLabel, text.isEmpty {
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

                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(canSend ? Color.accentColor : Color.secondary.opacity(0.4), in: Circle())
                }
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(Text("Send"))
                .accessibilityIdentifier("sendButton")
            }
            .padding(6)
            .padding(.leading, 0)
            .floatingSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .onChange(of: photoSelection) { _, items in
            Task { await loadPhotos(items) }
        }
    }

    private func modelChip(_ label: String, symbol: String?) -> some View {
        Chip(text: chipText(label), symbol: symbol)
            .accessibilityLabel(Text("Model: \(label)"))
            .accessibilityValue(effort.map { Text(EffortLevel.localizedName($0)) } ?? Text(verbatim: ""))
    }

    private func chipText(_ label: String) -> Text {
        guard let effort else { return Text(verbatim: label) }
        return Text(verbatim: "\(label) · ") + Text(EffortLevel.localizedName(effort))
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        attachmentError = nil
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { continue }
            if let jpeg = Self.compress(image) {
                attachments.append(MessageAttachment(mediaType: "image/jpeg", data: jpeg))
            } else {
                attachmentError = String(localized: "An image was too large to send.")
            }
        }
        photoSelection = []
    }

    /// JPEG under the 5 MB protocol limit, longest side at most 2048 px.
    static func compress(_ image: UIImage) -> Data? {
        let maxSide: CGFloat = 2_048
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        for quality in [0.8, 0.6, 0.4] {
            if let data = resized.jpegData(compressionQuality: quality), data.count <= MessageAttachment.maxBytes {
                return data
            }
        }
        return nil
    }
}

struct AttachmentChip: View {
    let attachment: MessageAttachment
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = UIImage(data: attachment.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
            .accessibilityLabel(Text("Remove image"))
        }
    }
}
