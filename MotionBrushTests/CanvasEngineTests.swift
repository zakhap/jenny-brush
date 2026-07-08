import XCTest
@testable import MotionBrush

/// §14 test #1 — Stamper determinism: a fixed polyline + fixed brush (synthetic
/// frame widths) must produce an exact expected stamp list, including residual
/// carry-over across multiple `consume` calls and frame-index wraparound.
/// Also covers E8 (tap-without-drag → single frame-0 stamp).
final class CanvasEngineTests: XCTestCase {

    /// Frames sized so spacing = width * K.spacingFactor == 4 px each, constant —
    /// derived from the tunable so these exact-value assertions stay valid when
    /// K.spacingFactor is retuned for feel.
    private static let spacing4Width = 4 / K.spacingFactor
    private func uniformBrush(width: CGFloat = spacing4Width, count: Int = 3) -> StamperBrush {
        StamperBrush(frames: Array(repeating: StamperBrushFrame(width: width), count: count))
    }

    // MARK: - Single straight segment, exact stamp positions

    func testSingleSegmentProducesExpectedSpacingAndFrames() {
        let brush = uniformBrush() // spacing = 4
        var stamper = Stamper()
        stamper.resetForNewStroke()

        // A single 20px horizontal segment: stamps expected at x = 4, 8, 12, 16, 20.
        let polyline = [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0)]
        let stamps = stamper.consume(polyline: polyline, brush: brush)

        let expected: [Stamp] = [
            Stamp(center: CGPoint(x: 4, y: 0), frame: 0),
            Stamp(center: CGPoint(x: 8, y: 0), frame: 1),
            Stamp(center: CGPoint(x: 12, y: 0), frame: 2),
            Stamp(center: CGPoint(x: 16, y: 0), frame: 0), // wraparound: frame 2 -> 0
            Stamp(center: CGPoint(x: 20, y: 0), frame: 1),
        ]
        XCTAssertEqual(stamps, expected)
        XCTAssertEqual(stamper.frameIdx, 2) // next stamp would be frame 2
        XCTAssertEqual(stamper.residual, 0, accuracy: 1e-9)
    }

    // MARK: - Residual carry-over across multiple `consume` calls

    func testResidualCarriesOverAcrossConsumeCalls() {
        let brush = uniformBrush() // spacing = 4
        var stamper = Stamper()
        stamper.resetForNewStroke()

        // First batch: 0 -> 10 (one segment). Stamps at 4, 8. Residual after = 2.
        let firstBatchStamps = stamper.consume(polyline: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)], brush: brush)
        XCTAssertEqual(firstBatchStamps, [
            Stamp(center: CGPoint(x: 4, y: 0), frame: 0),
            Stamp(center: CGPoint(x: 8, y: 0), frame: 1),
        ])
        XCTAssertEqual(stamper.residual, 2, accuracy: 1e-9)
        XCTAssertEqual(stamper.frameIdx, 2)

        // Second batch, a fresh segment continuing from the same point: 10 -> 16.
        // residual=2 carries in: next stamp at local distance (spacing - residual) = 2 -> canvas x = 12.
        // Then next stamp at local distance 2+4=6 -> canvas x = 16.
        let secondBatchStamps = stamper.consume(polyline: [CGPoint(x: 10, y: 0), CGPoint(x: 16, y: 0)], brush: brush)
        XCTAssertEqual(secondBatchStamps, [
            Stamp(center: CGPoint(x: 12, y: 0), frame: 2),
            Stamp(center: CGPoint(x: 16, y: 0), frame: 0), // wraparound
        ])
        XCTAssertEqual(stamper.residual, 0, accuracy: 1e-9)
        XCTAssertEqual(stamper.frameIdx, 1)
    }

    // MARK: - Frame-index wraparound across a longer multi-cycle stroke

    func testFrameIndexWrapsForwardAcrossMultipleCycles() {
        let brush = uniformBrush(width: Self.spacing4Width, count: 2) // spacing = 4, 2 frames
        var stamper = Stamper()
        stamper.resetForNewStroke()

        // 0 -> 40: 10 stamps at 4,8,...,40. Frames cycle 0,1,0,1,...
        let stamps = stamper.consume(polyline: [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0)], brush: brush)
        XCTAssertEqual(stamps.count, 10)
        for (i, stamp) in stamps.enumerated() {
            XCTAssertEqual(stamp.center.x, CGFloat((i + 1) * 4), accuracy: 1e-9)
            XCTAssertEqual(stamp.frame, i % 2)
        }
    }

    // MARK: - Per-stroke reset (FR-20)

    func testResetForNewStrokeClearsResidualAndFrameIndex() {
        let brush = uniformBrush()
        var stamper = Stamper()
        stamper.resetForNewStroke()
        _ = stamper.consume(polyline: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)], brush: brush)
        XCTAssertNotEqual(stamper.frameIdx, 0)

        stamper.resetForNewStroke()
        XCTAssertEqual(stamper.frameIdx, 0)
        XCTAssertEqual(stamper.residual, 0, accuracy: 1e-9)
    }

    // MARK: - E8: tap without drag places a single frame-0 stamp

    func testTapWithoutDragEmitsSingleFrameZeroStamp() {
        let stamper = Stamper()
        let stamp = stamper.tapStamp(at: CGPoint(x: 42, y: 17))
        XCTAssertEqual(stamp, Stamp(center: CGPoint(x: 42, y: 17), frame: 0))
    }

    func testStrokeBuilderTapWithoutDragEmitsSingleFrameZeroStamp() {
        let brush = uniformBrush()
        let builder = StrokeBuilder(brush: brush)
        builder.begin(at: CGPoint(x: 5, y: 5))
        // No addPoints call at all — a pure tap.
        let final = builder.end()
        XCTAssertEqual(final, [Stamp(center: CGPoint(x: 5, y: 5), frame: 0)])
    }

    // MARK: - Zero-length segments are skipped without breaking residual accounting

    func testZeroLengthSegmentIsSkipped() {
        let brush = uniformBrush()
        var stamper = Stamper()
        stamper.resetForNewStroke()
        let polyline = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0)]
        let stamps = stamper.consume(polyline: polyline, brush: brush)
        XCTAssertEqual(stamps, [Stamp(center: CGPoint(x: 4, y: 0), frame: 0)])
    }
}
