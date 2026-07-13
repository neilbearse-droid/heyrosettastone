import Charts
import SwiftUI

/// Progress (§3, §7 tone): celebrates the family's accumulated knowledge —
/// words, confirmed clips, and time-to-understanding falling. Never a
/// streak, never a score pointed at him. Per-word ML maturity joins in
/// Phase 2 (§5.6).
struct ProgressTabView: View {
    @Environment(AppEnvironment.self) private var env

    struct WordRow {
        let label: String
        let count: Int
        let maturity: MaturityGate.Report?
    }

    @State private var totalExemplars = 0
    @State private var wordCount = 0
    @State private var perIntent: [WordRow] = []
    @State private var latencyTrend: [(day: Date, medianMs: Int)] = []

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
                    } header: {
                        Text("Time to understanding")
                    } footer: {
                        Text("Median seconds from his first word in an exchange to your confirmation, per day. Down means the guessing is getting shorter.")
                    }
                }

                Section {
                    ForEach(perIntent, id: \.label) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.label)
                                Text(maturityCaption(row))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                        ? "A word starts getting guessed once it has 5 confirmed clips and the model recognizes its own examples reliably. More confirmations always help."
                        : "Guessing is off — no recognition model is bundled in this build. Every confirmation still counts; guesses appear the moment a model is added.")
                }
            }
            .navigationTitle("Progress")
            .onAppear(perform: reload)
        }
    }

    private func statCard(value: String, caption: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 40, weight: .bold, design: .rounded))
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
            return "guessing live — recognizes \(pct)% of its own clips"
        }
        if report.exemplarCount < MaturityGate.Config().minExemplars {
            return "learning — \(report.exemplarCount) of \(MaturityGate.Config().minExemplars) clips needed"
        }
        return "needs more varied clips before guessing"
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
        let reports = Dictionary(
            uniqueKeysWithValues: env.suggestions.maturityReports.map { ($0.intentId, $0) }
        )
        perIntent = intents
            .map { intent in
                WordRow(
                    label: intent.label,
                    count: (try? env.exemplars.count(intentId: intent.id)) ?? 0,
                    maturity: reports[intent.id]
                )
            }
            .sorted { $0.count > $1.count }
        let monthAgo = Date().addingTimeInterval(-30 * 24 * 3600)
        latencyTrend = (try? env.events.confirmLatencies(since: monthAgo)) ?? []
    }
}
