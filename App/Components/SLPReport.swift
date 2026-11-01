import Foundation
import GRDB
import UIKit

// MARK: - Data

/// Everything in the SLP report (§6: "PDF summary of intent inventory,
/// frequencies, contexts, and growth over time, no raw audio"), as plain
/// values. `build` reads the database; `SLPReport.render` draws it. Pure
/// and Equatable so the tests can assert on it without a PDF parser.
///
/// Child-neutral: no name is stored anywhere in the app, so none appears
/// here. Station names and labeller names are the family's own words.
struct SLPReportData: Equatable {
    /// One dictionary entry, most frequent first in `inventory`.
    struct IntentSummary: Equatable, Identifiable {
        var id: String
        var label: String
        var respondNote: String?
        /// Confirmed exemplars (clips).
        var clipCount: Int
        /// Distinct exchanges those clips came from (session id on the
        /// exemplar; a clip with no session — pre-v3 — counts as its own).
        var exchangeCount: Int
        /// Family confirmations of this meaning: Confirm card, Ask flow,
        /// and his own board taps (`EventLog.confirmCounts`).
        var confirmationCount: Int
        var firstConfirmedAt: Date?
        var lastConfirmedAt: Date?
        /// Up to two of "mornings" / "afternoons" / "evenings" / "nights",
        /// most common first, from when the clips were captured.
        var typicalTimes: [String]
        /// The station most of the clips were captured at.
        var typicalStation: String?
        /// Plain-language maturity (§5.6), from the ranking engine's report
        /// when the caller had one.
        var maturity: String
    }

    /// One ISO week of growth, oldest first in `weeks`.
    struct WeekSummary: Equatable {
        var weekStart: Date
        /// Clips confirmed (by confirmation time) this week.
        var newClips: Int
        /// Labels whose 5th clip was confirmed this week.
        var wordsReachingFive: [String]
        /// Median ms from exchange open to confirmation this week.
        var medianLatencyMs: Int?
        var exchangesResolved: Int
        var exchangesAbandoned: Int
    }

    static let appName = "Rosetta"
    static let weeksCovered = 12
    /// The §5.6 exemplar count a word is reported as "reaching".
    static var clipTarget: Int { MaturityGate.Config().minExemplars }

    var generatedAt: Date
    var preparedBy: String
    var stations: [String]
    var labellers: [String]
    var totalClips: Int
    var inventory: [IntentSummary]
    var weeks: [WeekSummary]

    // MARK: Build

    /// Reads the stores and summarises them. Safe to call off the main
    /// thread (nothing here is main-actor state); pass the engine's
    /// `maturityReports` from the main actor if you have them, or nil when
    /// no model is running so the report says so rather than "learning".
    ///
    /// `calendar` decides local hour-of-day buckets and the time zone of
    /// the ISO weeks (always Monday-start, whatever the calendar's own
    /// first weekday).
    static func build(db: AppDatabase,
                      labeller: String,
                      maturity: [MaturityGate.Report]? = nil,
                      now: Date = Date(),
                      calendar: Calendar = .current) throws -> SLPReportData {
        let intents = try IntentStore(db: db).all()
        let exemplars: [ExemplarRecord] = try db.dbQueue.read { db in
            try ExemplarRecord.order(Column("timestamp")).fetchAll(db)
        }
        let sessionDevices: [String] = try db.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT device FROM sessions")
        }
        let events = EventLog(db: db)
        let confirmCounts = try events.confirmCounts()

        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let weekStarts = Self.weekStarts(endingAt: now, count: weeksCovered, calendar: iso)
        let since = weekStarts.first ?? now
        var weekIndex: [Date: Int] = [:]
        for (index, start) in weekStarts.enumerated() { weekIndex[start] = index }
        func week(of date: Date) -> Int? {
            guard let start = iso.dateInterval(of: .weekOfYear, for: date)?.start else { return nil }
            return weekIndex[start]
        }

        var byIntent: [String: [ExemplarRecord]] = [:]
        for exemplar in exemplars {
            byIntent[exemplar.intentId, default: []].append(exemplar)
        }
        var reports: [String: MaturityGate.Report] = [:]
        for report in maturity ?? [] { reports[report.intentId] = report }

        var inventory: [IntentSummary] = []
        for intent in intents {
            let own = byIntent[intent.id] ?? []
            var sessions = Set<String>()
            var orphanClips = 0
            var timeBuckets: [String: Int] = [:]
            var stationCounts: [String: Int] = [:]
            for exemplar in own {
                if let session = exemplar.sessionId { sessions.insert(session) } else { orphanClips += 1 }
                timeBuckets[Self.timeOfDay(exemplar.capturedAt, calendar: calendar), default: 0] += 1
                stationCounts[exemplar.device, default: 0] += 1
            }
            // Most common first; ties fall back to the order of the day so
            // the result does not depend on sort stability.
            let typicalTimes = Self.timeOrder.enumerated()
                .filter { (timeBuckets[$0.element] ?? 0) > 0 }
                .sorted { a, b in
                    let ca = timeBuckets[a.element] ?? 0
                    let cb = timeBuckets[b.element] ?? 0
                    return ca != cb ? ca > cb : a.offset < b.offset
                }
                .prefix(2)
                .map(\.element)
            let typicalStation = stationCounts
                .sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
                .first?.key
            inventory.append(IntentSummary(
                id: intent.id,
                label: intent.label,
                respondNote: (intent.respondNote?.isEmpty ?? true) ? nil : intent.respondNote,
                clipCount: own.count,
                exchangeCount: sessions.count + orphanClips,
                confirmationCount: confirmCounts[intent.id] ?? 0,
                firstConfirmedAt: own.map(\.timestamp).min(),
                lastConfirmedAt: own.map(\.timestamp).max(),
                typicalTimes: Array(typicalTimes),
                typicalStation: typicalStation,
                maturity: Self.maturityText(reports[intent.id], modelRunning: maturity != nil)
            ))
        }
        // Frequency first (confirmations, then clips), then label, so the
        // SLP reads the words that matter most at home first.
        inventory.sort { a, b in
            if a.confirmationCount != b.confirmationCount { return a.confirmationCount > b.confirmationCount }
            if a.clipCount != b.clipCount { return a.clipCount > b.clipCount }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }

        // Growth over time, one bucket per ISO week.
        var newClips = [Int](repeating: 0, count: weekStarts.count)
        var reachedFive = [[String]](repeating: [], count: weekStarts.count)
        var latencies = [[Int]](repeating: [], count: weekStarts.count)
        var resolved = [Int](repeating: 0, count: weekStarts.count)
        var abandoned = [Int](repeating: 0, count: weekStarts.count)

        for exemplar in exemplars where exemplar.timestamp >= since {
            if let index = week(of: exemplar.timestamp) { newClips[index] += 1 }
        }
        let target = clipTarget
        for intent in intents {
            let own = (byIntent[intent.id] ?? []).sorted { $0.timestamp < $1.timestamp }
            guard own.count >= target else { continue }
            let fifth = own[target - 1].timestamp
            guard fifth >= since, let index = week(of: fifth) else { continue }
            reachedFive[index].append(intent.label)
        }
        for row in try events.confirmLatencyRows(since: since) {
            if let index = week(of: row.timestamp) { latencies[index].append(row.latencyMs) }
        }
        for session in try events.sessionOutcomes(since: since, now: now) {
            guard let index = week(of: session.startedAt) else { continue }
            switch session.outcome {
            case .resolved: resolved[index] += 1
            case .abandoned: abandoned[index] += 1
            case .undecided, .notAnExchange: continue
            }
        }

        var weeks: [WeekSummary] = []
        for (index, start) in weekStarts.enumerated() {
            let sorted = latencies[index].sorted()
            weeks.append(WeekSummary(
                weekStart: start,
                newClips: newClips[index],
                wordsReachingFive: reachedFive[index].sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                },
                medianLatencyMs: sorted.isEmpty ? nil : sorted[sorted.count / 2],
                exchangesResolved: resolved[index],
                exchangesAbandoned: abandoned[index]
            ))
        }

        let stations = Set(exemplars.map(\.device) + sessionDevices)
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let labellers = Set(exemplars.map(\.labeller))
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        return SLPReportData(
            generatedAt: now,
            preparedBy: labeller.trimmingCharacters(in: .whitespaces).isEmpty ? "the family" : labeller,
            stations: stations,
            labellers: labellers,
            totalClips: exemplars.count,
            inventory: inventory,
            weeks: weeks
        )
    }

    // MARK: Helpers (internal for tests)

    static let timeOrder = ["mornings", "afternoons", "evenings", "nights"]

    /// Local hour → bucket. 5–11 mornings, 12–16 afternoons, 17–20
    /// evenings, otherwise nights.
    static func timeOfDay(_ date: Date, calendar: Calendar) -> String {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<12: return "mornings"
        case 12..<17: return "afternoons"
        case 17..<21: return "evenings"
        default: return "nights"
        }
    }

    /// The Monday-start week containing `end` and the `count - 1` weeks
    /// before it, oldest first.
    static func weekStarts(endingAt end: Date, count: Int, calendar: Calendar) -> [Date] {
        guard count > 0, let current = calendar.dateInterval(of: .weekOfYear, for: end)?.start else { return [] }
        var starts: [Date] = []
        for back in stride(from: count - 1, through: 0, by: -1) {
            if let start = calendar.date(byAdding: .weekOfYear, value: -back, to: current) {
                starts.append(start)
            }
        }
        return starts
    }

    /// Same words Progress uses (§5.6), without the live-only framing.
    static func maturityText(_ report: MaturityGate.Report?, modelRunning: Bool) -> String {
        guard modelRunning else { return "no live guessing on this phone yet" }
        guard let report else { return "counting confirmations" }
        if report.isSuggestible {
            let pct = Int(((report.looTop3HitRate ?? 0) * 100).rounded())
            return "guessed live — recognizes \(pct)% of its own clips"
        }
        let config = MaturityGate.Config()
        if report.exemplarCount < config.minExemplars {
            return "learning — \(report.exemplarCount) of \(config.minExemplars) clips needed"
        }
        if report.sessionCount < config.minSessions {
            return "learning — heard in \(report.sessionCount) of \(config.minSessions) separate exchanges so far"
        }
        return "learning — needs a few more confirmations before guessing"
    }
}

// MARK: - PDF

/// Draws `SLPReportData` as a US Letter PDF with `UIGraphicsPDFRenderer`.
/// Row-by-row: every row is one attributed string, measured with
/// `boundingRect`, and a row that would cross the bottom margin starts a
/// new page. Header and footer on every page. Correctness over beauty.
enum SLPReport {
    static let pageSize = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 36
    static let footerText = "Prepared by the family with Rosetta — no audio included"

    /// `Rosetta-SLP-report-YYYY-MM-DD.pdf`, dated from the data.
    static func fileName(for data: SLPReportData) -> String {
        let stamp = ISO8601DateFormatter().string(from: data.generatedAt).prefix(10)
        return "Rosetta-SLP-report-\(stamp).pdf"
    }

    /// Renders and writes the PDF into the temporary directory for the
    /// share sheet; returns its URL.
    static func writeTemporaryPDF(_ data: SLPReportData) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(for: data))
        try? FileManager.default.removeItem(at: url)
        try render(data).write(to: url, options: .atomic)
        return url
    }

    static func render(_ data: SLPReportData) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "\(SLPReportData.appName) communication dictionary report",
            kCGPDFContextCreator as String: SLPReportData.appName,
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize), format: format)
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        let dayFormatter = DateFormatter()
        dayFormatter.setLocalizedDateFormatFromTemplate("d MMM")

        return renderer.pdfData { context in
            let pager = Pager(context: context)
            pager.beginPage()

            // Title block
            pager.draw(Style.title("Communication dictionary report"), spacing: 2)
            pager.draw(Style.small("Prepared \(dateFormatter.string(from: data.generatedAt)) by \(data.preparedBy) with \(SLPReportData.appName). No audio or photos are included."), spacing: 12)

            pager.draw(Style.body("This is a family-trained communication dictionary: each entry is something he communicates — a sound, a word, a phrase or a gesture, labelled in the family's own words — and what the family has confirmed it means. Counts are the family's confirmations, not the app's guesses. Please flag anything to merge, split, rename or add: labels that mean the same thing across caregivers are what make the dictionary learnable."), spacing: 10)

            let wordCount = data.inventory.count
            pager.draw(Style.body("Words in the dictionary: \(wordCount) · confirmed clips: \(data.totalClips)"), spacing: 2)
            if !data.stations.isEmpty {
                pager.draw(Style.body("Listening stations: \(data.stations.joined(separator: ", "))"), spacing: 2)
            }
            if !data.labellers.isEmpty {
                pager.draw(Style.body("Labelled by: \(data.labellers.joined(separator: ", "))"), spacing: 2)
            }
            pager.space(10)

            // Inventory
            pager.draw(Style.heading("What he communicates, most often first"), spacing: 6)
            if data.inventory.isEmpty {
                pager.draw(Style.body("No words yet."), spacing: 6)
            }
            for (index, item) in data.inventory.enumerated() {
                pager.keepTogether(estimatedHeight: 64)
                var headline = "\(index + 1). \(item.label)"
                headline += "   —   \(item.clipCount) confirmed clip\(item.clipCount == 1 ? "" : "s")"
                if item.exchangeCount > 0 {
                    headline += " across \(item.exchangeCount) exchange\(item.exchangeCount == 1 ? "" : "s")"
                }
                headline += ", confirmed \(item.confirmationCount) time\(item.confirmationCount == 1 ? "" : "s")"
                pager.draw(Style.entry(headline), spacing: 1)

                var context: [String] = []
                if !item.typicalTimes.isEmpty {
                    context.append("usually " + item.typicalTimes.joined(separator: " and "))
                }
                if let station = item.typicalStation {
                    context.append("mostly at the \(station) station")
                }
                if let first = item.firstConfirmedAt, let last = item.lastConfirmedAt {
                    context.append("first confirmed \(dateFormatter.string(from: first)), last \(dateFormatter.string(from: last))")
                }
                if context.isEmpty {
                    context.append("not confirmed yet")
                }
                pager.draw(Style.detail(context.joined(separator: " · ").capitalizedFirst), indent: 14, spacing: 1)
                if let note = item.respondNote {
                    pager.draw(Style.detail("How to respond: \(note)"), indent: 14, spacing: 1)
                }
                pager.draw(Style.small("Recognition: \(item.maturity)"), indent: 14, spacing: 7)
            }
            pager.space(6)

            // Growth
            pager.draw(Style.heading("Growth over the last \(data.weeks.count) weeks"), spacing: 4)
            pager.draw(Style.small("Time to understanding is the median gap between the start of an exchange and the family's confirmation. An exchange \"got there\" when it was confirmed, or when he reached the word on his board; \"did not\" when its clips were left unlabelled past a day."), spacing: 6)
            if data.weeks.allSatisfy({ $0.newClips == 0 && $0.exchangesResolved == 0 && $0.exchangesAbandoned == 0 }) {
                pager.draw(Style.body("Nothing recorded in this period yet."), spacing: 6)
            }
            for week in data.weeks {
                var parts: [String] = []
                parts.append("\(week.newClips) new clip\(week.newClips == 1 ? "" : "s")")
                if !week.wordsReachingFive.isEmpty {
                    parts.append("reached \(SLPReportData.clipTarget) clips: \(week.wordsReachingFive.joined(separator: ", "))")
                }
                if let ms = week.medianLatencyMs {
                    parts.append("time to understanding \(Self.seconds(ms))")
                }
                let total = week.exchangesResolved + week.exchangesAbandoned
                if total > 0 {
                    parts.append("exchanges that got there: \(week.exchangesResolved) of \(total)")
                }
                pager.draw(Style.body("Week of \(dayFormatter.string(from: week.weekStart)):  " + parts.joined(separator: " · ")), indent: 0, spacing: 3)
            }
        }
    }

    private static func seconds(_ ms: Int) -> String {
        let seconds = Double(ms) / 1000
        if seconds < 60 { return String(format: "%.0f s", seconds) }
        return String(format: "%.1f min", seconds / 60)
    }

    // MARK: Typography

    private enum Style {
        static func make(_ text: String, font: UIFont, color: UIColor = .black) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            return NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ])
        }

        static func title(_ t: String) -> NSAttributedString { make(t, font: .boldSystemFont(ofSize: 20)) }
        static func heading(_ t: String) -> NSAttributedString { make(t, font: .boldSystemFont(ofSize: 14)) }
        static func entry(_ t: String) -> NSAttributedString { make(t, font: .boldSystemFont(ofSize: 11)) }
        static func body(_ t: String) -> NSAttributedString { make(t, font: .systemFont(ofSize: 11)) }
        static func detail(_ t: String) -> NSAttributedString { make(t, font: .systemFont(ofSize: 10.5), color: .darkGray) }
        static func small(_ t: String) -> NSAttributedString { make(t, font: .systemFont(ofSize: 9.5), color: .darkGray) }
    }

    // MARK: Pagination

    /// Row-by-row cursor with automatic page breaks. Every page gets the
    /// header line inside the top margin and the footer with the page
    /// number inside the bottom margin.
    private final class Pager {
        let context: UIGraphicsPDFRendererContext
        let content: CGRect
        private(set) var y: CGFloat = 0
        private(set) var pageNumber = 0

        private let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

        init(context: UIGraphicsPDFRendererContext) {
            self.context = context
            self.content = CGRect(
                x: SLPReport.margin,
                y: SLPReport.margin,
                width: SLPReport.pageSize.width - 2 * SLPReport.margin,
                height: SLPReport.pageSize.height - 2 * SLPReport.margin
            )
        }

        func beginPage() {
            context.beginPage()
            pageNumber += 1
            y = content.minY

            let header = Style.small("\(SLPReportData.appName) · communication dictionary report")
            header.draw(with: CGRect(x: content.minX, y: 12, width: content.width, height: 14), options: options, context: nil)

            let footer = Style.small("\(SLPReport.footerText) · Page \(pageNumber)")
            let footerHeight = ceil(footer.boundingRect(
                with: CGSize(width: content.width, height: .greatestFiniteMagnitude),
                options: options, context: nil).height)
            footer.draw(with: CGRect(
                x: content.minX,
                y: SLPReport.pageSize.height - 12 - footerHeight,
                width: content.width,
                height: footerHeight
            ), options: options, context: nil)
        }

        /// Draws one row at the cursor, breaking the page first if the
        /// row does not fit. A single row taller than a page is drawn
        /// from the top of a fresh page and clipped — only a pathological
        /// respond note could do that.
        func draw(_ text: NSAttributedString, indent: CGFloat = 0, spacing: CGFloat = 4) {
            let width = max(1, content.width - indent)
            let height = ceil(text.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: options, context: nil).height)
            if y + height > content.maxY, y > content.minY {
                beginPage()
            }
            text.draw(with: CGRect(x: content.minX + indent, y: y, width: width, height: height),
                      options: options, context: nil)
            y += height + spacing
        }

        func space(_ height: CGFloat) {
            y = min(y + height, content.maxY)
        }

        /// Starts a new page when fewer than `estimatedHeight` points
        /// remain, so an entry's headline is not orphaned at the bottom.
        func keepTogether(estimatedHeight: CGFloat) {
            if y + estimatedHeight > content.maxY, y > content.minY {
                beginPage()
            }
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
