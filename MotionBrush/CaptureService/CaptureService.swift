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

    /// The AVFoundation engine; deliberately not `@MainActor` (see its doc comment).
    private let core = CaptureSessionCore()

    /// False on the Simulator (no camera device) — startRecording()/finishRecording()
    /// no-op / fail gracefully instead of crashing.
    private var hasCamera = false

    private var progressTask: Task<Void, Never>?
    private var recordingStart: Date?
    private var recordingDelegate: RecordingDelegate?

    /// Set while `finishRecording()` is awaiting the delegate's completion.
    private var pendingContinuation: CheckedContinuation<URL, Error>?
    /// Populated if the recording finished (e.g. auto-stop at K.maxClipSec) BEFORE
    /// `finishRecording()` was called to collect the result.
    private var stashedOutcome: (url: URL, error: Error?, elapsed: Double)?

    init() {
        authStatus = Self.mapAuthStatus(AVCaptureDevice.authorizationStatus(for: .video))
    }

    /// Request camera permission (FR-5). Returns true if authorized.
    func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authStatus = .authorized
            return true
        case .denied, .restricted:
            authStatus = .denied
            return false
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authStatus = granted ? .authorized : .denied
            return granted
        @unknown default:
            authStatus = .denied
            return false
        }
    }

    /// Configure a camera-only session (rear by default) and start running (FR-1).
    func configureAndStart() async {
        guard authStatus == .authorized else { return }
        hasCamera = await core.configureAndStart()
    }

    /// Stop the running session and tear down.
    func stop() {
        progressTask?.cancel()
        progressTask = nil
        isRecording = false
        recordProgress = 0
        core.stop()
    }

    /// A live preview layer bound to the session, for the CaptureScreen to host.
    func makePreviewLayer() -> CALayer {
        let layer = AVCaptureVideoPreviewLayer(session: core.session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    /// Toggle rear/front camera (FR-1).
    func flip() {
        Task { [weak self] in
            await self?.core.flip()
        }
    }

    /// Begin recording. Auto-stops at K.maxClipSec (FR-2).
    func startRecording() {
        guard hasCamera, !isRecording else { return }

        isRecording = true
        recordProgress = 0
        stashedOutcome = nil

        let url = Self.makeTempClipURL()
        let delegate = RecordingDelegate { [weak self] finishedURL, error in
            Task { @MainActor in
                self?.recordingDidFinish(url: finishedURL, error: error)
            }
        }
        recordingDelegate = delegate
        recordingStart = Date()
        core.startRecording(to: url, delegate: delegate)
        startProgressLoop()
    }

    /// Finish recording and return a temp `.mov` URL (NOT saved to Photos, FR-4).
    /// Throws `CaptureError.tooShort` for clips < K.minClipSec (FR-2).
    func finishRecording() async throws -> URL {
        // Auto-stop may already have fired (K.maxClipSec reached) before the caller
        // asked for the result — resolve it immediately in that case.
        if let stashed = stashedOutcome {
            stashedOutcome = nil
            return try Self.outcome(url: stashed.url, error: stashed.error, elapsed: stashed.elapsed).get()
        }
        guard isRecording else {
            throw hasCamera ? CaptureError.failed("not recording") : CaptureError.noCamera
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            pendingContinuation = continuation
            core.stopRecording()
        }
    }

    // MARK: - Recording lifecycle

    private func startProgressLoop() {
        progressTask?.cancel()
        let start = Date()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(start)
                self.recordProgress = CaptureMath.progress(elapsed: elapsed, maxClipSec: K.maxClipSec)
                if elapsed >= K.maxClipSec {
                    self.core.stopRecording()
                    break
                }
                try? await Task.sleep(nanoseconds: 33_000_000) // ~30 Hz
            }
        }
    }

    private func recordingDidFinish(url: URL, error: Error?) {
        progressTask?.cancel()
        progressTask = nil
        isRecording = false
        recordProgress = 0
        recordingDelegate = nil

        let elapsed = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        recordingStart = nil

        if let continuation = pendingContinuation {
            pendingContinuation = nil
            switch Self.outcome(url: url, error: error, elapsed: elapsed) {
            case .success(let finalURL):
                continuation.resume(returning: finalURL)
            case .failure(let captureError):
                continuation.resume(throwing: captureError)
            }
        } else {
            stashedOutcome = (url, error, elapsed)
        }
    }

    /// Turns a finished-recording callback into a Result, deleting the temp file on
    /// any failure path (too short / write error) per FR-2/FR-4.
    private static func outcome(url: URL, error: Error?, elapsed: Double) -> Result<URL, CaptureError> {
        if let error {
            try? FileManager.default.removeItem(at: url)
            return .failure(.failed(error.localizedDescription))
        }
        if CaptureMath.isTooShort(duration: elapsed, minClipSec: K.minClipSec) {
            try? FileManager.default.removeItem(at: url)
            return .failure(.tooShort)
        }
        return .success(url)
    }

    private static func makeTempClipURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
    }

    private static func mapAuthStatus(_ status: AVAuthorizationStatus) -> CameraAuthStatus {
        switch status {
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}
