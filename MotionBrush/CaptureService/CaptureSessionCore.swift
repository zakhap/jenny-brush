import AVFoundation

/// Owns the `AVCaptureSession` and every AVFoundation object underneath it.
///
/// This type is intentionally NOT `@MainActor` (unlike `CaptureService`). All
/// configuration and I/O — adding inputs/outputs, starting/stopping the session,
/// starting/stopping recording — happens on `queue`, a private serial background
/// queue, per Apple's guidance that session configuration is a blocking call and
/// must not run on the main thread. `CaptureService` (the `@MainActor` facade the
/// App module binds to) calls into this via `async` methods and only publishes
/// `@Observable` state back on the main actor once a call completes.
///
/// Camera only: no `AVCaptureDeviceInput` for audio is ever added, so no
/// microphone permission prompt appears (FR-5).
final class CaptureSessionCore {
    /// Safe to read from any thread to build an `AVCaptureVideoPreviewLayer` — Apple
    /// documents that the preview layer may be created/attached on the main thread
    /// while the session runs on a background queue.
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.motionbrush.captureservice.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var currentPosition: AVCaptureDevice.Position = .back

    /// Builds a camera-only session (rear by default, 1080p/30fps portrait if
    /// available) and starts it running. Returns whether a usable camera device was
    /// found — false on the Simulator, which must not crash (just runs preview-less).
    func configureAndStart() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                let hasCamera = self.configure()
                if hasCamera {
                    self.session.startRunning()
                }
                continuation.resume(returning: hasCamera)
            }
        }
    }

    private func configure() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }

        let hasCamera = attachVideoInput(position: currentPosition)

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        applyPortraitOrientation()
        return hasCamera
    }

    @discardableResult
    private func attachVideoInput(position: AVCaptureDevice.Position) -> Bool {
        if let existing = videoInput {
            session.removeInput(existing)
            videoInput = nil
        }
        guard let device = Self.device(for: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            return false
        }
        session.addInput(input)
        videoInput = input
        return true
    }

    private func applyPortraitOrientation() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        if #available(iOS 17.0, *), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    private static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// Toggle rear/front (FR-1). Returns whether a device for the new position was
    /// found; on failure the previous input is left in place.
    func flip() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                let next: AVCaptureDevice.Position = self.currentPosition == .back ? .front : .back
                self.session.beginConfiguration()
                let ok = self.attachVideoInput(position: next)
                if ok {
                    self.currentPosition = next
                }
                self.applyPortraitOrientation()
                self.session.commitConfiguration()
                continuation.resume(returning: ok)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    /// Begin writing to `url`. `delegate`'s completion fires on an AVFoundation
    /// internal queue (not necessarily `queue` or main) — the caller bridges it.
    func startRecording(to url: URL, delegate: AVCaptureFileOutputRecordingDelegate) {
        queue.async { [weak self] in
            self?.movieOutput.startRecording(to: url, recordingDelegate: delegate)
        }
    }

    func stopRecording() {
        queue.async { [weak self] in
            self?.movieOutput.stopRecording()
        }
    }
}
