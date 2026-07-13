import AVFoundation
import Foundation

/// Microphone capture, converted to the pipeline's canonical format:
/// 16 kHz mono Float32 (§5.1). Delivers sample chunks to a handler on a
/// dedicated serial queue. Knows nothing about sessions or VAD.
final class AudioCaptureEngine {
    enum CaptureError: Error {
        case formatUnavailable
        case converterUnavailable
    }

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "rosetta.capture", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var onSamples: (([Float]) -> Void)?

    private(set) var isRunning = false

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(SessionBuffer.sampleRate),
        channels: 1,
        interleaved: false
    )!

    /// `handler` is called on the capture queue with 16 kHz mono samples.
    func start(handler: @escaping ([Float]) -> Void) throws {
        guard !isRunning else { return }
        onSamples = handler

        let audioSession = AVAudioSession.sharedInstance()
        // .mixWithOthers: ambient listening must never interrupt anything
        // else the device is doing; no unexpected sounds, ever (§7).
        try audioSession.setCategory(.playAndRecord, mode: .default,
                                     options: [.mixWithOthers, .defaultToSpeaker])
        try audioSession.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw CaptureError.formatUnavailable }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.queue.async { self?.convertAndDeliver(buffer) }
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// One-tap pause must take effect instantly (§7): the tap is removed and
    /// the engine stopped before this returns.
    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        onSamples = nil
        isRunning = false
    }

    private func convertAndDeliver(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let onSamples else { return }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return
        }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, let channel = out.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        if !samples.isEmpty {
            onSamples(samples)
        }
    }
}
