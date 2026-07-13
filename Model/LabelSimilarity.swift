import Foundation

/// Near-duplicate label detection for the setup interview (§4.1).
/// Inconsistent labels across caregivers poison the classes, so we flag both
/// string-near labels ("bannana" vs "banana") and known same-concept pairs
/// ("snack" vs "hungry") and ask the family to merge or keep.
enum LabelSimilarity {
    /// Concept clusters that different caregivers commonly label differently.
    /// Membership in the same cluster flags a pair for review; the family
    /// decides. Extend freely — a false flag costs one tap.
    static let conceptClusters: [[String]] = [
        ["snack", "hungry", "food", "eat", "eating"],
        ["drink", "thirsty", "water", "juice", "cup"],
        ["bathroom", "toilet", "potty", "pee", "washroom"],
        ["outside", "out", "walk", "park"],
        ["sleep", "tired", "bed", "nap"],
        ["hurt", "pain", "ouch", "sore"],
        ["mom", "mommy", "mum", "mummy", "mama"],
        ["dad", "daddy", "papa"],
        ["more", "again"],
        ["done", "finished", "all done", "stop"],
        ["help", "help me"],
        ["tv", "show", "video", "screen", "tablet", "ipad"],
    ]

    static func normalize(_ label: String) -> String {
        label.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
    }

    /// True when two labels are likely the same intent worded differently.
    static func areNearDuplicates(_ a: String, _ b: String) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        if na.count > 3, nb.count > 3, (na.contains(nb) || nb.contains(na)) { return true }

        // Small edit distance relative to length catches misspellings.
        let distance = levenshtein(na, nb)
        let threshold = max(1, min(na.count, nb.count) / 4)
        if distance <= threshold { return true }

        // Same concept cluster catches synonyms.
        for cluster in conceptClusters {
            let inA = cluster.contains(na)
            let inB = cluster.contains(nb)
            if inA && inB { return true }
        }
        return false
    }

    /// Labels in `existing` that near-duplicate `candidate`.
    static func conflicts(for candidate: String, in existing: [String]) -> [String] {
        existing.filter { areNearDuplicates(candidate, $0) }
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let sa = Array(a), sb = Array(b)
        if sa.isEmpty { return sb.count }
        if sb.isEmpty { return sa.count }
        var previous = Array(0...sb.count)
        var current = [Int](repeating: 0, count: sb.count + 1)
        for i in 1...sa.count {
            current[0] = i
            for j in 1...sb.count {
                let cost = sa[i - 1] == sb[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[sb.count]
    }
}
