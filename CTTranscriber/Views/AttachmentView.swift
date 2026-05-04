import SwiftUI
import AppKit

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
        if attachment.isDeleted || attachment.modelContext == nil {
            EmptyView()
        } else {
            Group {
                switch attachment.kind {
                case .audio:
                    AudioPlayerView(attachment: attachment, seekRequest: $seekRequest)
                case .video:
                    if isUnsupportedVideo && attachment.convertedName == nil {
                        UnsupportedVideoView(attachment: attachment, isConverting: false)
                    } else {
                        let playName = attachment.convertedName ?? attachment.storedName
                        let url = FileStorage.url(for: playName)
                        let ratio = ChatTableView.Coordinator.videoAspectRatio(url: url) ?? (16.0 / 9.0)
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
            .onDrag {
                let url = FileStorage.url(for: attachment.storedName)
                let provider = NSItemProvider(item: url as NSURL, typeIdentifier: "public.file-url")
                provider.suggestedName = attachment.originalName
                return provider
            }
            .contextMenu {
                Button("Save As...") {
                    saveAttachment(attachment)
                }
                Button("Reveal in Finder") {
                    let url = FileStorage.url(for: attachment.storedName)
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                }
            }
        }
    }

    private func saveAttachment(_ attachment: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.originalName
        if panel.runModal() == .OK, let destURL = panel.url {
            let sourceURL = FileStorage.url(for: attachment.storedName)
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            } catch let error as NSError where error.code == NSFileWriteFileExistsError {
                do {
                    try FileManager.default.removeItem(at: destURL)
                    try FileManager.default.copyItem(at: sourceURL, to: destURL)
                } catch {
                    showSaveError(error)
                }
            } catch {
                showSaveError(error)
            }
        }
    }

    private func showSaveError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Save Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
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
