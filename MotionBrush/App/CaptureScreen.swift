import SwiftUI

/// PLACEHOLDER (foundation). Integration wave replaces this with the real camera:
/// AVCaptureVideoPreviewLayer full screen, record control + progress ring, flip,
/// close, permission-denied inline state. See §12, FR-1…FR-6.
struct CaptureScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Text("[placeholder camera — foundation]")
                    .foregroundStyle(.white)
                Button("Simulate clip → Processing") {
                    // Foundation only: fabricate a fake URL to exercise navigation.
                    model.startProcessing(videoURL: URL(fileURLWithPath: "/dev/null"))
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") { model.goCanvas() }
                    .foregroundStyle(.white)
            }
        }
    }
}
