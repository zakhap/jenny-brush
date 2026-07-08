import SwiftUI

/// The home canvas: full-bleed drawing surface + brush shelf + toolbar, or the
/// empty state on first launch (§12, FR-15…FR-25).
struct CanvasScreen: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false
    @State private var shareItem: ShareImage?

    private var hasBrushes: Bool { !model.store.brushes.isEmpty }

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            // Drawing surface (always present so restore/replay state persists).
            CanvasHost(controller: model.canvas) {
                model.persistCanvas()
            }
            .ignoresSafeArea()
            .opacity(hasBrushes ? 1 : 0)

            if hasBrushes {
                loadedChrome
            } else {
                emptyState
            }
        }
        .onAppear { syncBrushAndRestore() }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.image])
        }
    }

    // MARK: Loaded state — toolbar + shelf

    private var loadedChrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                Spacer()
                toolbarButton("arrow.uturn.backward") { model.canvas.undo() }
                toolbarButton("trash") { confirmClear = true }
                toolbarButton("square.and.arrow.up") { share() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Spacer()

            shelf
        }
        .confirmationDialog("Clear the canvas?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { model.canvas.clear(); model.persistCanvas() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var shelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                cameraButton
                ForEach(model.store.brushes) { brush in
                    ShelfCell(
                        brush: brush,
                        isActive: brush.id == model.store.activeBrushID,
                        onTap: { model.store.select(brush.id); model.canvas.setBrush(model.store.activeBrush) },
                        onDelete: { deleteBrush(brush) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
    }

    private var cameraButton: some View {
        Button { model.goCapture() } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 22))
                .frame(width: 56, height: 56)
                .background(Circle().fill(.tint))
                .foregroundStyle(.white)
        }
    }

    private func toolbarButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
        }
    }

    // MARK: Empty state (0 brushes)

    private var emptyState: some View {
        VStack(spacing: 24) {
            Text("Film something that moves.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button { model.goCapture() } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 30))
                    .frame(width: 84, height: 84)
                    .background(Circle().fill(.tint))
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: Actions

    private func syncBrushAndRestore() {
        model.canvas.restore(canvasPNG: model.store.loadCanvasPNG())
        model.canvas.setBrush(model.store.activeBrush)
    }

    private func deleteBrush(_ brush: BrushAsset) {
        try? model.store.delete(brush.id)
        model.canvas.setBrush(model.store.activeBrush)
    }

    private func share() {
        guard let png = model.canvas.exportPNG(), let image = UIImage(data: png) else { return }
        shareItem = ShareImage(image: image)
    }
}

// MARK: - Shelf cell

private struct ShelfCell: View {
    let brush: BrushAsset
    let isActive: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        Button(action: onTap) {
            AnimatedImageView(url: brush.previewURL)
                .frame(width: 96, height: 72)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isActive ? Color.accentColor : Color.black.opacity(0.08),
                                      lineWidth: isActive ? 2.5 : 1)
                )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete this brush?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Share sheet

struct ShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
