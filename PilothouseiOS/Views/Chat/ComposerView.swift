import PhotosUI
import PilothouseKit
import SwiftUI

/// Multi-line message field with slash-command suggestions and image attachments.
struct ComposerView: View {
    @Binding var text: String
    @Binding var attachments: [MessageAttachment]
    let slashCommands: [String]
    let isEnabled: Bool
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
            HStack(alignment: .bottom, spacing: 10) {
                PhotosPicker(selection: $photoSelection, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "photo.badge.plus")
                        .font(.title3)
                }
                .disabled(!isEnabled)
                .accessibilityLabel(Text("Attach images"))

                TextField("Message Claude…", text: $text, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .submitLabel(.return)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityIdentifier("composerField")

                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .symbolRenderingMode(.hierarchical)
                }
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(Text("Send"))
                .accessibilityIdentifier("sendButton")
            }
        }
        .onChange(of: photoSelection) { _, items in
            Task { await loadPhotos(items) }
        }
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
