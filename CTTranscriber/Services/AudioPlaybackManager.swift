import Foundation
import AVFoundation

/// Ensures only one audio plays at a time across the entire app.
/// When a new audio starts, the previous one is paused automatically.
@Observable
final class AudioPlaybackManager {
    static let shared = AudioPlaybackManager()

    /// The storedName of the currently playing attachment, or nil.
    private(set) var currentlyPlayingID: String?

    /// Callback for the currently playing view to pause itself.
    private var pauseCallback: (() -> Void)?

    private init() {}

    /// Called when an audio starts playing. Pauses any other playing audio first.
    func didStartPlaying(storedName: String, onPause: @escaping () -> Void) {
        if currentlyPlayingID != nil && currentlyPlayingID != storedName {
            // Pause the previous audio
            pauseCallback?()
        }
        currentlyPlayingID = storedName
        pauseCallback = onPause
    }

    /// Called when an audio is paused or stopped.
    func didStopPlaying(storedName: String) {
        if currentlyPlayingID == storedName {
            currentlyPlayingID = nil
            pauseCallback = nil
        }
    }
}
