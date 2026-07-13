import Accelerate
import Foundation

/// Fixed-vector audio embedding (§5.1). Phase 2's live implementation is
/// the WhisperKit encoder (WhisperKitEmbedder); tests use fixture vectors
/// directly against the ranker and never touch this protocol.
protocol EmbeddingProvider {
    /// Embedding dimension this provider produces.
    var dimension: Int { get }
    /// 16 kHz mono samples → L2-normalized fixed vector.
    func embed(samples: [Float]) async throws -> [Float]
}

/// Blob codec for embedding storage: little-endian Float32, no header.
enum EmbeddingCodec {
    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        var vector = [Float](repeating: 0, count: count)
        _ = vector.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return vector
    }
}

enum VectorMath {
    /// Cosine similarity via Accelerate (§5.7). For pre-normalized vectors
    /// this is just the dot product, but we normalize defensively.
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var magA: Float = 0
        var magB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &magA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &magB, vDSP_Length(b.count))
        let denominator = (magA * magB).squareRoot()
        guard denominator > 0 else { return 0 }
        return Double(dot / denominator)
    }

    static func l2Normalized(_ vector: [Float]) -> [Float] {
        var squared: Float = 0
        vDSP_svesq(vector, 1, &squared, vDSP_Length(vector.count))
        let norm = squared.squareRoot()
        guard norm > 0 else { return vector }
        var result = [Float](repeating: 0, count: vector.count)
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
        return result
    }

    /// Element-wise mean of equal-length vectors, re-normalized — used to
    /// pool one exchange's segment embeddings into a single query, on the
    /// §4.2 theory that he repeated the same intent through the no's.
    static func meanPooled(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors where vector.count == first.count {
            vDSP_vadd(sum, 1, vector, 1, &sum, 1, vDSP_Length(first.count))
        }
        var divisor = Float(vectors.count)
        vDSP_vsdiv(sum, 1, &divisor, &sum, 1, vDSP_Length(first.count))
        return l2Normalized(sum)
    }
}
