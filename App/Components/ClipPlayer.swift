import AVFoundation
import Foundation
import Observation

/// Plays segment clips for chips and Review. Playback is always a parent
/// action — nothing in the app plays audio unprompted (§7).
///
/// Every play is reported to `SpeechOutput.shared` as self-produced sound
/// so capture feeds silence for the clip's length: through the counter
/// phone's speaker the clip is his own voice coming back at the
/// microphone, and ungated it would be cut as a new utterance (and open a
/// new session that clears the Confirm card the parent is labelling).
@Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playingClipRef: String?
    private var player: AVAudioPlayer?

    func toggle(clipRef: String) {
        if playingClipRef == clipRef {
            stop()
            return
        }
        stop()
        // A tombstoned ref (clip deleted) or a missing file simply does
        // nothing; callers disable the control for those, this is the
        // backstop.
        guard let url = FileLocations.existingClipURL(id: clipRef) else { return }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        self.player = player
        playingClipRef = clipRef
        // Gate capture before the first sample leaves the speaker.
        SpeechOutput.shared.beginSelfPlayback(duration: player.duration)
        player.play()
    }

    func stop() {
        let wasPlaying = playingClipRef != nil
        player?.stop()
        player = nil
        playingClipRef = nil
        if wasPlaying {
            SpeechOutput.shared.endSelfPlayback()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playingClipRef = nil
            self.player = nil
            SpeechOutput.shared.endSelfPlayback()
        }
    }
}
