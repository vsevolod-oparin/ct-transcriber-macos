import SwiftUI

// MARK: - Attachment View

struct AttachmentView: View {
    let attachment: Attachment
    @Binding var seekRequest: (id: UUID, storedName: String, time: TimeInterval)?

    /// File extensions that AVPlayer cannot play natively on macOS.
    private static let unsupportedVideoExtensions: Set<String> = ["webm", "mkv", "flv", "wmv"]

    private var isUnsupportedVideo: Bool {
        let ext = attachment.storedName.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        // Also check original name
        let origExt = attachment.originalName.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        return Self.unsupportedVideoExtensions.contains(ext) || Self.unsupportedVideoExtensions.contains(origExt)
    }

    var body: some View {
        switch attachment.kind {
        case .audio:
            AudioPlayerView(attachment: attachment, seekRequest: $seekRequest)
        case .video:
            if isUnsupportedVideo && attachment.convertedName == nil {
                UnsupportedVideoView(attachment: attachment, isConverting: true)
            } else {
                let playName = attachment.convertedName ?? attachment.storedName
                let url = FileStorage.url(for: playName)
                let ratio = ChatTableView.Coordinator.videoAspectRatio(url: url)
                VideoPlayerView(attachment: attachment,
                                playbackStoredName: attachment.convertedName,
                                initialAspectRatio: ratio,
                                seekRequest: $seekRequest
                )
            }
        case .image:
            ImageAttachmentView(attachment: attachment)
        case .text:
            FileAttachmentBadge(attachment: attachment, iconName: "doc.text")
        }
    }
}

// MARK: - Image Attachment

struct ImageAttachmentView: View {
    let attachment: Attachment
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            FileAttachmentBadge(attachment: attachment, iconName: "photo")
        }
        .task {
            // Load image on background thread to avoid blocking scroll
            let url = FileStorage.url(for: attachment.storedName)
            let loaded = await Task.detached(priority: .utility) {
                NSImage(contentsOf: url)
            }.value
            image = loaded
        }
    }
}

// MARK: - Generic File Badge

struct FileAttachmentBadge: View {
    let attachment: Attachment
    let iconName: String
    @Environment(\.fontScale) private var fontScale

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
            Text(attachment.originalName)
                .lineLimit(1)
        }
        .font(ScaledFont(scale: fontScale).caption)
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
