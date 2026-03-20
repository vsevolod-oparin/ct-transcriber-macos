import SwiftUI
import AVFoundation
import AVKit

// MARK: - Audio/Video Player with Seek Bar

struct AudioPlayerView: View {
    let attachment: Attachment
    /// Binding to the ViewModel's seek request — when a transcript timestamp is tapped,
    /// this gets set with (storedName, time) so the matching player can seek.
    @Binding var seekRequest: (id: UUID, storedName: String, time: TimeInterval)?
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isDragging = false
    @State private var timer: Timer?
    @State private var videoThumbnail: NSImage?
    @State private var loadError: String?
    @Environment(\.fontScale) private var fontScale

    /// Update interval for the seek bar position (seconds).
    private static let progressUpdateInterval: TimeInterval = 0.1

    private func sp(_ base: CGFloat) -> CGFloat { base * CGFloat(fontScale) }

    var body: some View {
        let sf = ScaledFont(scale: fontScale)
        VStack(alignment: .leading, spacing: sp(4)) {
            // Video thumbnail (if video)
            if attachment.kind == .video, let thumbnail = videoThumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: sp(160))
                    .clipShape(RoundedRectangle(cornerRadius: sp(6)))
            }

            if let loadError {
                Text(loadError)
                    .font(sf.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: sp(6)) {
                if loadError == nil {
                    Button(action: togglePlayback) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(sf.title2)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                }

                // Seek slider
                Slider(value: Binding(
                    get: { duration > 0 ? currentTime / duration : 0 },
                    set: { newValue in
                        isDragging = true
                        currentTime = newValue * duration
                    }
                ), in: 0...1) { editing in
                    if !editing {
                        // Drag ended — seek to position
                        player?.currentTime = currentTime
                        isDragging = false
                        persistPosition()
                    }
                }
                .controlSize(.small)
                .frame(minWidth: sp(80))

                // Time display: current / duration
                Text("\(formatTime(currentTime)) / \(formatTime(duration))")
                    .font(sf.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .frame(minWidth: sp(80), alignment: .trailing)
            }

            Text(attachment.originalName)
                .font(sf.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, sp(8))
        .padding(.vertical, sp(6))
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: sp(6)))
        .onAppear { loadMetadata() }
        .onDisappear { cleanup() }
        .onChange(of: seekRequest?.id) { _, _ in
            guard let req = seekRequest, req.storedName == attachment.storedName else { return }
            if player == nil { loadMetadata() }
            player?.currentTime = req.time
            currentTime = req.time
            if !isPlaying {
                startPlayback()
            }
            seekRequest = nil
        }
    }

    private func loadMetadata() {
        let url = FileStorage.url(for: attachment.storedName)
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            duration = p.duration
            player = p
            // Restore persisted playback position
            let saved = attachment.playbackPosition
            if saved > 0 && saved < p.duration {
                p.currentTime = saved
                currentTime = saved
            }
        } catch {
            AppLogger.error("Failed to load audio: \(error)", category: "audio")
            loadError = "Failed to load audio"
        }

        // Generate video thumbnail
        if attachment.kind == .video {
            Task.detached(priority: .utility) {
                let thumb = await Self.generateThumbnail(url: url)
                await MainActor.run { videoThumbnail = thumb }
            }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        if player == nil { loadMetadata() }

        AudioPlaybackManager.shared.didStartPlaying(
            storedName: attachment.storedName,
            displayName: attachment.originalName,
            conversationID: attachment.message?.conversation?.id,
            duration: duration,
            player: player,
            onPause: { [self] in pausePlayback() },
            onSeek: { [self] time in
                player?.currentTime = time
                currentTime = time
                if !isPlaying {
                    player?.play()
                    isPlaying = true
                    startTimer()
                }
            },
            onGetCurrentTime: {
                (AudioPlaybackManager.shared.activePlayer as? AVAudioPlayer)?.currentTime ?? 0
            }
        )

        player?.play()
        isPlaying = true
        startTimer()
    }

    private func pausePlayback() {
        player?.pause()
        isPlaying = false
        stopTimer()
        persistPosition()
        AudioPlaybackManager.shared.didStopPlaying(storedName: attachment.storedName)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.progressUpdateInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let player, !isDragging else { return }
                currentTime = player.currentTime
                AudioPlaybackManager.shared.currentTime = currentTime
                if !player.isPlaying {
                    isPlaying = false
                    persistPosition()
                    stopTimer()
                    AudioPlaybackManager.shared.didFinishPlaying(storedName: attachment.storedName)
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func cleanup() {
        persistPosition()
        // Don't stop playback when scrolling out — the mini-player takes over.
        // Only stop the UI timer; the AVAudioPlayer continues in the background.
        // The AudioPlaybackManager keeps tracking the state.
        if !isPlaying {
            player?.stop()
            AudioPlaybackManager.shared.didStopPlaying(storedName: attachment.storedName)
        }
        stopTimer()
    }

    /// Saves current playback position to the SwiftData Attachment model.
    private func persistPosition() {
        let pos = player?.currentTime ?? currentTime
        if pos > 0 {
            attachment.playbackPosition = pos
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Generates a thumbnail from the first frame of a video file.
    private static func generateThumbnail(url: URL) async -> NSImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)

        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
    }
}

// MARK: - Video Player

struct VideoPlayerView: View {
    let attachment: Attachment
    var playbackStoredName: String?
    var initialAspectRatio: CGFloat = 16.0 / 9.0
    @Binding var seekRequest: (id: UUID, storedName: String, time: TimeInterval)?
    @State private var avPlayer: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isDragging = false
    @State private var timeObserver: Any?
    @State private var videoAspectRatio: CGFloat?
    @Environment(\.fontScale) private var fontScale

    private func sp(_ base: CGFloat) -> CGFloat { base * CGFloat(fontScale) }

    private var effectiveAspectRatio: CGFloat {
        videoAspectRatio ?? initialAspectRatio
    }

    /// Compute video display dimensions from aspect ratio.
    /// Portrait videos get more height since they're already narrow.
    private var videoSize: (width: CGFloat, height: CGFloat) {
        let maxW = sp(350)
        let ratio = effectiveAspectRatio
        let isPortrait = ratio < 1.0
        let maxH = isPortrait ? sp(450) : sp(300)
        let h = min(maxH, maxW / ratio)
        let w = h * ratio
        return (w, h)
    }

    var body: some View {
        let sf = ScaledFont(scale: fontScale)
        let vs = videoSize
        let outerWidth = vs.width + sp(4) * 2
        VStack(alignment: .leading, spacing: sp(4)) {
            // Video player — always reserve the frame for correct height measurement
            if let avPlayer {
                VideoPlayerNSView(player: avPlayer)
                    .frame(width: vs.width, height: vs.height)
                    .clipShape(RoundedRectangle(cornerRadius: sp(6)))
            } else {
                // Placeholder with same dimensions — ensures correct row height before player loads
                RoundedRectangle(cornerRadius: sp(6))
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                    .frame(width: vs.width, height: vs.height)
            }

            Text(attachment.originalName)
                .font(sf.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: vs.width, alignment: .leading)
        }
        .padding(sp(4))
        .frame(width: outerWidth, alignment: .leading)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: sp(6)))
        .onAppear { loadVideo() }
        .onDisappear { cleanup() }
        .onChange(of: seekRequest?.id) { _, _ in
            guard let req = seekRequest, req.storedName == attachment.storedName else { return }
            avPlayer?.seek(to: CMTime(seconds: req.time, preferredTimescale: 600))
            currentTime = req.time
            if !isPlaying { startPlayback() }
            seekRequest = nil
        }
    }

    private func loadVideo() {
        let url = FileStorage.url(for: playbackStoredName ?? attachment.storedName)

        // Use pre-computed aspect ratio from cache (populated on attach, non-blocking)
        let cachedRatio = ChatTableView.Coordinator.videoAspectRatio(url: url)
        if cachedRatio != 16.0 / 9.0 {
            videoAspectRatio = cachedRatio
        }

        let player = AVPlayer(url: url)
        self.avPlayer = player

        // Get duration and aspect ratio async (non-blocking)
        Task {
            // Compute aspect ratio on background if not cached
            if videoAspectRatio == nil {
                if let tracks = try? await player.currentItem?.asset.loadTracks(withMediaType: .video),
                   let track = tracks.first,
                   let size = try? await track.load(.naturalSize),
                   let transform = try? await track.load(.preferredTransform) {
                    let transformed = size.applying(transform)
                    let w = abs(transformed.width)
                    let h = abs(transformed.height)
                    if w > 0 && h > 0 {
                        let ratio = w / h
                        await MainActor.run {
                            videoAspectRatio = ratio
                            // Write back to static cache so the coordinator's
                            // videoLayoutKey detects the change and recalculates row height.
                            // Critical for WebM/MKV where precomputeVideoAspectRatio fails
                            // because AVAsset can't read those formats.
                            ChatTableView.Coordinator.setVideoAspectRatio(ratio, for: url)
                            NotificationCenter.default.post(name: .videoAspectRatioDidChange, object: nil)
                        }
                    }
                }
            }

            if let d = try? await player.currentItem?.asset.load(.duration) {
                let seconds = CMTimeGetSeconds(d)
                if seconds.isFinite {
                    await MainActor.run { duration = seconds }
                }
            }
        }

        // Restore saved position
        let saved = attachment.playbackPosition
        if saved > 0 {
            player.seek(to: CMTime(seconds: saved, preferredTimescale: 600))
            currentTime = saved
        }

        // Periodic time observer
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            MainActor.assumeIsolated {
                guard !isDragging else { return }
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite {
                    currentTime = seconds
                    AudioPlaybackManager.shared.currentTime = seconds
                }
                // Detect end of playback
                if let item = player.currentItem,
                   CMTimeGetSeconds(item.duration).isFinite,
                   seconds >= CMTimeGetSeconds(item.duration) - 0.1 {
                    isPlaying = false
                    AudioPlaybackManager.shared.didFinishPlaying(storedName: attachment.storedName)
                }
            }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        AudioPlaybackManager.shared.didStartPlaying(
            storedName: attachment.storedName,
            displayName: attachment.originalName,
            conversationID: attachment.message?.conversation?.id,
            duration: duration,
            player: avPlayer,
            onPause: {
                // Use manager's retained player — survives cell destruction
                let mgr = AudioPlaybackManager.shared
                (mgr.activePlayer as? AVPlayer)?.pause()
                if let id = mgr.currentlyPlayingID { mgr.didStopPlaying(storedName: id) }
            },
            onSeek: { time in
                guard let p = AudioPlaybackManager.shared.activePlayer as? AVPlayer else { return }
                p.seek(to: CMTime(seconds: time, preferredTimescale: 600))
                p.play()
            },
            onGetCurrentTime: {
                guard let p = AudioPlaybackManager.shared.activePlayer as? AVPlayer else { return 0 }
                let t = CMTimeGetSeconds(p.currentTime())
                return t.isFinite ? t : 0
            }
        )
        avPlayer?.play()
        isPlaying = true
    }

    private func pausePlayback() {
        avPlayer?.pause()
        isPlaying = false
        persistPosition()
        AudioPlaybackManager.shared.didStopPlaying(storedName: attachment.storedName)
    }

    private func cleanup() {
        persistPosition()
        // Don't stop playback when scrolling out — the mini-player takes over.
        if !isPlaying {
            avPlayer?.pause()
            AudioPlaybackManager.shared.didStopPlaying(storedName: attachment.storedName)
        }
        if let observer = timeObserver {
            avPlayer?.removeTimeObserver(observer)
        }
        timeObserver = nil
    }

    private func persistPosition() {
        attachment.playbackPosition = currentTime
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// NSViewRepresentable wrapping AVPlayerView for native macOS video rendering.
struct VideoPlayerNSView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

// MARK: - Unsupported Video (WebM, MKV, etc.)

struct UnsupportedVideoView: View {
    let attachment: Attachment
    var isConverting: Bool = false
    @Environment(\.fontScale) private var fontScale

    private func sp(_ base: CGFloat) -> CGFloat { base * CGFloat(fontScale) }

    var body: some View {
        let sf = ScaledFont(scale: fontScale)
        VStack(spacing: sp(6)) {
            Image(systemName: "film")
                .font(.system(size: 28 * CGFloat(fontScale)))
                .foregroundStyle(.secondary)
            Text(attachment.originalName)
                .font(sf.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if isConverting {
                HStack(spacing: sp(4)) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Converting to MP4 for playback...")
                        .font(sf.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Playback not supported for this format.")
                    .font(sf.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(sp(12))
        .frame(maxWidth: sp(300))
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: sp(6)))
    }
}

// MARK: - Mini Player Bar

/// Compact player bar shown when the playing audio/video is scrolled out of view.
struct MiniPlayerBar: View {
    @Environment(\.fontScale) private var fontScale
    private var manager: AudioPlaybackManager { .shared }

    private func sp(_ base: CGFloat) -> CGFloat { base * CGFloat(fontScale) }

    var body: some View {
        let sf = ScaledFont(scale: fontScale)
        HStack(spacing: sp(8)) {
            Button(action: { manager.togglePlayPause() }) {
                Image(systemName: manager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(sf.title3)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)

            if let name = manager.currentlyPlayingName {
                Text(name)
                    .font(sf.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }

            Slider(value: Binding(
                get: { manager.duration > 0 ? manager.currentTime / manager.duration : 0 },
                set: { manager.seek(to: $0 * manager.duration) }
            ), in: 0...1)
            .controlSize(.small)

            Text(formatTime(manager.currentTime))
                .font(sf.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: sp(40), alignment: .trailing)
        }
        .padding(.horizontal, sp(12))
        .padding(.vertical, sp(4))
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
