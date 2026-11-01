import AVFoundation
import Foundation

/// Microphone capture, converted to the pipeline's canonical format:
/// 16 kHz mono Float32 (§5.1). Delivers sample chunks to a handler on a
/// dedicated serial queue. Knows nothing about sessions or VAD.
///
/// Threading: the capture queue is the only mutator of capture state
/// (`converter`, `onSamples`, `wantsRunning`, the engine itself). `start`
/// and `stop` hop onto it synchronously; audio-session notifications hop
/// onto it asynchronously; the tap hops onto it per buffer. Callers may use
/// `perform`/`performSync` to run their own capture-side work in the same
/// order as delivered chunks.
final class AudioCaptureEngine {
    enum CaptureError: LocalizedError {
        case microphonePermissionDenied
        case formatUnavailable
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Rosetta doesn't have permission to use the microphone. Allow it in Settings > Privacy & Security > Microphone."
            case .formatUnavailable:
                return "The microphone isn't reporting an audio format. Try unplugging headphones or restarting the phone."
            case .converterUnavailable:
                return "The microphone's audio format can't be converted for listening on this phone."
            }
        }
    }

    /// One delivered chunk of 16 kHz mono samples, stamped with the wall
    /// clock time it arrived from the microphone so downstream timestamps
    /// never depend on the sample stream having been unbroken.
    struct Chunk {
        let samples: [Float]
        let receivedAt: Date
    }

    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "rosetta.capture", qos: .userInitiated)

    // Capture-queue state.
    private var converter: AVAudioConverter?
    private var onSamples: ((Chunk) -> Void)?
    /// True between `start` and `stop`, including while stalled by an
    /// interruption; distinct from `isRunning`, which is the engine's truth.
    private var wantsRunning = false

    private var observers: [NSObjectProtocol] = []

    /// Called on the capture queue after the tap has been removed and the
    /// engine stopped because of an interruption, a configuration change or
    /// a media-services reset. The string is a plain-language reason.
    var onStalled: ((String) -> Void)?
    /// Called on the capture queue after the engine has been rebuilt and
    /// restarted following a stall or an input route change. Chunks
    /// delivered after this call may be separated from earlier ones by a
    /// gap of unknown length.
    var onResumed: (() -> Void)?

    /// The engine's actual state, not a cached flag.
    var isRunning: Bool { engine.isRunning }

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(SessionBuffer.sampleRate),
        channels: 1,
        interleaved: false
    )!

    init() {
        observeAudioSession()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Control (call from any thread; serialized on the capture queue)

    /// `handler` is called on the capture queue with 16 kHz mono samples.
    /// Starting while already started tears the old capture down first.
    func start(handler: @escaping (Chunk) -> Void) throws {
        try queue.sync {
            if wantsRunning {
                tearDownLocked()
            }
            onSamples = handler
            wantsRunning = true
            do {
                try bringUpLocked()
            } catch {
                tearDownLocked()
                wantsRunning = false
                onSamples = nil
                throw error
            }
        }
    }

    /// One-tap pause must take effect instantly (§7): the tap is removed,
    /// the engine stopped and any in-flight chunk delivered before this
    /// returns. No chunk can reach the handler afterwards.
    func stop() {
        queue.sync {
            guard wantsRunning else { return }
            wantsRunning = false
            tearDownLocked()
            onSamples = nil
        }
    }

    /// Runs `work` on the capture queue, after any chunk already queued.
    func perform(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    /// Runs `work` on the capture queue and waits for it. Never call from
    /// the capture queue itself (a chunk handler or a stall/resume
    /// callback): that would deadlock.
    func performSync(_ work: () -> Void) {
        queue.sync(execute: work)
    }

    // MARK: - Engine lifecycle (capture queue only)

    private func bringUpLocked() throws {
        let audioSession = AVAudioSession.sharedInstance()
        // .mixWithOthers: ambient listening must never interrupt anything
        // else the device is doing; no unexpected sounds, ever (§7).
        try audioSession.setCategory(.playAndRecord, mode: .default,
                                     options: [.mixWithOthers, .defaultToSpeaker])
        try audioSession.setActive(true)

        let input = engine.inputNode
        // Best-effort acoustic echo cancellation so the board's own speech
        // (played through this same session) is attenuated before it
        // reaches the VAD. Voice processing is not guaranteed on every
        // device or route, and it is not a complete fix: CaptureController
        // additionally zeroes samples while SpeechOutput is speaking. The
        // input format must be read AFTER this call because enabling voice
        // processing changes it.
        try? input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.formatUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            // Stamp on the render thread so the time is as close as
            // possible to when the audio actually arrived.
            let receivedAt = Date()
            self?.queue.async { self?.convertAndDeliver(buffer, receivedAt: receivedAt) }
        }
        engine.prepare()
        try engine.start()
    }

    private func tearDownLocked() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        converter = nil
    }

    private func stallLocked(reason: String) {
        guard wantsRunning else { return }
        tearDownLocked()
        onStalled?(reason)
    }

    private func restartLocked() {
        guard wantsRunning else { return }
        tearDownLocked()
        do {
            try bringUpLocked()
            onResumed?()
        } catch {
            onStalled?("the microphone could not be restarted (\(error.localizedDescription))")
        }
    }

    private func convertAndDeliver(_ buffer: AVAudioPCMBuffer, receivedAt: Date) {
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
            onSamples(Chunk(samples: samples, receivedAt: receivedAt))
        }
    }

    // MARK: - Audio session events

    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: nil
        ) { [weak self] note in
            self?.handleInterruption(userInfo: note.userInfo ?? [:])
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: nil
        ) { [weak self] note in
            self?.handleRouteChange(userInfo: note.userInfo ?? [:])
        })

        // Posted by the engine when the hardware configuration changed
        // underneath it (it stops itself). Observed without an object so
        // the observer survives the engine being recreated after a
        // media-services reset.
        observers.append(center.addObserver(
            forName: Notification.Name.AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil
        ) { [weak self] _ in
            self?.handleMediaServicesReset()
        })
    }

    private func handleInterruption(userInfo: [AnyHashable: Any]) {
        guard let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            var reason = "a phone call, Siri, an alarm or another app took the microphone"
            if let reasonValue = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt,
               let interruptionReason = AVAudioSession.InterruptionReason(rawValue: reasonValue),
               interruptionReason == .builtInMicMuted {
                reason = "the microphone was muted"
            }
            queue.async { [weak self] in self?.stallLocked(reason: reason) }

        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            guard options.contains(.shouldResume) else { return }
            queue.async { [weak self] in self?.restartLocked() }

        @unknown default:
            break
        }
    }

    private func handleRouteChange(userInfo: [AnyHashable: Any]) {
        guard let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange, .override, .wakeFromSleep:
            break
        default:
            return
        }

        // Only an input change matters: headphones without a mic, or a
        // speaker-only Bluetooth device, change the output route and leave
        // the microphone alone.
        let previousInputs = (userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?
            .inputs.map(\.uid) ?? []
        let currentInputs = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid)
        guard previousInputs != currentInputs else { return }

        // The input sample rate may differ on the new route: rebuild the
        // converter from the new input format and restart.
        queue.async { [weak self] in self?.restartLocked() }
    }

    private func handleConfigurationChange() {
        queue.async { [weak self] in
            guard let self, self.wantsRunning else { return }
            // The engine stops itself on a real configuration change. If it
            // is still running this notification is informational (for
            // example one that trails our own restart) and nothing is
            // needed.
            guard !self.engine.isRunning else { return }
            self.stallLocked(reason: "the phone's audio setup changed")
            self.restartLocked()
        }
    }

    private func handleMediaServicesReset() {
        queue.async { [weak self] in
            guard let self else { return }
            // Every audio object is invalid after a media-services reset;
            // the engine must be recreated, not restarted.
            let wasWanted = self.wantsRunning
            self.converter = nil
            self.engine = AVAudioEngine()
            guard wasWanted else { return }
            self.onStalled?("the phone's audio system restarted")
            self.restartLocked()
        }
    }
}
