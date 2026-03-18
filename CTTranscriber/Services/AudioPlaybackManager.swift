import Foundation
import AVFoundation

/// Manages the globally active audio/video playback.
/// Ensures only one plays at a time and provides state for the floating mini-player.
@Observable
final class AudioPlaybackManager {
    static let shared = AudioPlaybackManager()

    /// The storedName of the currently playing attachment, or nil.
    private(set) var currentlyPlayingID: String?
    /// Display name (original filename) of the currently playing media.
    private(set) var currentlyPlayingName: String?
    /// Conversation ID the playback belongs to.
    private(set) var conversationID: UUID?
    /// Whether playback is active (not just paused).
    private(set) var isPlaying: Bool = false
    /// Current playback position (seconds).
    var currentTime: TimeInterval = 0
    /// Total duration (seconds).
    var duration: TimeInterval = 0

    /// Callback for the currently playing view to pause itself.
    private var pauseCallback: (() -> Void)?
    /// Callback to seek the currently playing media.
    private var seekCallback: ((TimeInterval) -> Void)?
    /// Callback to get current time from the player (for mini-player updates).
    private var getCurrentTimeCallback: (() -> TimeInterval)?
    /// Strong reference to the active player to keep it alive when the cell scrolls out.
    var activePlayer: AnyObject?
    /// Timer for updating currentTime when the cell's own timer is stopped (scrolled out).
    private var miniPlayerTimer: Timer?

    private init() {}

    /// Called when an audio starts playing. Pauses any other playing audio first.
    func didStartPlaying(
        storedName: String,
        displayName: String = "",
        conversationID: UUID? = nil,
        duration: TimeInterval = 0,
        player: AnyObject? = nil,
        onPause: @escaping () -> Void,
        onSeek: @escaping (TimeInterval) -> Void = { _ in },
        onGetCurrentTime: @escaping () -> TimeInterval = { 0 }
    ) {
        if currentlyPlayingID != nil && currentlyPlayingID != storedName {
            pauseCallback?()
            stopMiniPlayerTimer()
        }
        currentlyPlayingID = storedName
        currentlyPlayingName = displayName
        self.conversationID = conversationID
        self.duration = duration
        self.isPlaying = true
        self.activePlayer = player
        pauseCallback = onPause
        seekCallback = onSeek
        getCurrentTimeCallback = onGetCurrentTime
        startMiniPlayerTimer()
    }

    /// Called when an audio is paused or stopped.
    func didStopPlaying(storedName: String) {
        if currentlyPlayingID == storedName {
            isPlaying = false
            stopMiniPlayerTimer()
        }
    }

    /// Called when playback finishes completely.
    func didFinishPlaying(storedName: String) {
        if currentlyPlayingID == storedName {
            stopMiniPlayerTimer()
            currentlyPlayingID = nil
            currentlyPlayingName = nil
            conversationID = nil
            isPlaying = false
            currentTime = 0
            duration = 0
            pauseCallback = nil
            seekCallback = nil
            getCurrentTimeCallback = nil
            activePlayer = nil
        }
    }

    /// Stops all playback and clears state (e.g., on conversation switch).
    func stopAll() {
        pauseCallback?()
        stopMiniPlayerTimer()
        currentlyPlayingID = nil
        currentlyPlayingName = nil
        conversationID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        pauseCallback = nil
        seekCallback = nil
        getCurrentTimeCallback = nil
        activePlayer = nil
    }

    // MARK: - Mini-player timer

    private func startMiniPlayerTimer() {
        stopMiniPlayerTimer()
        miniPlayerTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying, let getTime = self.getCurrentTimeCallback else { return }
            self.currentTime = getTime()
        }
    }

    private func stopMiniPlayerTimer() {
        miniPlayerTimer?.invalidate()
        miniPlayerTimer = nil
    }

    /// Toggle play/pause from the mini-player.
    func togglePlayPause() {
        pauseCallback?()
    }

    /// Seek from the mini-player.
    func seek(to time: TimeInterval) {
        seekCallback?(time)
        currentTime = time
    }
}
