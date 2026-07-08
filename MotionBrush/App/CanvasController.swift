import Foundation
import Observation
import UIKit

/// A thin handle the App layer uses to drive the live `CanvasView` (undo, clear,
/// export, brush selection, demo stroke) without owning UIKit state in SwiftUI.
/// `CanvasHost` installs the view reference on `makeUIView`.
@Observable
@MainActor
final class CanvasController {
    private(set) weak var view: CanvasView?

    func attach(_ view: CanvasView) { self.view = view }

    func setBrush(_ brush: BrushAsset?) { view?.setBrush(brush) }
    func restore(canvasPNG: Data?) { view?.restore(canvasPNG: canvasPNG) }
    func undo() { view?.undo() }
    func clear() { view?.clear() }
    func exportPNG() -> Data? { view?.exportPNG() }
    func playDemoStroke() { view?.playDemoStroke() }
}
