import SwiftUI
import UIKit

/// Hosts the Metal `CanvasView` in SwiftUI and wires stroke-commit autosave.
struct CanvasHost: UIViewRepresentable {
    let controller: CanvasController
    let onStrokeCommitted: () -> Void

    func makeUIView(context: Context) -> CanvasView {
        let view = CanvasView(frame: .zero)
        view.onStrokeCommitted = onStrokeCommitted
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: CanvasView, context: Context) {}
}

/// Hosts an AVCaptureVideoPreviewLayer (from CaptureService) full-bleed.
struct CameraPreviewHost: UIViewRepresentable {
    let makeLayer: () -> CALayer

    func makeUIView(context: Context) -> PreviewContainerView {
        let v = PreviewContainerView()
        v.backgroundColor = .black
        let layer = makeLayer()
        v.previewLayer = layer
        v.layer.addSublayer(layer)
        return v
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {}

    final class PreviewContainerView: UIView {
        var previewLayer: CALayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
    }
}
