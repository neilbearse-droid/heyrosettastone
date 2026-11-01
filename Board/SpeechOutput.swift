import AVFoundation
import Foundation
import Observation
import os

/// The board's voice. Speech happens only when the child triggers it by
/// tapping a button — the device never speaks unprompted (§7). The voice is
/// his choice (§12), persisted by identifier.
///
/// One long-lived instance (`shared`) serves the board: a synthesizer that
/// is torn down with a view cuts the word off, and a fresh one pays the
/// voice-load latency on every first tap. It is also the capture path's
/// authority on when the phone itself is talking, so the board's speech is
/// not recorded as the child's (`selfSpeakingUntil`).
@Observable
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechOutput()

    static let voiceDefaultsKey = "boardVoiceIdentifier"

    /// Silence kept after an utterance ends before capture trusts the
    /// microphone again: speaker tail, room reverb, synthesizer trailing
    /// buffers.
    static let selfSpeechTail: TimeInterval = 0.3

    /// True from `speak` until the synthesizer reports finish or cancel.
    private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()

    /// Thread-safe: read on the capture queue, written on the main thread.
    /// (A `let`, so the Observable macro leaves it alone.)
    private let selfSpeakingUntilLock = OSAllocatedUnfairLock(initialState: Date.distantPast)
    /// Same, for stored-clip playback (ClipPlayer). Kept apart from the
    /// synthesizer's gate so a word spoken while a clip plays, or a clip
    /// stopped while a word is mid-utterance, cannot release the other.
    private let playbackUntilLock = OSAllocatedUnfairLock(initialState: Date.distantPast)

    /// Until this instant the phone is (or may still be) producing sound of
    /// its own: the board's voice, or a stored clip being played back.
    /// Capture feeds silence into the session buffer while
    /// `Date() < selfSpeakingUntil` so neither becomes a segment. The
    /// speech gate is set pessimistically at `speak` (the synthesizer may
    /// take a few hundred ms to actually start), then tightened to
    /// end-of-utterance + `selfSpeechTail` by the delegate; the playback
    /// gate is set from the clip's duration by `beginSelfPlayback`.
    var selfSpeakingUntil: Date {
        let speech = selfSpeakingUntilLock.withLock { $0 }
        let playback = playbackUntilLock.withLock { $0 }
        return max(speech, playback)
    }

    /// The phone is about to play a stored clip for `duration` seconds — a
    /// chip on the Confirm card, a row in Review, an exemplar in Dictionary.
    /// Through the counter phone's speaker that is his own voice coming
    /// back at the microphone: ungated it would be cut as a new utterance,
    /// and if the exchange had already closed (the normal yes-moment
    /// timing) it would open a new session and wipe the very card the
    /// parent is labelling. Same gate as the board's voice. Also makes sure
    /// the audio session can play when capture is off (the silent switch
    /// would otherwise mute Review playback).
    func beginSelfPlayback(duration: TimeInterval) {
        ensurePlaybackCapableSession()
        let until = Date().addingTimeInterval(max(0, duration) + Self.selfSpeechTail)
        playbackUntilLock.withLock { $0 = max($0, until) }
    }

    /// Playback finished or was stopped early: release the playback gate
    /// after the tail. The synthesizer's own gate is untouched.
    func endSelfPlayback() {
        playbackUntilLock.withLock { $0 = Date().addingTimeInterval(Self.selfSpeechTail) }
    }

    /// The utterance we most recently asked for. `stopSpeaking(at:)` on a
    /// fast second tap delivers `didCancel` for the *previous* utterance after
    /// `speak` has already set the new pessimistic gate; ignoring callbacks
    /// for any other utterance keeps the gate honest.
    @ObservationIgnored
    private var currentUtterance: AVSpeechUtterance?

    @ObservationIgnored
    private var preparedVoice: AVSpeechSynthesisVoice?
    @ObservationIgnored
    private var preparedVoiceIdentifier: String?

    var voiceIdentifier: String? {
        get { UserDefaults.standard.string(forKey: Self.voiceDefaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.voiceDefaultsKey)
            preparedVoice = nil
            preparedVoiceIdentifier = nil
        }
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Resolves the chosen voice ahead of the first tap so the first word
    /// is not late. Call from the board's onAppear.
    func prewarm() {
        _ = resolvedVoice()
    }

    /// Speaks immediately, cancelling any in-flight utterance so a fast
    /// second tap feels instant rather than queued.
    func speak(_ text: String) {
        ensurePlaybackCapableSession()

        // Gate capture from this instant: the synthesizer's didStart may
        // lag by hundreds of ms on a cold voice.
        let estimated = min(10, max(2, 1.5 + 0.12 * Double(text.count)))
        setSelfSpeakingUntil(Date().addingTimeInterval(estimated))
        isSpeaking = true

        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        if let voice = resolvedVoice() {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    /// Voices offered in settings for him to choose from, current language
    /// first. The choice is made by him if he shows a preference (§12).
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        return AVSpeechSynthesisVoice.speechVoices()
            .sorted { a, b in
                if (a.language == language) != (b.language == language) {
                    return a.language == language
                }
                return a.name < b.name
            }
    }

    // MARK: - AVSpeechSynthesizerDelegate (delivered on the main thread)

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        isSpeaking = true
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        finished()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        finished()
    }

    // MARK: - Internals

    private func finished() {
        setSelfSpeakingUntil(Date().addingTimeInterval(Self.selfSpeechTail))
        isSpeaking = false
        currentUtterance = nil
    }

    private func setSelfSpeakingUntil(_ date: Date) {
        selfSpeakingUntilLock.withLock { $0 = date }
    }

    private func resolvedVoice() -> AVSpeechSynthesisVoice? {
        let id = voiceIdentifier
        if preparedVoiceIdentifier == id, let preparedVoice {
            return preparedVoice
        }
        let voice: AVSpeechSynthesisVoice?
        if let id, let chosen = AVSpeechSynthesisVoice(identifier: id) {
            voice = chosen
        } else {
            voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        }
        preparedVoice = voice
        preparedVoiceIdentifier = id
        return voice
    }

    /// When capture is running the session is `.playAndRecord`, which
    /// already ignores the ring/silent switch, and must be left alone.
    /// Otherwise the app is in the default `.soloAmbient`, which obeys the
    /// switch: a muted counter phone would have a silent board. Move to a
    /// playback category that mixes with other audio (no unexpected
    /// interruption of anything else, §7).
    private func ensurePlaybackCapableSession() {
        let session = AVAudioSession.sharedInstance()
        switch session.category {
        case .playAndRecord, .playback:
            return
        default:
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
        }
    }
}
