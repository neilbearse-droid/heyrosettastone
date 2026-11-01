import Foundation
import NaturalLanguage

/// Near-duplicate label detection for the setup interview (§4.1).
/// Inconsistent labels across caregivers poison the classes, so we flag
/// string-near labels ("bannana" vs "banana"), inflected and multi-word
/// forms ("snacks" vs "snack", "want food" vs "hungry"), known same-concept
/// pairs, and — as a fallback — words the on-device English word embedding
/// places close together. The family decides; a false flag costs one tap,
/// so the matcher leans toward flagging, but not for 3-letter words where
/// one edit changes the meaning ("dad" vs "mad").
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

    /// Function words that carry no intent on their own. "more" is also a
    /// cluster member; when stripping leaves nothing, the raw tokens are
    /// used instead so "more" vs "again" still matches.
    static let stopwords: Set<String> = [
        "want", "go", "my", "the", "a", "please", "time", "more",
        "i", "to", "me", "some", "an", "it",
    ]

    /// Minimum normalized label length for a single-edit misspelling match.
    static let minLengthForEditMatch = 5
    /// Tokens shorter than this never use the semantic fallback: word
    /// embeddings are noisy for very short words.
    static let minLengthForSemanticMatch = 4
    /// NLEmbedding cosine distance (0 = identical, 2 = opposite) at or below
    /// which two single words are treated as the same concept. Tunable.
    static var semanticDistanceCutoff: Double = 0.6

    /// On-device English word embedding (no network); nil on systems
    /// without the asset.
    private static let englishEmbedding: NLEmbedding? = NLEmbedding.wordEmbedding(for: .english)

    static func normalize(_ label: String) -> String {
        label.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
    }

    /// Lowercased, punctuation-free, stopwords removed, trailing "s"
    /// stripped from plural-looking tokens.
    static func tokens(_ label: String) -> [String] {
        let raw = normalize(label)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        let content = raw.filter { !stopwords.contains($0) }
        let kept = content.isEmpty ? raw : content
        return kept.map(stem)
    }

    static func stem(_ token: String) -> String {
        guard token.count >= 4, token.hasSuffix("s"), !token.hasSuffix("ss") else { return token }
        return String(token.dropLast())
    }

    /// True when two labels are likely the same intent worded differently.
    static func areNearDuplicates(_ a: String, _ b: String) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }

        let ta = tokens(a)
        let tb = tokens(b)
        let ja = ta.joined(separator: " ")
        let jb = tb.joined(separator: " ")
        guard !ja.isEmpty, !jb.isEmpty else { return false }
        if ja == jb { return true }

        // One label contained in the other ("bath" vs "bathroom").
        if ja.count > 3, jb.count > 3, (ja.contains(jb) || jb.contains(ja)) { return true }

        // Small edit distance relative to length catches misspellings —
        // but a single edit on a short word usually changes the meaning
        // ("dad" vs "mad"), so distance-1 matches need some length.
        let distance = levenshtein(ja, jb)
        let shorter = min(ja.count, jb.count)
        let threshold = max(1, shorter / 4)
        if distance <= threshold, !(distance == 1 && shorter < minLengthForEditMatch) {
            return true
        }

        // Same concept cluster catches synonyms, per token and per label.
        let candidatesA = Set(ta + [ja])
        let candidatesB = Set(tb + [jb])
        for cluster in conceptClusters {
            let members = Set(cluster)
            if !members.isDisjoint(with: candidatesA), !members.isDisjoint(with: candidatesB) {
                return true
            }
        }

        // Semantic fallback: on-device word embedding distance.
        return semanticallyClose(ta, tb)
    }

    /// Any single-word pair across the two token lists closer than the
    /// cutoff in the English word embedding.
    static func semanticallyClose(_ ta: [String], _ tb: [String]) -> Bool {
        guard let embedding = englishEmbedding else { return false }
        for wa in ta where wa.count >= minLengthForSemanticMatch && embedding.contains(wa) {
            for wb in tb where wb.count >= minLengthForSemanticMatch && wb != wa && embedding.contains(wb) {
                let distance = embedding.distance(between: wa, and: wb)
                if distance.isFinite, distance <= semanticDistanceCutoff {
                    return true
                }
            }
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
