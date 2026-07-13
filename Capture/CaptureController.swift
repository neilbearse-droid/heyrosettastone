import Foundation
import Observation

/// Glues engine → session buffer → disk + database, and publishes listening
/// state for the parent UI (indicator, pause, live chips). All UI-visible
/// state changes hop to the main actor.
@Observable
final class CaptureController: SessionBufferDelegate {
    // UI state.
    private(set) var isListening = false
    private(set) var activeSessionId: String?
    /// Segments of the current or most recent session, newest last — the
    /// Confirm card's chip source. Cleared when a confirm/skip resolves them.
    private(set) var recentSegments: [SegmentRecord] = []
    private(set) var lastError: String?

    /// Station identity for context priors, e.g. "Kitchen" (§5.3). Stored so
    /// @Observable notifies; didSet persists.
    var stationName: String {
        didSet { UserDefaults.standard.set(stationName, forKey: "stationName") }
    }

    private let engine = AudioCaptureEngine()
    private let writer = SegmentWriter()
    private var buffer: SessionBuffer
    private let sessions: SessionStore
    private let events: EventLog

    /// Maps the sample-clock to wall time: the Date at stream position 0.
    private var streamStartDate = Date()
    /// Wall-clock open time of the active session, for confirm latency.
    private(set) var activeSessionOpenedAt: Date?

    init(db: AppDatabase) {
        self.sessions = SessionStore(db: db)
        self.events = EventLog(db: db)
        self.stationName = UserDefaults.standard.string(forKey: "stationName") ?? "Home"
        self.buffer = SessionBuffer()
        self.buffer.delegate = self
    }

    // MARK: - Listening control

    func startListening() {
        guard !isListening else { return }
        streamStartDate = Date()
        buffer = SessionBuffer()
        buffer.delegate = self
        do {
            try engine.start { [weak self] samples in
                self?.buffer.ingest(samples)
            }
            isListening = true
            lastError = nil
        } catch {
            lastError = "Could not start listening: \(error.localizedDescription)"
        }
    }

    /// Instant, honoured pause (§7, §8). Closes any open session first so
    /// nothing already captured is lost.
    func pauseListening() {
        buffer.interrupt()
        engine.stop()
        isListening = false
    }

    /// Marks the current chip set as handled (confirmed or skipped) so the
    /// next exchange starts with a clean card.
    func clearRecentSegments() {
        recentSegments = []
    }

    private func wallDate(forStreamTime time: TimeInterval) -> Date {
        streamStartDate.addingTimeInterval(time)
    }

    // MARK: - SessionBufferDelegate (called on the capture queue)

    func sessionOpened(id: String, atStreamTime time: TimeInterval) {
        let openedAt = wallDate(forStreamTime: time)
        let record = SessionRecord(id: id, startedAt: openedAt, device: stationName)
        try? sessions.insert(record)
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
        } catch {
            Task { @MainActor in
                self.lastError = "Could not save a clip: \(error.localizedDescription)"
            }
        }
    }

    func sessionClosed(id: String, atStreamTime time: TimeInterval, reason: SessionCloseReason) {
        try? sessions.close(id: id, at: wallDate(forStreamTime: time))
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
