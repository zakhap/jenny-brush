import SwiftUI

/// PLACEHOLDER (foundation). Integration wave replaces this with the real canvas:
/// full-bleed CanvasView + bottom brush shelf + top toolbar (undo/clear/share) +
/// empty state ("Film something that moves."). See §12.
struct CanvasScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Text("Film something that moves.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button {
                    model.goCapture()
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 28))
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(.tint))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text("[placeholder canvas — foundation]")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 40)
        }
    }
}
