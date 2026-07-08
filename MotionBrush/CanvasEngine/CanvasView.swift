import CoreGraphics
import Foundation
import UIKit

/// The drawing surface: a Metal-backed UIView hosting committed + live stroke
/// textures, arc-length stamping, undo, clear, export (§11, FR-19…FR-25).
///
/// PUBLIC API IS A FROZEN CONTRACT. The Wave-1A agent implements the renderer,
/// StrokeBuilder/Stamper, UndoStack, and Shaders.metal as files inside
/// CanvasEngine/, keeping this UIView's public surface stable so CanvasScreen
/// (a UIViewRepresentable) compiles unchanged.
final class CanvasView: UIView {
    /// Called after each committed stroke (App autosaves the canvas, FR-26).
    var onStrokeCommitted: (() -> Void)?

    /// Set the active brush; loads its atlas pages into MTLTextures for the
    /// active brush only (§9.6). Pass nil to draw nothing.
    func setBrush(_ brush: BrushAsset?) {
        _stub("CanvasView.setBrush")
    }

    /// Restore the committed canvas from a saved PNG (base for replay, FR-26).
    /// Pass nil for a fresh white canvas.
    func restore(canvasPNG: Data?) {
        _stub("CanvasView.restore")
    }

    /// Revert the most recent stroke via replay (FR-23).
    func undo() {
        _stub("CanvasView.undo")
    }

    /// Erase everything to white and empty the undo stack (FR-23, behind a confirm in UI).
    func clear() {
        _stub("CanvasView.clear")
    }

    /// The committed canvas composited over opaque white as PNG (FR-25 export & FR-26 persist).
    func exportPNG() -> Data? {
        _stub("CanvasView.exportPNG")
    }

    /// Programmatically draw the demo S-curve with the active brush over
    /// K.demoStrokeDuration, feeding points through the normal stroke path (FR-24).
    func playDemoStroke() {
        _stub("CanvasView.playDemoStroke")
    }

    private func _stub(_ what: String) -> Never {
        fatalError("\(what) not yet implemented — Wave 1A")
    }
}
