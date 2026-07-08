import AVFoundation
import SwiftUI
import UIKit

/// Full-screen camera with press-and-hold record, progress ring, flip, close, and
/// the permission-denied inline state (§12, FR-1…FR-6, E1). On the Simulator (no
/// camera) it offers a bundled test clip so the full loop stays exercisable.
struct CaptureScreen: View {
    @Environment(AppModel.self) private var model
    @State private var configured = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.capture.authStatus {
            case .authorized:
                cameraUI
            case .denied:
                permissionDenied
            case .notDetermined:
                Color.black
            }

            controls
        }
        .task { await configureIfNeeded() }
        .onDisappear { model.capture.stop() }
    }

    // MARK: Camera

    private var cameraUI: some View {
        CameraPreviewHost { model.capture.makePreviewLayer() }
            .ignoresSafeArea()
    }

    private var permissionDenied: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.metering.none").font(.system(size: 40))
            Text("Camera access is off.")
                .font(.headline)
            Text("Turn it on in Settings to film a brush.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(40)
    }

    // MARK: Controls overlay

    private var controls: some View {
        VStack {
            HStack {
                iconButton("xmark") { model.goCanvas() }
                Spacer()
                if model.capture.authStatus == .authorized {
                    iconButton("arrow.triangle.2.circlepath.camera") { model.capture.flip() }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()

            bottomControl
                .padding(.bottom, 40)
        }
    }

    @ViewBuilder private var bottomControl: some View {
        #if targetEnvironment(simulator)
        // The Simulator has no camera regardless of auth status — always offer the clip.
        testClipButton
        #else
        if model.capture.authStatus == .authorized {
            recordButton
        }
        #endif
    }

    private var recordButton: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.4), lineWidth: 5)
                .frame(width: 84, height: 84)
            Circle()
                .trim(from: 0, to: model.capture.recordProgress)
                .stroke(Color.red, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: 84, height: 84)
                .rotationEffect(.degrees(-90))
            Circle()
                .fill(Color.red)
                .frame(width: model.capture.isRecording ? 40 : 68,
                       height: model.capture.isRecording ? 40 : 68)
                .animation(.easeInOut(duration: 0.2), value: model.capture.isRecording)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !model.capture.isRecording { startRecording() } }
                .onEnded { _ in finishRecording() }
        )
    }

    #if targetEnvironment(simulator)
    private var testClipButton: some View {
        VStack(spacing: 10) {
            Text("No camera on Simulator")
                .font(.footnote).foregroundStyle(.white.opacity(0.7))
            if let clip = Self.bundledClipURL() {
                Button {
                    model.startProcessing(videoURL: copyToTemp(clip))
                } label: {
                    Label("Use test clip", systemImage: "film")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Drop fixtures/clip.mov and rebuild")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    static func bundledClipURL() -> URL? {
        for ext in ["mov", "mp4", "m4v"] {
            if let u = Bundle.main.url(forResource: "clip", withExtension: ext) { return u }
        }
        return nil
    }

    /// Copy the bundled read-only clip to a writable temp URL so the pipeline (and
    /// its cleanup) treats it exactly like a real recording.
    private func copyToTemp(_ src: URL) -> URL {
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(src.pathExtension)
        try? FileManager.default.copyItem(at: src, to: dst)
        return dst
    }
    #endif

    // MARK: Actions

    private func configureIfNeeded() async {
        guard !configured else { return }
        configured = true
        let granted = await model.capture.requestAccess()
        if granted { await model.capture.configureAndStart() }
    }

    private func startRecording() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        model.capture.startRecording()
    }

    private func finishRecording() {
        Task {
            do {
                let url = try await model.capture.finishRecording()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                model.startProcessing(videoURL: url)
            } catch CaptureError.tooShort {
                model.showToast("Hold longer")   // FR-2
            } catch {
                // Not-recording / other: ignore, camera stays open.
            }
        }
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.black.opacity(0.35)))
        }
    }
}
