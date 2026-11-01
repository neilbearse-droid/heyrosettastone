import CoreML
import XCTest
@testable import Rosetta

/// `WhisperKitEmbedder.meanPool` is the only code that touches the
/// encoder's (1, dim, 1, frames) layout and the padded-30-s-window
/// pitfall: it must read through the array's strides and pool only over
/// the frames that carry real audio.
final class MeanPoolTests: XCTestCase {
    private let dim = 3
    private let frames = 4

    /// Value stored at (d, f): d·10 + f, so means are easy to predict.
    private func value(_ d: Int, _ f: Int) -> Float { Float(d * 10 + f) }

    private func contiguousArray(dataType: MLMultiArrayDataType) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, dim, 1, frames] as [NSNumber], dataType: dataType)
        for d in 0..<dim {
            for f in 0..<frames {
                array[[0, d, 0, f] as [NSNumber]] = NSNumber(value: value(d, f))
            }
        }
        return array
    }

    func testPoolsOnlyOverMaxFrames() throws {
        let array = try contiguousArray(dataType: .float32)
        let pooled = try WhisperKitEmbedder.meanPool(encoderOutput: array, maxFrames: 2)
        XCTAssertEqual(pooled.count, dim)
        // (d·10 + 0 + d·10 + 1) / 2
        XCTAssertEqual(pooled[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(pooled[1], 10.5, accuracy: 1e-6)
        XCTAssertEqual(pooled[2], 20.5, accuracy: 1e-6)
    }

    func testMaxFramesIsClampedToTheArray() throws {
        let array = try contiguousArray(dataType: .float32)
        let pooled = try WhisperKitEmbedder.meanPool(encoderOutput: array, maxFrames: 1_500)
        // Mean over all four frames: d·10 + 1.5
        XCTAssertEqual(pooled[0], 1.5, accuracy: 1e-6)
        XCTAssertEqual(pooled[1], 11.5, accuracy: 1e-6)
        XCTAssertEqual(pooled[2], 21.5, accuracy: 1e-6)

        let atLeastOne = try WhisperKitEmbedder.meanPool(encoderOutput: array, maxFrames: 0)
        XCTAssertEqual(atLeastOne[1], 10, accuracy: 1e-6, "zero frames still pools the first frame")
    }

    func testReadsThroughNonContiguousStrides() throws {
        // Frame-major storage: element (d, f) lives at f·dim + d. A reader
        // that assumed C-order on the shape would read garbage.
        let count = dim * frames
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { pointer.deallocate() }
        for d in 0..<dim {
            for f in 0..<frames {
                pointer[f * dim + d] = value(d, f)
            }
        }
        let array = try MLMultiArray(
            dataPointer: UnsafeMutableRawPointer(pointer),
            shape: [1, dim, 1, frames] as [NSNumber],
            dataType: .float32,
            strides: [count, 1, count, dim] as [NSNumber],
            deallocator: nil
        )
        let pooled = try WhisperKitEmbedder.meanPool(encoderOutput: array, maxFrames: 2)
        XCTAssertEqual(pooled[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(pooled[1], 10.5, accuracy: 1e-6)
        XCTAssertEqual(pooled[2], 20.5, accuracy: 1e-6)
    }

    func testFloat16Storage() throws {
        // Values exactly representable in half precision.
        let array = try MLMultiArray(shape: [1, dim, 1, frames] as [NSNumber], dataType: .float16)
        for d in 0..<dim {
            for f in 0..<frames {
                array[[0, d, 0, f] as [NSNumber]] = NSNumber(value: Float(d) + 0.5 * Float(f))
            }
        }
        XCTAssertEqual(array.dataType, .float16)
        let pooled = try WhisperKitEmbedder.meanPool(encoderOutput: array, maxFrames: 3)
        // (d + 0 + d + 0.5 + d + 1.0) / 3 = d + 0.5
        XCTAssertEqual(pooled[0], 0.5, accuracy: 1e-3)
        XCTAssertEqual(pooled[1], 1.5, accuracy: 1e-3)
        XCTAssertEqual(pooled[2], 2.5, accuracy: 1e-3)
    }

    func testRejectsUnexpectedShapes() throws {
        let threeDim = try MLMultiArray(shape: [1, dim, frames] as [NSNumber], dataType: .float32)
        XCTAssertThrowsError(try WhisperKitEmbedder.meanPool(encoderOutput: threeDim, maxFrames: 2))

        let batched = try MLMultiArray(shape: [2, dim, 1, frames] as [NSNumber], dataType: .float32)
        XCTAssertThrowsError(try WhisperKitEmbedder.meanPool(encoderOutput: batched, maxFrames: 2))

        let doubles = try MLMultiArray(shape: [1, dim, 1, frames] as [NSNumber], dataType: .double)
        XCTAssertThrowsError(try WhisperKitEmbedder.meanPool(encoderOutput: doubles, maxFrames: 2),
                             "only float32 / float16 encoder outputs are understood")
    }

    func testEncoderWidthPerCheckpoint() {
        XCTAssertEqual(WhisperKitEmbedder.encoderWidth(forModelNamed: "openai_whisper-tiny"), 384)
        XCTAssertEqual(WhisperKitEmbedder.encoderWidth(forModelNamed: "openai_whisper-base"), 512)
        XCTAssertEqual(WhisperKitEmbedder.encoderWidth(forModelNamed: "openai_whisper-small"), 768)
    }
}
