import CoreML
import Foundation

// MARK: - Runner abstraction

/// One forward pass of the Silero VAD network. Abstracted so `SileroVAD`'s
/// rebuffering, state threading and hysteresis are testable without Core
/// ML (tests script probabilities through a fake runner).
///
/// - `audio`: exactly `SileroVAD.windowSamples` (512) samples of 16 kHz
///   mono, i.e. one 32 ms window.
/// - `state`: the recurrent (h, c) state from the previous call, as a flat
///   row-major array of shape (2, 1, 128) = 256 floats — element
///   `[layer, 0, i]` lives at index `layer * 128 + i`. All zeros for the
///   first window of a stream and after `reset()`.
/// - returns the speech probability (0...1) for this window and the new
///   state to pass to the next call, in the same layout.
protocol SileroModelRunner {
    mutating func predict(audio: [Float], state: [Float]) throws -> (probability: Float, state: [Float])
}

// MARK: - Core ML runner

/// Runs the bundled Core ML conversion of Silero VAD
/// (docs/silero-vad-conversion.md). The app ships without the model unless
/// a developer adds `CoreMLModels/SileroVAD.mlpackage` to the project;
/// nothing is ever downloaded. `loadIfAvailable()` is the only entry point
/// the capture path uses and it never throws.
///
/// Model interface the runner expects (what the conversion doc produces):
///   inputs  "audio"  float32, 512 elements (shape (1, 512) or (512,))
///           "state"  float32, 256 elements (shape (2, 1, 128))
///           "sr"     optional; int32 or float32, 1 element; filled with 16000
///   outputs one array with 1 element   → speech probability
///           one array with 256 elements → new state
/// Outputs are picked by element count, not by name, because the ONNX
/// export calls them "output" and "stateN" and coremltools is free to
/// rename them; a model exported under other names still works.
///
/// Threading: `predict` reuses the input arrays, so one caller at a time —
/// the capture queue. Copies of this struct share those arrays (they are
/// class references), which is fine because only one `SileroVAD` is ever
/// live: `CaptureController` carries the detector from buffer to buffer.
struct CoreMLSileroRunner: SileroModelRunner {
    enum RunnerError: Error, CustomStringConvertible {
        case modelNotBundled
        case unexpectedInterface(String)
        case unexpectedOutput(String)
        case badInput(String)

        var description: String {
            switch self {
            case .modelNotBundled: return "SileroVAD.mlmodelc is not in the app bundle"
            case .unexpectedInterface(let detail): return "Silero model interface: \(detail)"
            case .unexpectedOutput(let detail): return "Silero model output: \(detail)"
            case .badInput(let detail): return "Silero runner input: \(detail)"
            }
        }
    }

    /// Resource name of the compiled model in the bundle. Xcode compiles
    /// `SileroVAD.mlpackage` into `SileroVAD.mlmodelc` at build time.
    static let modelName = "SileroVAD"
    static let audioInputName = "audio"
    static let stateInputName = "state"
    static let sampleRateInputName = "sr"
    static let sampleRate = 16_000

    private let model: MLModel
    private let audioArray: MLMultiArray
    private let stateArray: MLMultiArray
    private let inputProvider: MLDictionaryFeatureProvider
    /// Storage offsets, in elements, of each row-major element of the
    /// reused input arrays (computed once from their strides).
    private let audioOffsets: [Int]
    private let stateOffsets: [Int]
    /// Resolved from the model description at load time when it declares
    /// output shapes; otherwise resolved from the first prediction.
    private var probabilityOutputName: String?
    private var stateOutputName: String?

    /// The compiled model in the bundle, or nil if the app was built
    /// without one. Checked at the bundle root (an `.mlpackage` in the
    /// target's sources compiles there) and under `CoreMLModels/` (a
    /// developer who adds the folder as a blue folder reference instead).
    static func bundledModelURL() -> URL? {
        Bundle.main.url(forResource: modelName, withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: modelName, withExtension: "mlmodelc", subdirectory: "CoreMLModels")
    }

    /// Nil when the model is absent or fails to load or validate: the
    /// caller falls back to `EnergyVAD`. Never throws out of the capture
    /// path. Loading can take a few hundred milliseconds the first time
    /// the OS compiles the model for the Neural Engine (cached afterwards).
    static func loadIfAvailable() -> CoreMLSileroRunner? {
        guard let url = bundledModelURL() else { return nil }
        return try? CoreMLSileroRunner(contentsOf: url)
    }

    init(contentsOf url: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: url, configuration: configuration)
        self.model = model

        let description = model.modelDescription
        let inputs = description.inputDescriptionsByName

        guard let audioConstraint = inputs[Self.audioInputName]?.multiArrayConstraint else {
            throw RunnerError.unexpectedInterface("no multi-array input named \"\(Self.audioInputName)\"")
        }
        guard let stateConstraint = inputs[Self.stateInputName]?.multiArrayConstraint else {
            throw RunnerError.unexpectedInterface("no multi-array input named \"\(Self.stateInputName)\"")
        }
        let audioShape = Self.shape(of: audioConstraint, fallback: [1, SileroVAD.windowSamples])
        let stateShape = Self.shape(of: stateConstraint, fallback: [2, 1, 128])
        guard audioShape.reduce(1, *) == SileroVAD.windowSamples else {
            throw RunnerError.unexpectedInterface("\"audio\" has shape \(audioShape), expected \(SileroVAD.windowSamples) elements")
        }
        guard stateShape.reduce(1, *) == SileroVAD.stateCount else {
            throw RunnerError.unexpectedInterface("\"state\" has shape \(stateShape), expected \(SileroVAD.stateCount) elements")
        }
        guard audioConstraint.dataType == .float32, stateConstraint.dataType == .float32 else {
            throw RunnerError.unexpectedInterface("\"audio\" and \"state\" must be float32")
        }

        let audioArray = try MLMultiArray(shape: audioShape.map { NSNumber(value: $0) }, dataType: .float32)
        let stateArray = try MLMultiArray(shape: stateShape.map { NSNumber(value: $0) }, dataType: .float32)
        self.audioArray = audioArray
        self.stateArray = stateArray
        self.audioOffsets = Self.rowMajorOffsets(shape: audioShape, strides: audioArray.strides.map(\.intValue))
        self.stateOffsets = Self.rowMajorOffsets(shape: stateShape, strides: stateArray.strides.map(\.intValue))

        var features: [String: Any] = [
            Self.audioInputName: MLFeatureValue(multiArray: audioArray),
            Self.stateInputName: MLFeatureValue(multiArray: stateArray),
        ]

        // "sr" is a constant for us. The conversion doc exports it as
        // int32; a float32 export (coremltools' default dtype) is accepted
        // too, and a model exported without it (sample rate baked in) needs
        // nothing.
        if let srConstraint = inputs[Self.sampleRateInputName]?.multiArrayConstraint {
            let srShape = Self.shape(of: srConstraint, fallback: [1])
            guard srShape.reduce(1, *) == 1 else {
                throw RunnerError.unexpectedInterface("\"sr\" has shape \(srShape), expected 1 element")
            }
            let srType: MLMultiArrayDataType
            switch srConstraint.dataType {
            case .int32: srType = .int32
            case .float32: srType = .float32
            case .double: srType = .double
            default:
                throw RunnerError.unexpectedInterface("\"sr\" must be int32, float32 or double")
            }
            let srArray = try MLMultiArray(shape: srShape.map { NSNumber(value: $0) }, dataType: srType)
            // NSNumber subscript converts to the array's element type.
            srArray[0] = NSNumber(value: Self.sampleRate)
            features[Self.sampleRateInputName] = MLFeatureValue(multiArray: srArray)
        } else if inputs[Self.sampleRateInputName] != nil {
            throw RunnerError.unexpectedInterface("\"sr\" is not a multi-array input")
        }
        self.inputProvider = try MLDictionaryFeatureProvider(dictionary: features)

        // Pick outputs by declared element count when the model states its
        // output shapes (mlprogram exports usually do).
        for (name, feature) in description.outputDescriptionsByName {
            guard let constraint = feature.multiArrayConstraint, !constraint.shape.isEmpty else { continue }
            let count = constraint.shape.map(\.intValue).reduce(1, *)
            if count == 1, probabilityOutputName == nil {
                probabilityOutputName = name
            } else if count == SileroVAD.stateCount, stateOutputName == nil {
                stateOutputName = name
            }
        }
    }

    mutating func predict(audio: [Float], state: [Float]) throws -> (probability: Float, state: [Float]) {
        guard audio.count == SileroVAD.windowSamples else {
            throw RunnerError.badInput("audio has \(audio.count) samples, expected \(SileroVAD.windowSamples)")
        }
        guard state.count == SileroVAD.stateCount else {
            throw RunnerError.badInput("state has \(state.count) elements, expected \(SileroVAD.stateCount)")
        }
        Self.write(audio, into: audioArray, offsets: audioOffsets)
        Self.write(state, into: stateArray, offsets: stateOffsets)

        let output = try model.prediction(from: inputProvider)

        if probabilityOutputName == nil || stateOutputName == nil {
            try resolveOutputNames(from: output)
        }
        guard let probabilityName = probabilityOutputName, let stateName = stateOutputName,
              let probabilityArray = output.featureValue(for: probabilityName)?.multiArrayValue,
              let newStateArray = output.featureValue(for: stateName)?.multiArrayValue
        else {
            throw RunnerError.unexpectedOutput("missing probability or state output")
        }

        let probability = try Self.read(probabilityArray)
        let newState = try Self.read(newStateArray)
        guard let p = probability.first else {
            throw RunnerError.unexpectedOutput("empty probability output")
        }
        guard newState.count == SileroVAD.stateCount else {
            throw RunnerError.unexpectedOutput("state output has \(newState.count) elements, expected \(SileroVAD.stateCount)")
        }
        return (p, newState)
    }

    // MARK: Internals

    /// Resolves which output is the probability and which the new state
    /// from the arrays actually returned, for models whose description
    /// leaves output shapes unspecified.
    private mutating func resolveOutputNames(from output: MLFeatureProvider) throws {
        for name in output.featureNames.sorted() {
            guard let array = output.featureValue(for: name)?.multiArrayValue else { continue }
            if array.count == 1, probabilityOutputName == nil {
                probabilityOutputName = name
            } else if array.count == SileroVAD.stateCount, stateOutputName == nil {
                stateOutputName = name
            }
        }
        guard probabilityOutputName != nil, stateOutputName != nil else {
            let names = output.featureNames.sorted().joined(separator: ", ")
            throw RunnerError.unexpectedOutput("could not find a 1-element and a \(SileroVAD.stateCount)-element output among [\(names)]")
        }
    }

    private static func shape(of constraint: MLMultiArrayConstraint, fallback: [Int]) -> [Int] {
        let declared = constraint.shape.map(\.intValue)
        return declared.isEmpty ? fallback : declared
    }

    /// Storage offset (in elements) of every element of an array with the
    /// given shape, in row-major order, honouring the array's strides so a
    /// padded or pitched buffer is read and written correctly.
    static func rowMajorOffsets(shape: [Int], strides: [Int]) -> [Int] {
        guard shape.count == strides.count, !shape.contains(where: { $0 <= 0 }) else { return [] }
        let count = shape.reduce(1, *)
        var offsets = [Int](repeating: 0, count: count)
        var index = [Int](repeating: 0, count: shape.count)
        for flat in 0..<count {
            var offset = 0
            for d in 0..<shape.count {
                offset += index[d] * strides[d]
            }
            offsets[flat] = offset
            // Advance the multi-index, last dimension fastest.
            var d = shape.count - 1
            while d >= 0 {
                index[d] += 1
                if index[d] < shape[d] { break }
                index[d] = 0
                d -= 1
            }
        }
        return offsets
    }

    private static func write(_ values: [Float], into array: MLMultiArray, offsets: [Int]) {
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        let n = min(values.count, offsets.count)
        for i in 0..<n {
            pointer[offsets[i]] = values[i]
        }
    }

    /// Reads every element in row-major order as Float, whatever storage
    /// type Core ML chose for the output.
    static func read(_ array: MLMultiArray) throws -> [Float] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let offsets = rowMajorOffsets(shape: shape, strides: strides)
        guard !offsets.isEmpty else { return [] }
        var values = [Float](repeating: 0, count: offsets.count)
        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<offsets.count { values[i] = pointer[offsets[i]] }
        case .float16:
            let pointer = array.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<offsets.count { values[i] = Float(pointer[offsets[i]]) }
        case .double:
            let pointer = array.dataPointer.assumingMemoryBound(to: Double.self)
            for i in 0..<offsets.count { values[i] = Float(pointer[offsets[i]]) }
        case .int32:
            let pointer = array.dataPointer.assumingMemoryBound(to: Int32.self)
            for i in 0..<offsets.count { values[i] = Float(pointer[offsets[i]]) }
        default:
            throw RunnerError.unexpectedOutput("unsupported output data type \(array.dataType.rawValue)")
        }
        return values
    }
}

// MARK: - Detector

/// Silero VAD behind the `VoiceActivityDetector` protocol.
///
/// `SessionBuffer` feeds 30 ms (480-sample) frames; the network wants
/// 32 ms (512-sample) windows. Incoming frames accumulate in a pending
/// buffer and the model runs each time 512 samples are available (the
/// remainder, always < 512, waits for the next frame), threading the
/// recurrent state from call to call. A frame's answer is the latest
/// window's probability passed through hysteresis: speech starts at
/// `Tuning.onset` and ends below `Tuning.offset`.
///
/// Latency: the first frame of a stream carries no window yet (480 < 512)
/// and in general a frame's decision reflects audio up to one 512-sample
/// window — up to 32 ms — behind the frame's end. `SessionBuffer`'s
/// 3-frame onset debounce and 0.5 s hangover absorb that comfortably.
///
/// An `EnergyVAD` runs alongside on every frame. It supplies `currentRMS`
/// and `currentThreshold` (the Listen tab's meter keeps its energy meaning
/// under either detector) and it is the warm fallback: if the model throws,
/// that frame is "not speech"; after `Tuning.maxConsecutiveFailures`
/// failures in a row the model is abandoned for the rest of the process
/// and this detector answers exactly like `EnergyVAD` from then on
/// (`isDegraded`, `lastError`). `reset()` does not re-arm the model.
struct SileroVAD: VoiceActivityDetector {
    /// Model input window: 32 ms at 16 kHz.
    static let windowSamples = 512
    /// Flat recurrent state (2, 1, 128).
    static let stateCount = 256

    struct Tuning {
        /// Probability at or above which a non-speech run becomes speech.
        var onset: Float = 0.5
        /// Probability below which a speech run ends.
        var offset: Float = 0.35
        /// Runner failures in a row after which the model is abandoned.
        var maxConsecutiveFailures = 3
    }

    let tuning: Tuning
    private var runner: SileroModelRunner
    private var energy: EnergyVAD

    private var pending: [Float] = []
    private var state: [Float]
    private var inSpeech = false
    private var consecutiveFailures = 0

    /// Speech probability of the most recent window; nil before the first
    /// successful model call, after a failed call, and once degraded.
    private(set) var currentConfidence: Float?
    /// True once the model has been abandoned for this process.
    private(set) var isDegraded = false
    /// Description of the most recent runner failure, kept after recovery
    /// for diagnostics.
    private(set) var lastError: String?
    /// Successful model calls so far (diagnostics and tests).
    private(set) var modelCallCount = 0

    var currentRMS: Float { energy.currentRMS }
    var currentThreshold: Float { energy.currentThreshold }

    init(runner: SileroModelRunner, tuning: Tuning = Tuning(), energy: EnergyVAD = EnergyVAD()) {
        self.runner = runner
        self.tuning = tuning
        self.energy = energy
        self.state = [Float](repeating: 0, count: Self.stateCount)
        self.pending.reserveCapacity(Self.windowSamples * 2)
    }

    mutating func isSpeech(_ frame: ArraySlice<Float>) -> Bool {
        guard !frame.isEmpty else { return false }
        // Always consulted: it keeps the level readout honest and stays
        // warm (knows the room) in case the model has to be abandoned.
        let energySpeech = energy.isSpeech(frame)
        if isDegraded { return energySpeech }

        pending.append(contentsOf: frame)
        while pending.count >= Self.windowSamples {
            let window = Array(pending.prefix(Self.windowSamples))
            pending.removeFirst(Self.windowSamples)
            runModel(on: window)
            if isDegraded { return energySpeech }
        }
        return inSpeech
    }

    /// Zeroes the recurrent state and the pending samples and drops any
    /// speech run, as for a new stream. The model stays abandoned if it
    /// was; the embedded energy detector goes back to its cold-start floor.
    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        state = [Float](repeating: 0, count: Self.stateCount)
        inSpeech = false
        currentConfidence = nil
        consecutiveFailures = 0
        energy.reset()
    }

    // MARK: Internals

    private mutating func runModel(on window: [Float]) {
        do {
            let result = try runner.predict(audio: window, state: state)
            guard result.state.count == Self.stateCount else {
                throw CoreMLSileroRunner.RunnerError.unexpectedOutput(
                    "runner returned \(result.state.count) state elements, expected \(Self.stateCount)")
            }
            guard result.probability.isFinite else {
                throw CoreMLSileroRunner.RunnerError.unexpectedOutput("runner returned a non-finite probability")
            }
            let probability = min(max(result.probability, 0), 1)
            state = result.state
            currentConfidence = probability
            inSpeech = inSpeech ? probability >= tuning.offset : probability >= tuning.onset
            consecutiveFailures = 0
            modelCallCount += 1
        } catch {
            consecutiveFailures += 1
            lastError = String(describing: error)
            inSpeech = false
            currentConfidence = nil
            if consecutiveFailures >= tuning.maxConsecutiveFailures {
                isDegraded = true
                pending.removeAll()
                state = [Float](repeating: 0, count: Self.stateCount)
            }
        }
    }
}

// MARK: - Factory

/// Picks the detector for a capture start: Silero when its model is bundled
/// and loads, otherwise the Phase 1 energy gate. Mirrors the WhisperKit
/// pattern — the app ships without the model unless a developer adds it,
/// and nothing is ever downloaded.
enum VoiceActivityDetectorFactory {
    enum Kind: String {
        case silero
        case energy
    }

    /// Which detector `makeDefault()` produced most recently. Written on
    /// the capture queue at the first Listen start and never again (the
    /// detector is carried across starts), so a later read from the main
    /// actor is safe in practice; `CaptureController.vadKind` is the
    /// main-actor copy the UI should prefer.
    static var activeKind: Kind = .energy

    static func makeDefault() -> VoiceActivityDetector {
        if let runner = CoreMLSileroRunner.loadIfAvailable() {
            activeKind = .silero
            return SileroVAD(runner: runner)
        }
        activeKind = .energy
        return EnergyVAD()
    }

    static func kind(of detector: VoiceActivityDetector) -> Kind {
        detector is SileroVAD ? .silero : .energy
    }
}
