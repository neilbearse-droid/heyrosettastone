import AVFoundation
import Foundation

/// The board's voice. Speech happens only when the child triggers it by
/// tapping a button — the device never speaks unprompted (§7). The voice is
/// his choice (§12), persisted by identifier.
final class SpeechOutput: NSObject {
    static let voiceDefaultsKey = "boardVoiceIdentifier"

    private let synthesizer = AVSpeechSynthesizer()

    var voiceIdentifier: String? {
        get { UserDefaults.standard.string(forKey: Self.voiceDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.voiceDefaultsKey) }
    }

    /// Speaks immediately, cancelling any in-flight utterance so a fast
    /// second tap feels instant rather than queued.
    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        if let id = voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
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
}
