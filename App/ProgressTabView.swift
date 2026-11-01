import Charts
import SwiftUI

/// Progress (§3, §7 tone): celebrates the family's accumulated knowledge —
/// words, confirmed clips, exchanges that got there, and time-to-
/// understanding falling. Never a streak, never a score pointed at him.
/// Per-word ML maturity joins in Phase 2 (§5.6).
@MainActor
struct ProgressTabView: View {
    @Environment(AppEnvironment.self) private var env

    struct WordRow: Identifiable {
        /// The intent id — labels may legitimately repeat ("keep both" in
        /// setup), so they cannot key the list (D9).
        let id: String
        let label: String
        let count: Int
        let maturity: MaturityGate.Report?
        /// How the word fared when the model was guessing (last 30 days);
        /// nil when it was never among the guesses or the answer.
        let accuracy: LiveAccuracy.IntentAccuracy?
        /// Times since launch the family confirmed this word after the
        /// model had declined it as not sounding like itself enough.
        let floorMisses: Int
    }

    /// Window for the exchange-outcome card and the latency trend.
    private static let window: TimeInterval = 30 * 24 * 3600

    @State private var totalExemplars = 0
    @State private var wordCount = 0
    @State private var perIntent: [WordRow] = []
    @State private var latencyTrend: [(day: Date, medianMs: Int)] = []
    @State private var resolvedExchanges = 0
    @State private var abandonedExchanges = 0
    @State private var abandonedRate: Double?
    @State private var accuracy: LiveAccuracy.Summary = .empty

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        statCard(value: "\(wordCount)", caption: "words in his dictionary")
                        statCard(value: "\(totalExemplars)", caption: "clips the family has labelled")
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                // §2.9's second metric, framed as what the family achieved
                // (D3). Sessions still inside their Review window are
                // neither resolved nor abandoned and are left out.
                if resolvedExchanges + abandonedExchanges > 0 {
                    Section {
                        statCard(
                            value: "\(resolvedExchanges) of \(resolvedExchanges + abandonedExchanges)",
                            caption: "exchanges that got there in the last 30 days"
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                    } footer: {
                        if let abandonedRate {
                            Text("Got there means confirmed on the card, resolved on his board, or labelled in Review within a day. Exchanges that turned out to be someone else are left out. \(Int((abandonedRate * 100).rounded()))% went unresolved; those are the ones to catch sooner next time.")
                        }
                    }
                }

                // The Phase 2 acceptance criterion (§9), measured on real
                // confirmations rather than on the model's own clips. Only
                // exchanges where guesses were shown AND a word was
                // confirmed count; the model's silences are counted by the
                // floor-miss lines below.
                if accuracy.exchangesWithGuesses > 0 {
                    Section {
                        statCard(
                            value: "\(accuracy.confirmedWordShown) of \(accuracy.exchangesWithGuesses)",
                            caption: "times his word was in the top 3 when it guessed (last 30 days)"
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                    } footer: {
                        Text("Counted on exchanges where the model offered guesses and you then confirmed a word. \(accuracy.confirmedWordWasTop) of those had his word as the first guess. Every confirmation, right or wrong, sharpens the next one.")
                    }
                }

                if !latencyTrend.isEmpty {
                    Section {
                        Chart(latencyTrend, id: \.day) { point in
                            LineMark(
                                x: .value("Day", point.day),
                                y: .value("Seconds", Double(point.medianMs) / 1000)
                            )
                            PointMark(
                                x: .value("Day", point.day),
                                y: .value("Seconds", Double(point.medianMs) / 1000)
                            )
                        }
                        .frame(height: 180)
                        .padding(.vertical, 8)
                        .accessibilityLabel("Median seconds to understanding per day")
                    } header: {
                        Text("Time to understanding")
                    } footer: {
                        Text("Median seconds from his first word in an exchange to your confirmation, per day. Down means the guessing is getting shorter.")
                    }
                }

                Section {
                    ForEach(perIntent) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.label)
                                Text(maturityCaption(row))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let note = floorMissCaption(row) {
                                    Text(note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(row.count) clip\(row.count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            maturityBadge(row)
                        }
                    }
                } header: {
                    Text("What the model knows, word by word")
                } footer: {
                    Text(env.suggestions.isModelAvailable
                        ? maturityFooter
                        : "Guessing is off — no recognition model is bundled in this build. Every confirmation still counts; guesses appear the moment a model is added.")
                }
            }
            .navigationTitle("Progress")
            .onAppear(perform: reload)
        }
    }

    private func statCard(value: String, caption: String) -> some View {
        VStack(spacing: 4) {
            // Dynamic Type-relative (D9), rounded for the celebratory tone.
            Text(value)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    // §5.6: per-word maturity, so the family sees exactly which words the
    // model knows and which need more confirmations. Framed around the
    // family's accumulated knowledge, never as a score for him (§7 tone).
    private func maturityCaption(_ row: WordRow) -> String {
        guard env.suggestions.isModelAvailable else { return "counting confirmations" }
        guard let report = row.maturity else { return "counting confirmations" }
        if report.isSuggestible {
            let pct = Int(((report.looTop3HitRate ?? 0) * 100).rounded())
            var caption = "guessing live — recognizes \(pct)% of its own clips"
            if let note = selfSimilarityNote(report) {
                caption += "; \(note)"
            }
            if let suffix = accuracySuffix(row.accuracy) {
                caption += " — \(suffix)"
            }
            return caption
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

    /// "guessed right 3 of 4": of the confirmed exchanges where this word
    /// was among the guesses, how often it was the answer. Nil until the
    /// word has been shown at least once.
    private func accuracySuffix(_ accuracy: LiveAccuracy.IntentAccuracy?) -> String? {
        guard let accuracy, accuracy.shown > 0 else { return nil }
        return "guessed right \(accuracy.confirmedWhenShown) of \(accuracy.shown)"
    }

    /// Only when it reads naturally: a tight cluster or a visibly varied
    /// one; the middle band says nothing. Bounds are tunable; real encoder
    /// cosines sit in a narrow band (≈ 0.80–0.95), so these are the tails.
    private static let tightSelfSimilarity = 0.92
    private static let variedSelfSimilarity = 0.80

    private func selfSimilarityNote(_ report: MaturityGate.Report) -> String? {
        guard let typical = report.typicalSelfSimilarity else { return nil }
        if typical >= Self.tightSelfSimilarity { return "its clips match each other closely" }
        if typical <= Self.variedSelfSimilarity { return "his way of saying it varies" }
        return nil
    }

    /// The floor was stricter than his variability: the family confirmed
    /// the word the model had declined. Counted, never auto-applied
    /// (§2.2); the confirmation itself is what widens the floor next pass.
    private func floorMissCaption(_ row: WordRow) -> String? {
        guard row.floorMisses > 0 else { return nil }
        let times = row.floorMisses == 1 ? "once" : "\(row.floorMisses) times"
        return "his say of “\(row.label)” varied more than the model expected \(times) — more confirmations will widen it"
    }

    /// The gate's numbers, read from the config so the footer can never
    /// drift from what the model actually requires.
    private var maturityFooter: String {
        let config = MaturityGate.Config()
        return "A word starts getting guessed once it has \(config.minExemplars) confirmed clips from \(config.minSessions) different exchanges and the model recognizes its own examples reliably. More confirmations always help."
    }

    @ViewBuilder
    private func maturityBadge(_ row: WordRow) -> some View {
        if row.maturity?.isSuggestible == true {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.tint)
                .accessibilityLabel("Being suggested")
        }
    }

    private func reload() {
        let intents = (try? env.intents.all()) ?? []
        wordCount = intents.count
        totalExemplars = (try? env.exemplars.totalCount()) ?? 0
        var reports: [String: MaturityGate.Report] = [:]
        for report in env.suggestions.maturityReports {
            reports[report.intentId] = report
        }
        let since = Date().addingTimeInterval(-Self.window)
        accuracy = (try? LiveAccuracy.summary(db: env.db, since: since)) ?? .empty
        var accuracyByIntent: [String: LiveAccuracy.IntentAccuracy] = [:]
        for row in accuracy.perIntent {
            accuracyByIntent[row.intentId] = row
        }
        perIntent = intents
            .map { intent in
                WordRow(
                    id: intent.id,
                    label: intent.label,
                    count: (try? env.exemplars.count(intentId: intent.id)) ?? 0,
                    maturity: reports[intent.id],
                    accuracy: accuracyByIntent[intent.id],
                    floorMisses: env.suggestions.floorMisses(for: intent.id)
                )
            }
            .sorted { $0.count > $1.count }

        latencyTrend = (try? env.events.confirmLatencies(since: since)) ?? []
        if let outcomes = try? env.events.exchangeOutcomes(since: since) {
            resolvedExchanges = outcomes.resolved
            abandonedExchanges = outcomes.abandoned
        } else {
            resolvedExchanges = 0
            abandonedExchanges = 0
        }
        abandonedRate = try? env.events.abandonedRate(since: since)
    }
}
