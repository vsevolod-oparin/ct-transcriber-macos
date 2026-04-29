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
    /// AVPlayer used for OGG files where AVAudioPlayer's seek is broken.
    @State private var avPlayer: AVPlayer?
    @State private var avTimeObserver: Any?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isDragging = false
    @State private var videoThumbnail: NSImage?
    @State private var loadError: String?
    @Environment(\.fontScale) private var fontScale

    private var isOGG: Bool {
        FileStorage.url(for: attachment.storedName).pathExtension.lowercased() == "ogg"
    }

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
                        seekPlayer(to: currentTime)
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
        .onAppear {
            loadMetadata()
            handleSeekIfPending()
        }
        .onDisappear { cleanup() }
        .onReceive(Timer.publish(every: Self.progressUpdateInterval, on: .main, in: .common).autoconnect()) { _ in
            guard isPlaying, !isDragging else { return }
            updatePlaybackTime()
        }
        .onChange(of: seekRequest?.id) { _, _ in
            handleSeekIfPending()
        }
    }

    private func handleSeekIfPending() {
        guard let req = seekRequest, req.storedName == attachment.storedName else { return }
        if player == nil && avPlayer == nil { loadMetadata() }
        seekPlayer(to: req.time)
        currentTime = req.time
        if !isPlaying { startPlayback() }
        seekRequest = nil
    }

    private func loadMetadata() {
        let manager = AudioPlaybackManager.shared
        let url = FileStorage.url(for: attachment.storedName)

        if isOGG {
            if manager.currentlyPlayingID == attachment.storedName,
               let existing = manager.activePlayer as? AVPlayer {
                avPlayer = existing
                isPlaying = manager.isPlaying
                let t = CMTimeGetSeconds(existing.currentTime())
                if t.isFinite { currentTime = t }
                if let item = existing.currentItem, CMTimeGetSeconds(item.duration).isFinite {
                    duration = CMTimeGetSeconds(item.duration)
                }
                reregisterCallbacks()
                return
            }
            let ap = AVPlayer(url: url)
            avPlayer = ap
            Task {
                if let d = try? await ap.currentItem?.asset.load(.duration) {
                    let seconds = CMTimeGetSeconds(d)
                    if seconds.isFinite {
                        await MainActor.run { duration = seconds }
                    }
                }
                // Fallback: get duration from AVAudioPlayer if AVPlayer reports NaN
                if duration == 0 {
                    if let probe = try? AVAudioPlayer(contentsOf: url) {
                        await MainActor.run { duration = probe.duration }
                    }
                }
                let saved = manager.lastPositions[attachment.storedName] ?? attachment.playbackPosition
                if saved > 0 && (duration == 0 || saved < duration) {
                    let target = CMTime(seconds: saved, preferredTimescale: 600)
                    await ap.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                    await MainActor.run { currentTime = saved }
                }
            }
            return
        }

        if manager.currentlyPlayingID == attachment.storedName,
           let existing = manager.activePlayer as? AVAudioPlayer {
            player = existing
            duration = existing.duration
            currentTime = existing.currentTime
            isPlaying = existing.isPlaying
            reregisterCallbacks()
            return
        }

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            duration = p.duration
            player = p
            let saved = manager.lastPositions[attachment.storedName] ?? attachment.playbackPosition
            if saved > 0 && saved < p.duration {
                p.currentTime = saved
                currentTime = saved
            }
        } catch {
            AppLogger.error("Failed to load audio: \(error)", category: "audio")
            loadError = "Failed to load audio"
        }

        // Load video thumbnail from cache or generate
        if attachment.kind == .video {
            if let cached = ChatTableView.Coordinator.videoThumbnail(for: attachment.storedName) {
                videoThumbnail = cached
            } else {
                Task.detached(priority: .utility) {
                    let storedName = attachment.storedName
                    if let thumb = await Self.generateThumbnail(url: url) {
                        ChatTableView.Coordinator.setVideoThumbnail(thumb, for: storedName)
                        await MainActor.run { videoThumbnail = thumb }
                    }
                }
            }
        }
    }

    private func seekPlayer(to time: TimeInterval) {
        if let avPlayer {
            let target = CMTime(seconds: time, preferredTimescale: 600)
            avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        guard let player else { return }
        let wasPlaying = player.isPlaying
        player.stop()

        let url = FileStorage.url(for: attachment.storedName)
        guard let fresh = try? AVAudioPlayer(contentsOf: url) else {
            player.currentTime = time
            if wasPlaying { player.play() }
            return
        }
        fresh.currentTime = time
        fresh.prepareToPlay()
        self.player = fresh
        duration = fresh.duration
        if wasPlaying { fresh.play() }
        if AudioPlaybackManager.shared.currentlyPlayingID == attachment.storedName {
            AudioPlaybackManager.shared.activePlayer = fresh
        }
    }

    private func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }

    private func reregisterCallbacks() {
        let manager = AudioPlaybackManager.shared
        guard manager.currentlyPlayingID == attachment.storedName else { return }

        if let avPlayer {
            manager.didStartPlaying(
                storedName: attachment.storedName,
                displayName: attachment.originalName,
                conversationID: attachment.message?.conversation?.id,
                duration: duration,
                player: avPlayer,
                onPause: { [self] in pausePlayback() },
                onResume: { [self] in
                    self.avPlayer?.play()
                    isPlaying = true
                },
                onSeek: { [self] time in
                    seekPlayer(to: time)
                    currentTime = time
                    if !isPlaying {
                        self.avPlayer?.play()
                        isPlaying = true
                    }
                },
                onGetCurrentTime: {
                    guard let p = AudioPlaybackManager.shared.activePlayer as? AVPlayer else { return 0 }
                    let t = CMTimeGetSeconds(p.currentTime())
                    return t.isFinite ? t : 0
                }
            )
            return
        }

        manager.didStartPlaying(
            storedName: attachment.storedName,
            displayName: attachment.originalName,
            conversationID: attachment.message?.conversation?.id,
            duration: duration,
            player: player,
            onPause: { [self] in pausePlayback() },
            onResume: { [self] in
                player?.play()
                isPlaying = true
            },
            onSeek: { [self] time in
                seekPlayer(to: time)
                currentTime = time
                if !isPlaying {
                    player?.play()
                    isPlaying = true
                }
            },
            onGetCurrentTime: {
                (AudioPlaybackManager.shared.activePlayer as? AVAudioPlayer)?.currentTime ?? 0
            }
        )
    }

    private func startPlayback() {
        if player == nil && avPlayer == nil { loadMetadata() }

        if let avPlayer {
            AudioPlaybackManager.shared.didStartPlaying(
                storedName: attachment.storedName,
                displayName: attachment.originalName,
                conversationID: attachment.message?.conversation?.id,
                duration: duration,
                player: avPlayer,
                onPause: { [self] in pausePlayback() },
                onResume: { [self] in
                    self.avPlayer?.play()
                    isPlaying = true
                },
                onSeek: { [self] time in
                    seekPlayer(to: time)
                    currentTime = time
                    if !isPlaying {
                        self.avPlayer?.play()
                        isPlaying = true
                    }
                },
                onGetCurrentTime: {
                    guard let p = AudioPlaybackManager.shared.activePlayer as? AVPlayer else { return 0 }
                    let t = CMTimeGetSeconds(p.currentTime())
                    return t.isFinite ? t : 0
                }
            )
            avPlayer.play()
            isPlaying = true
            return
        }

        AudioPlaybackManager.shared.didStartPlaying(
            storedName: attachment.storedName,
            displayName: attachment.originalName,
            conversationID: attachment.message?.conversation?.id,
            duration: duration,
            player: player,
            onPause: { [self] in pausePlayback() },
            onResume: { [self] in
                player?.play()
                isPlaying = true
            },
            onSeek: { [self] time in
                seekPlayer(to: time)
                currentTime = time
                if !isPlaying {
                    player?.play()
                    isPlaying = true
                }
            },
            onGetCurrentTime: {
                (AudioPlaybackManager.shared.activePlayer as? AVAudioPlayer)?.currentTime ?? 0
            }
        )

        player?.play()
        isPlaying = true
    }

    private func pausePlayback() {
        if avPlayer != nil {
            avPlayer?.pause()
        } else {
            player?.pause()
        }
        isPlaying = false
        persistPosition()
        AudioPlaybackManager.shared.didStopPlaying(storedName: attachment.storedName)
    }

    private func cleanup() {
        persistPosition()
        if !isPlaying {
            if avPlayer != nil {
                avPlayer?.pause()
            } else {
                player?.stop()
            }
            AudioPlaybackManager.shared.didStopPlaying(storedName: attachment.storedName)
        }
    }

    private func persistPosition() {
        var pos = currentTime
        if let avPlayer {
            let t = CMTimeGetSeconds(avPlayer.currentTime())
            if t.isFinite { pos = t }
        } else if let player {
            pos = player.currentTime
        }
        if pos > 0 {
            attachment.playbackPosition = pos
            AudioPlaybackManager.shared.lastPositions[attachment.storedName] = pos
        }
    }

    private func updatePlaybackTime() {
        if let avPlayer {
            let t = CMTimeGetSeconds(avPlayer.currentTime())
            if t.isFinite { currentTime = t }
            AudioPlaybackManager.shared.currentTime = currentTime
            if avPlayer.rate == 0 && isPlaying {
                if let item = avPlayer.currentItem,
                   CMTimeGetSeconds(item.duration).isFinite,
                   t >= CMTimeGetSeconds(item.duration) - 0.1 {
                    isPlaying = false
                    persistPosition()
                    AudioPlaybackManager.shared.didFinishPlaying(storedName: attachment.storedName)
                }
            }
        } else if let player {
            currentTime = player.currentTime
            AudioPlaybackManager.shared.currentTime = currentTime
            if !player.isPlaying {
                isPlaying = false
                persistPosition()
                AudioPlaybackManager.shared.didFinishPlaying(storedName: attachment.storedName)
            }
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

    private static let defaultAspectRatio: CGFloat = 16.0 / 9.0

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
        .onAppear {
            loadVideo()
            handleSeekIfPending()
        }
        .onDisappear { cleanup() }
        .onChange(of: seekRequest?.id) { _, _ in
            handleSeekIfPending()
        }
    }

    private func loadVideo() {
        let url = FileStorage.url(for: playbackStoredName ?? attachment.storedName)

        // Use pre-computed aspect ratio from cache (populated on attach, non-blocking)
        let cachedRatio = ChatTableView.Coordinator.videoAspectRatio(url: url)
        if let cached = cachedRatio {
            videoAspectRatio = cached
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

                // Detect playback started by native AVPlayerView controls
                // (bypasses our startPlayback method)
                if player.rate > 0 && !isPlaying {
                    startPlayback()
                } else if player.rate == 0 && isPlaying {
                    pausePlayback()
                }

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

    private func handleSeekIfPending() {
        guard let req = seekRequest, req.storedName == attachment.storedName else { return }
        let target = CMTime(seconds: req.time, preferredTimescale: 600)
        avPlayer?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = req.time
        if !isPlaying { startPlayback() }
        seekRequest = nil
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
                let mgr = AudioPlaybackManager.shared
                (mgr.activePlayer as? AVPlayer)?.pause()
                if let id = mgr.currentlyPlayingID { mgr.didStopPlaying(storedName: id) }
            },
            onResume: {
                guard let p = AudioPlaybackManager.shared.activePlayer as? AVPlayer else { return }
                p.play()
            },
            onSeek: { time in
                guard let p = AudioPlaybackManager.shared.activePlayer as? AVPlayer else { return }
                let target = CMTime(seconds: time, preferredTimescale: 600)
                p.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
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
