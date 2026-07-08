import SwiftUI

/// Switches between the three screens and hosts the global toast overlay.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.screen {
            case .canvas:     CanvasScreen()
            case .capture:    CaptureScreen()
            case .processing: ProcessingScreen()
            }

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(Capsule().fill(.black.opacity(0.82)))
                        .padding(.bottom, 130)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.screen)
        .animation(.easeInOut(duration: 0.2), value: model.toast)
    }
}
