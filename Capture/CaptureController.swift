import AVFoundation
import Foundation
import Observation
import UIKit

/// Glues engine → session buffer → disk + database, and publishes listening
/// state for the parent UI (indicator, pause, live chips, level readout).
///
/// Threading: everything marked "UI state" is read and written on the main
/// actor only. Everything marked "capture-queue state" is touched only on
/// the engine's serial queue (chunk handler, SessionBuffer delegate
/// callbacks, stall/resume callbacks, and `engine.perform`/`performSync`
/// blocks). Capture-queue properties are `@ObservationIgnored` so the
/// observation registrar is never touched off the main actor.
@Observable
final class CaptureController: SessionBufferDelegate {
    /// Free space on the clips volume below which listening pauses: a full
    /// disk fails every clip write and risks the database.
    static let minimumFreeBytes: Int64 = 200 * 1024 * 1024
    /// How often free space is re-checked while listening.
    static let diskCheckInterval: TimeInterval = 60
    /// Level readout refresh ceiling.
    static let levelPublishInterval: TimeInterval = 0.1

    // MARK: UI state (main actor)

    private(set) var isListening = false
    private(set) var activeSessionId: String?
    /// Segments of the current or most recent session, newest last — the
    /// Confirm card's chip source. Cleared when a confirm/skip resolves them.
    private(set) var recentSegments: [SegmentRecord] = []
    /// Persistent plain-language problem for the Listen tab. Stays set
    /// until the next successful start.
    private(set) var lastError: String?
    /// Wall-clock open time of the active session, for confirm latency.
    private(set) var activeSessionOpenedAt: Date?
    /// Microphone level readout for the Listen tab: the last frame's RMS
    /// and the VAD threshold it was judged against. Updated at most ~10 Hz
    /// while listening; (0, 0) otherwise.
    private(set) var liveLevel: (rms: Float, threshold: Float) = (0, 0)

    /// Station identity for context priors, e.g. "Kitchen" (§5.3). Stored so
    /// @Observable notifies; didSet persists and refreshes the capture-side
    /// snapshot.
    var stationName: String {
        didSet {
            UserDefaults.standard.set(stationName, forKey: "stationName")
            let name = stationName
            engine.perform { [weak self] in self?.queueStationName = name }
        }
    }

    /// Set by the app once the encoder model is loaded: embeds a fresh
    /// segment's samples near capture time (§5.7) so ranking is instant at
    /// the Confirm card. Nil when no model is bundled — capture is
    /// deliberately ignorant of ML beyond this hook.
    @ObservationIgnored
    var embedSamples: (([Float], _ segmentId: String) async -> Data?)?

    // MARK: Dependencies

    @ObservationIgnored private let engine = AudioCaptureEngine()
    @ObservationIgnored private let writer = SegmentWriter()
    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private let sessions: SessionStore
    @ObservationIgnored private let events: EventLog

    // MARK: Capture-queue state

    @ObservationIgnored private var buffer: SessionBuffer
    /// Fallback mapping from the sample clock to wall time, used only until
    /// the buffer has seen its first stamped chunk.
    @ObservationIgnored private var streamStartDate = Date()
    /// Snapshot of `stationName` for session rows, so the observable
    /// property is never read off the main actor.
    @ObservationIgnored private var queueStationName: String
    @ObservationIgnored private var lastLevelPublish = Date.distantPast
    @ObservationIgnored private var lastDiskCheck = Date.distantPast
    /// The noise floor is learned once per process; later starts and
    /// resumes carry the detector over instead of resetting it.
    @ObservationIgnored private var hasStartedOnce = false
    /// The session most recently opened in this process, so the next open
    /// can tell whether it displaced an exchange nobody resolved (§2.9).
    @ObservationIgnored private var queueLastSessionId: String?

    init(db: AppDatabase) {
        self.db = db
        self.sessions = SessionStore(db: db)
        self.events = EventLog(db: db)
        let station = UserDefaults.standard.string(forKey: "stationName") ?? "Home"
        self.stationName = station
        self.queueStationName = station
        self.buffer = SessionBuffer()
        self.buffer.delegate = self

        engine.onStalled = { [weak self] reason in self?.handleStall(reason: reason) }
        engine.onResumed = { [weak self] in self?.handleResume() }
    }

    // MARK: - Permissions

    /// Asks for microphone access (the system prompt). Call from first-run
    /// so the first Listen tap doesn't race the prompt.
    static func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: - Listening control (main actor)

    func startListening() {
        guard !isListening else { return }

        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            lastError = AudioCaptureEngine.CaptureError.microphonePermissionDenied.errorDescription
            return
        case .undetermined:
            // Ask first, then start; otherwise the engine start races the
            // prompt and fails with an opaque error.
            Task { @MainActor [weak self] in
                let granted = await Self.requestMicrophonePermission()
                guard let self else { return }
                if granted {
                    self.startListening()
                } else {
                    self.lastError = AudioCaptureEngine.CaptureError.microphonePermissionDenied.errorDescription
                }
            }
            return
        case .granted:
            break
        @unknown default:
            break
        }

        if let free = Self.availableCapacityForClips(), free < Self.minimumFreeBytes {
            lastError = Self.lowDiskMessage(freeBytes: free)
            return
        }

        let station = stationName
        let now = Date()
        // Capture-queue state is only touched on the queue, even when the
        // engine is idle: a stalled engine may be resuming concurrently.
        engine.performSync {
            let detector: VoiceActivityDetector
            if self.hasStartedOnce {
                detector = self.buffer.detector
            } else {
                detector = EnergyVAD()
            }
            self.hasStartedOnce = true
            let fresh = SessionBuffer(vad: detector)
            fresh.delegate = self
            self.buffer = fresh
            self.queueStationName = station
            self.streamStartDate = now
            self.lastLevelPublish = .distantPast
            self.lastDiskCheck = now
        }

        let speech = SpeechOutput.shared
        do {
            try engine.start { [weak self] chunk in
                self?.handleChunk(chunk, speech: speech)
            }
            isListening = true
            lastError = nil
            setIdleTimerDisabled(true)
        } catch {
            lastError = "Could not start listening: \(error.localizedDescription)"
            setIdleTimerDisabled(false)
        }
    }

    /// Instant, honoured pause (§7, §8). The engine is stopped first, so no
    /// frame can arrive while the open session is being closed; nothing
    /// already captured is lost.
    func pauseListening() {
        engine.stop()
        engine.performSync {
            self.buffer.interrupt()
        }
        isListening = false
        liveLevel = (0, 0)
        setIdleTimerDisabled(false)
    }

    /// Marks the current chip set as handled (confirmed or skipped) so the
    /// next exchange starts with a clean card.
    func clearRecentSegments() {
        recentSegments = []
    }

    // MARK: - Capture queue: chunk handling

    private func handleChunk(_ chunk: AudioCaptureEngine.Chunk, speech: SpeechOutput) {
        var samples = chunk.samples
        // While the board is talking, the microphone hears the phone, not
        // the child. Feed silence of the same length so the session clock
        // still advances (and a session still closes on time) without the
        // synthesizer's voice ever becoming a segment.
        if chunk.receivedAt < speech.selfSpeakingUntil {
            samples = [Float](repeating: 0, count: samples.count)
        }
        buffer.ingest(samples, receivedAt: chunk.receivedAt)
        publishLevelIfDue(now: chunk.receivedAt)
        checkDiskIfDue(now: chunk.receivedAt)
    }

    private func publishLevelIfDue(now: Date) {
        guard now.timeIntervalSince(lastLevelPublish) >= Self.levelPublishInterval else { return }
        lastLevelPublish = now
        let level = buffer.liveLevel
        Task { @MainActor in
            self.liveLevel = level
        }
    }

    private func checkDiskIfDue(now: Date) {
        guard now.timeIntervalSince(lastDiskCheck) >= Self.diskCheckInterval else { return }
        lastDiskCheck = now
        guard let free = Self.availableCapacityForClips(), free < Self.minimumFreeBytes else { return }
        let message = Self.lowDiskMessage(freeBytes: free)
        Task { @MainActor in
            self.stopForError(message)
        }
    }

    // MARK: - Capture queue: stall / resume

    /// The engine lost the microphone (phone call, Siri, route or media
    /// reset). Close the open session as interrupted, then tell the UI.
    private func handleStall(reason: String) {
        buffer.interrupt()
        let message = "Listening stopped: \(reason). It will resume on its own if the phone gives the microphone back; otherwise tap Listen."
        Task { @MainActor in
            self.isListening = false
            self.liveLevel = (0, 0)
            self.lastError = message
            self.setIdleTimerDisabled(false)
        }
    }

    /// The engine is delivering again after a gap of unknown length: start
    /// a fresh sample clock with the learned noise floor carried over.
    private func handleResume() {
        buffer.interrupt()
        let fresh = SessionBuffer(vad: buffer.detector)
        fresh.delegate = self
        buffer = fresh
        streamStartDate = Date()
        lastLevelPublish = .distantPast
        Task { @MainActor in
            self.isListening = true
            self.lastError = nil
            self.setIdleTimerDisabled(true)
        }
    }

    // MARK: - Failure path

    /// Stops listening and shows a persistent message. Never leaves the
    /// indicator green after a failure the family needs to know about.
    @MainActor
    private func stopForError(_ message: String) {
        pauseListening()
        lastError = message
    }

    private func failOnCaptureQueue(_ message: String) {
        Task { @MainActor in
            self.stopForError(message)
        }
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        // A counter-top phone that auto-locks stops being a listening
        // station; keep the screen awake exactly while listening.
        Task { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
    }

    // MARK: - Disk space

    static func availableCapacityForClips() -> Int64? {
        let values = try? FileLocations.clips.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func lowDiskMessage(freeBytes: Int64) -> String {
        let formatted = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return "Listening is paused because this phone is almost out of space (\(formatted) left). Free up some space, then tap Listen."
    }

    private func wallDate(forStreamTime time: TimeInterval) -> Date {
        buffer.wallDate(forStreamTime: time) ?? streamStartDate.addingTimeInterval(time)
    }

    // MARK: - SessionBufferDelegate (called on the capture queue)

    func sessionOpened(id: String, atStreamTime time: TimeInterval) {
        let openedAt = wallDate(forStreamTime: time)
        let record = SessionRecord(id: id, startedAt: openedAt, device: queueStationName)
        do {
            try sessions.insert(record)
        } catch {
            failOnCaptureQueue("Could not save the new exchange, so listening stopped: \(error.localizedDescription)")
            return
        }
        // Abandoned-exchange bookkeeping (§2.9): if the exchange this one
        // displaces still has unlabelled segments, nobody got to the yes
        // moment on the card. Log the marker (EventLog.exchangeOutcomes is
        // the source of truth), then sweep Review expiry so the card and
        // live guesses never operate on stale segments. Both are
        // best-effort: a failed write here must not stop listening.
        if let previous = queueLastSessionId, previous != id {
            let previousSegments = (try? sessions.segments(sessionId: previous)) ?? []
            if previousSegments.contains(where: { $0.segmentState == .pending }) {
                try? events.log(EventRecord(
                    exchangeId: previous,
                    type: .abandon,
                    device: queueStationName,
                    timestamp: openedAt
                ))
            }
        }
        queueLastSessionId = id
        _ = try? ReviewQueue(db: db).sweepExpired(now: openedAt)
        Task { @MainActor in
            self.activeSessionId = id
            self.activeSessionOpenedAt = openedAt
            self.recentSegments = []
        }
    }

    func segmentCaptured(_ segment: CapturedSegment) {
        do {
            let clipRef = try writer.write(segment)
            let record = SegmentRecord(
                id: segment.id,
                sessionId: segment.sessionId,
                clipRef: clipRef,
                startedAt: wallDate(forStreamTime: segment.startTime),
                durationMs: Int(segment.duration * 1000)
            )
            try sessions.insertSegment(record)
            Task { @MainActor in
                self.recentSegments.append(record)
            }
            if let embedSamples {
                // The engine persists the blob on the segment row itself
                // (SuggestionEngine.embedSamples(_:segmentId:)); only the
                // in-memory chip needs patching here.
                let samples = segment.samples
                let segmentId = record.id
                Task { [weak self] in
                    guard let blob = await embedSamples(samples, segmentId), let self else { return }
                    await MainActor.run {
                        if let i = self.recentSegments.firstIndex(where: { $0.id == segmentId }) {
                            self.recentSegments[i].embedding = blob
                        }
                    }
                }
            }
        } catch {
            // One lost clip is not a reason to stop listening (the next
            // one usually succeeds), but the family must see it.
            Task { @MainActor in
                self.lastError = "Could not save a clip: \(error.localizedDescription)"
            }
        }
    }

    func sessionClosed(id: String, atStreamTime time: TimeInterval, reason: SessionCloseReason) {
        let closedAt = wallDate(forStreamTime: time)
        do {
            try sessions.close(id: id, at: closedAt)
        } catch {
            failOnCaptureQueue("Could not save the end of an exchange, so listening stopped: \(error.localizedDescription)")
        }
        Task { @MainActor in
            if self.activeSessionId == id {
                self.activeSessionId = nil
                // recentSegments intentionally kept: the yes-moment usually
                // comes after the child stops talking, so the Confirm card
                // still needs the chips of the just-closed session.
            }
        }
    }
}
