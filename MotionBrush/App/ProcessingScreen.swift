import SwiftUI

/// PLACEHOLDER (foundation). Integration wave replaces this with the real
/// "theater": consumes BrushFactory's AsyncStream, stacks cutouts with a counter,
/// then crossfades to Canvas and plays the demo stroke. See §12, FR-12/FR-24.
struct ProcessingScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color(white: 0.95).ignoresSafeArea()
            VStack(spacing: 24) {
                Text("[placeholder theater — foundation]")
                    .foregroundStyle(.secondary)
                Button("Done → Canvas") { model.goCanvas() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
