import AVFoundation
import CoreTransferable
import PhotosUI
import RemoteCodeKit
import SwiftUI
import UniformTypeIdentifiers

/// Something attached in the composer: one photo, or a video sent as a few
/// evenly spaced frames (agent CLIs take images, not video; D-106).
struct ComposerAttachment: Identifiable, Equatable {
    enum Kind: Equatable {
        case image
        case video(seconds: Double)
    }

    let id = UUID()
    var kind: Kind
    /// What is sent: one JPEG for a photo, the frames for a video.
    var payloads: [MessageAttachment]
    /// Small JPEG shown in the composer and the sent bubble.
    var thumbnail: Data

    /// Line added to the message so the agent knows the images are video frames.
    var note: String? {
        guard case .video(let seconds) = kind else { return nil }
        let duration = Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
        return String(localized: "[Video, \(duration): the \(payloads.count) images attached are frames from it, evenly spaced from start to end.]")
    }
}

/// Turns picked photos, videos and camera shots into attachments.
enum AttachmentMaker {
    /// Frames taken from a video.
    static let videoFrameCount = 6
    /// The most images one message may carry.
    static let maximumImages = 20

    static func image(_ image: UIImage) -> ComposerAttachment? {
        guard let jpeg = compress(image), let thumbnail = thumbnail(image) else { return nil }
        return ComposerAttachment(kind: .image, payloads: [MessageAttachment(mediaType: "image/jpeg", data: jpeg)], thumbnail: thumbnail)
    }

    static func video(at url: URL) async -> ComposerAttachment? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_280, height: 1_280)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var frames: [UIImage] = []
        for index in 0..<videoFrameCount {
            // Centre of each slice, so the first and last frames are not black fades.
            let seconds = duration.seconds * (Double(index) + 0.5) / Double(videoFrameCount)
            if let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image {
                frames.append(UIImage(cgImage: frame))
            }
        }
        let payloads = frames.compactMap { compress($0).map { MessageAttachment(mediaType: "image/jpeg", data: $0) } }
        guard let first = frames.first, !payloads.isEmpty, let thumbnail = thumbnail(first) else { return nil }
        return ComposerAttachment(kind: .video(seconds: duration.seconds), payloads: payloads, thumbnail: thumbnail)
    }

    static func load(_ item: PhotosPickerItem) async -> ComposerAttachment? {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { return nil }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            return await video(at: movie.url)
        }
        guard let data = try? await item.loadTransferable(type: Data.self), let picture = UIImage(data: data) else { return nil }
        return image(picture)
    }

    /// JPEG under the 5 MB protocol limit, longest side at most 2048 px.
    static func compress(_ image: UIImage) -> Data? {
        let resized = resize(image, maxSide: 2_048)
        for quality in [0.8, 0.6, 0.4] {
            if let data = resized.jpegData(compressionQuality: quality), data.count <= MessageAttachment.maxBytes {
                return data
            }
        }
        return nil
    }

    static func thumbnail(_ image: UIImage) -> Data? {
        resize(image, maxSide: 240).jpegData(compressionQuality: 0.7)
    }

    private static func resize(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        guard scale < 1 else { return image }
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

/// A video from the photo library, copied to a temporary file.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// The camera, for a photo (video would need microphone access too).
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// Thumbnail in the composer, with a remove button and a video badge.
struct AttachmentChip: View {
    let attachment: ComposerAttachment
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = UIImage(data: attachment.thumbnail) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo")
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if case .video = attachment.kind {
                    Image(systemName: "video.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(4)
                }
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
            .accessibilityLabel(Text("Remove attachment"))
        }
    }
}
