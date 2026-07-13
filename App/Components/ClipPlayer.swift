import AVFoundation
import Foundation
import Observation

/// Plays segment clips for chips and Review. Playback is always a parent
/// action — nothing in the app plays audio unprompted (§7).
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
        let url = FileLocations.clipURL(id: clipRef)
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        self.player = player
        playingClipRef = clipRef
        player.play()
    }

    func stop() {
        player?.stop()
        player = nil
        playingClipRef = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playingClipRef = nil
            self.player = nil
        }
    }
}
