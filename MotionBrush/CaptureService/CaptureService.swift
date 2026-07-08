import AVFoundation
import Foundation
import Observation
import QuartzCore

/// AVCaptureSession wrapper → temporary `.mov` URL (§9.2, FR-1…FR-6).
///
/// PUBLIC API IS A FROZEN CONTRACT. The Wave-1D agent implements the bodies and
/// adds private files inside CaptureService/, but MUST keep these signatures so
/// the App module compiles unchanged. Camera only — configure the session with
/// NO audio input so no microphone prompt appears (FR-5).
@Observable
@MainActor
final class CaptureService {
    // Observable state the CaptureScreen binds to.
    private(set) var authStatus: CameraAuthStatus = .notDetermined
    private(set) var isRecording: Bool = false
    private(set) var recordProgress: Double = 0   // 0…1 toward K.maxClipSec (FR-3)

    init() {}

    /// Request camera permission (FR-5). Returns true if authorized.
    func requestAccess() async -> Bool {
        _stub("CaptureService.requestAccess")
    }

    /// Configure a camera-only session (rear by default) and start running (FR-1).
    func configureAndStart() async {
        _stub("CaptureService.configureAndStart")
    }

    /// Stop the running session and tear down.
    func stop() {
        _stub("CaptureService.stop")
    }

    /// A live preview layer bound to the session, for the CaptureScreen to host.
    func makePreviewLayer() -> CALayer {
        _stub("CaptureService.makePreviewLayer")
    }

    /// Toggle rear/front camera (FR-1).
    func flip() {
        _stub("CaptureService.flip")
    }

    /// Begin recording. Auto-stops at K.maxClipSec (FR-2).
    func startRecording() {
        _stub("CaptureService.startRecording")
    }

    /// Finish recording and return a temp `.mov` URL (NOT saved to Photos, FR-4).
    /// Throws `CaptureError.tooShort` for clips < K.minClipSec (FR-2).
    func finishRecording() async throws -> URL {
        _stub("CaptureService.finishRecording")
    }

    private func _stub(_ what: String) -> Never {
        fatalError("\(what) not yet implemented — Wave 1D")
    }
}
