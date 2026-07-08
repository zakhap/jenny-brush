import SwiftUI

/// Switches between the three screens. During Wave 1 the screens are visual
/// placeholders; the integration wave replaces them with the real UIs.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.screen {
            case .canvas:     CanvasScreen()
            case .capture:    CaptureScreen()
            case .processing: ProcessingScreen()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.screen)
    }
}
