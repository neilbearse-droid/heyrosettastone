import CoreML
import Foundation
import WhisperKit

/// The §5.1 embedding: WhisperKit's audio encoder (tiny checkpoint),
/// mean-pooled over the frames that carry real audio, L2-normalized.
/// Transcription is never invoked — only the encoder runs (§1: the app
/// never attempts transcription).
///
/// The model MUST be bundled with the app (docs/whisperkit-model-bundling.md).
/// `download: false` is hard-coded: Rosetta makes no network calls, so a
/// missing bundle means no suggestions — the app stays fully functional as
/// Phase 1 and the model "earns its way in" (§2.1).
///
/// NOTE: written against WhisperKit 0.9.x (pinned in project.yml). The
/// featureExtractor/audioEncoder surface occasionally shifts between
/// releases; if a WhisperKit upgrade breaks this file, this is the only
/// file to touch — everything else sees `EmbeddingProvider`.
final class WhisperKitEmbedder: EmbeddingProvider {
    enum EmbedError: Error {
        case modelUnavailable
        case unexpectedEncoderOutput
    }

    /// Whisper's fixed input window: 30 s at 16 kHz.
    private static let windowSamples = 480_000
    /// Mel hop 160 samples (10 ms) and the encoder halves time: 50 frames/s.
    private static let framesPerSecond = 50.0

    private let whisperKit: WhisperKit
    private(set) var dimension: Int

    static let modelName = "openai_whisper-tiny"

    /// The bundled Core ML model folder, or nil if the app was built
    /// without one.
    static func bundledModelFolder() -> URL? {
        Bundle.main.url(forResource: modelName, withExtension: nil)
            ?? Bundle.main.url(forResource: modelName, withExtension: nil, subdirectory: "WhisperKitModels")
    }

    /// Returns nil when no model is bundled or loading fails — callers
    /// treat nil as "Phase 1 behaviour".
    static func loadIfAvailable() async -> WhisperKitEmbedder? {
        guard let folder = bundledModelFolder() else { return nil }
        do {
            let config = WhisperKitConfig(
                model: modelName,
                modelFolder: folder.path,
                load: true,
                download: false
            )
            let kit = try await WhisperKit(config)
            return WhisperKitEmbedder(whisperKit: kit)
        } catch {
            return nil
        }
    }

    private init(whisperKit: WhisperKit) {
        self.whisperKit = whisperKit
        self.dimension = 384 // whisper-tiny encoder width; corrected on first embed
    }

    func embed(samples: [Float]) async throws -> [Float] {
        // Pad or trim to the fixed window.
        var window = samples
        if window.count > Self.windowSamples {
            window = Array(window.prefix(Self.windowSamples))
        } else if window.count < Self.windowSamples {
            window.append(contentsOf: [Float](repeating: 0, count: Self.windowSamples - window.count))
        }

        let audioArray = try MLMultiArray(shape: [NSNumber(value: Self.windowSamples)], dataType: .float32)
        window.withUnsafeBufferPointer { source in
            audioArray.dataPointer
                .assumingMemoryBound(to: Float.self)
                .update(from: source.baseAddress!, count: Self.windowSamples)
        }

        // WhisperKit's protocols return `any FeatureExtractorOutputType` /
        // `any AudioEncoderOutputType` to allow non-CoreML backends; the
        // default backend's concrete type is MLMultiArray.
        guard let mel = try await whisperKit.featureExtractor.logMelSpectrogram(fromAudio: audioArray),
              let encodedOutput = try await whisperKit.audioEncoder.encodeFeatures(mel),
              let encoded = encodedOutput as? MLMultiArray
        else { throw EmbedError.unexpectedEncoderOutput }

        // Pool only over frames covering the real utterance, not the padded
        // silence, so short clips aren't diluted toward the padding.
        let utteranceSeconds = Double(min(samples.count, Self.windowSamples)) / 16_000.0
        let usefulFrames = max(1, Int((utteranceSeconds * Self.framesPerSecond).rounded(.up)))
        let vector = try Self.meanPool(encoderOutput: encoded, maxFrames: usefulFrames)
        dimension = vector.count
        return VectorMath.l2Normalized(vector)
    }

    /// Encoder output is (1, dim, 1, frames). Mean over the frame axis,
    /// limited to `maxFrames`.
    static func meanPool(encoderOutput: MLMultiArray, maxFrames: Int) throws -> [Float] {
        let shape = encoderOutput.shape.map(\.intValue)
        guard shape.count == 4, shape[0] == 1, shape[2] == 1 else {
            throw EmbedError.unexpectedEncoderOutput
        }
        let dim = shape[1]
        let frames = min(shape[3], maxFrames)
        let dimStride = encoderOutput.strides[1].intValue
        let frameStride = encoderOutput.strides[3].intValue

        var pooled = [Float](repeating: 0, count: dim)
        switch encoderOutput.dataType {
        case .float32:
            let pointer = encoderOutput.dataPointer.assumingMemoryBound(to: Float.self)
            for d in 0..<dim {
                var sum: Float = 0
                for f in 0..<frames {
                    sum += pointer[d * dimStride + f * frameStride]
                }
                pooled[d] = sum / Float(frames)
            }
        case .float16:
            let pointer = encoderOutput.dataPointer.assumingMemoryBound(to: Float16.self)
            for d in 0..<dim {
                var sum: Float = 0
                for f in 0..<frames {
                    sum += Float(pointer[d * dimStride + f * frameStride])
                }
                pooled[d] = sum / Float(frames)
            }
        default:
            throw EmbedError.unexpectedEncoderOutput
        }
        return pooled
    }
}
