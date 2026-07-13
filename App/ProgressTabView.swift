import Charts
import SwiftUI

/// Progress (§3, §7 tone): celebrates the family's accumulated knowledge —
/// words, confirmed clips, and time-to-understanding falling. Never a
/// streak, never a score pointed at him. Per-word ML maturity joins in
/// Phase 2 (§5.6).
struct ProgressTabView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var totalExemplars = 0
    @State private var wordCount = 0
    @State private var perIntent: [(label: String, count: Int)] = []
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
                            Text(row.label)
                            Spacer()
                            Text("\(row.count) clip\(row.count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("Clips per word")
                } footer: {
                    Text("Words with more confirmed clips will be the first the app can help guess, once guessing arrives. Around 5 to 15 per word is the useful range.")
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

    private func reload() {
        let intents = (try? env.intents.all()) ?? []
        wordCount = intents.count
        totalExemplars = (try? env.exemplars.totalCount()) ?? 0
        perIntent = intents
            .map { (label: $0.label, count: (try? env.exemplars.count(intentId: $0.id)) ?? 0) }
            .sorted { $0.count > $1.count }
        let monthAgo = Date().addingTimeInterval(-30 * 24 * 3600)
        latencyTrend = (try? env.events.confirmLatencies(since: monthAgo)) ?? []
    }
}
