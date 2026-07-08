import XCTest
@testable import MotionBrush

/// The Simulator has no camera, so this only exercises what's reachable in
/// isolation: the pure clamp/progress helpers (`CaptureMath`) that back FR-2/FR-3,
/// and that instantiating `CaptureService` on the Simulator doesn't crash.
/// No real capture is attempted (see §14).
@MainActor
final class CaptureServiceTests: XCTestCase {

    // MARK: - CaptureMath.progress (FR-3: progress ring toward K.maxClipSec)

    func testProgressAtStartIsZero() {
        XCTAssertEqual(CaptureMath.progress(elapsed: 0, maxClipSec: K.maxClipSec), 0)
    }

    func testProgressAtHalfway() {
        let half = K.maxClipSec / 2
        XCTAssertEqual(
            CaptureMath.progress(elapsed: half, maxClipSec: K.maxClipSec),
            0.5,
            accuracy: 0.0001
        )
    }

    func testProgressAtCapIsOne() {
        XCTAssertEqual(CaptureMath.progress(elapsed: K.maxClipSec, maxClipSec: K.maxClipSec), 1)
    }

    func testProgressClampsAboveOneWhenOvershooting() {
        // A late timer tick right before auto-stop tears things down shouldn't
        // report more than 100%.
        XCTAssertEqual(CaptureMath.progress(elapsed: K.maxClipSec + 1, maxClipSec: K.maxClipSec), 1)
    }

    func testProgressNeverNegative() {
        XCTAssertEqual(CaptureMath.progress(elapsed: -5, maxClipSec: K.maxClipSec), 0)
    }

    func testProgressWithZeroMaxDoesNotDivideByZero() {
        XCTAssertEqual(CaptureMath.progress(elapsed: 1, maxClipSec: 0), 0)
    }

    // MARK: - CaptureMath.isTooShort (FR-2: clips < K.minClipSec are discarded)

    func testJustUnderMinIsTooShort() {
        XCTAssertTrue(CaptureMath.isTooShort(duration: K.minClipSec - 0.01, minClipSec: K.minClipSec))
    }

    func testExactlyMinIsNotTooShort() {
        XCTAssertFalse(CaptureMath.isTooShort(duration: K.minClipSec, minClipSec: K.minClipSec))
    }

    func testWellAboveMinIsNotTooShort() {
        XCTAssertFalse(CaptureMath.isTooShort(duration: K.maxClipSec, minClipSec: K.minClipSec))
    }

    func testZeroDurationIsTooShort() {
        XCTAssertTrue(CaptureMath.isTooShort(duration: 0, minClipSec: K.minClipSec))
    }

    // MARK: - CaptureService instantiation (must not crash on a cameraless Simulator)

    func testInstantiationDoesNotCrash() {
        let service = CaptureService()
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(service.recordProgress, 0)
        // authStatus reflects whatever the Simulator's TCC db reports; just assert
        // it's one of the three contract values (compiler already enforces this via
        // the enum, but exercise the property read).
        _ = service.authStatus
    }

    func testMakePreviewLayerDoesNotCrashWithoutConfiguringSession() {
        let service = CaptureService()
        let layer = service.makePreviewLayer()
        XCTAssertNotNil(layer)
    }

    func testFinishRecordingWithoutStartingThrows() async {
        let service = CaptureService()
        do {
            _ = try await service.finishRecording()
            XCTFail("expected finishRecording() to throw when no recording is in progress")
        } catch let error as CaptureError {
            // Either is acceptable depending on whether a camera was found; both are
            // CaptureError cases per the frozen contract.
            switch error {
            case .noCamera, .failed:
                break
            default:
                XCTFail("unexpected CaptureError: \(error)")
            }
        } catch {
            XCTFail("expected a CaptureError, got \(error)")
        }
    }

    func testStartRecordingWithoutCameraIsANoOp() {
        // On the Simulator `configureAndStart()` is never called in this test, so
        // `hasCamera` stays false — startRecording() must no-op rather than crash.
        let service = CaptureService()
        service.startRecording()
        XCTAssertFalse(service.isRecording)
    }
}
