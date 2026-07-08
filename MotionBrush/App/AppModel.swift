import Foundation
import Observation
import SwiftUI

/// The three-state navigation machine (§9.2). Held in one `@Observable` model.
@Observable
@MainActor
final class AppModel {
    enum Screen: Equatable {
        case canvas
        case capture
        case processing   // carries its job via `processingVideoURL`
    }

    var screen: Screen = .canvas

    /// Shared services. During Wave 1 these are stubs; the integration wave wires
    /// their real behavior into the screens.
    let store = BrushStore()
    let capture = CaptureService()

    /// Set when Capture hands a clip to Processing.
    var processingVideoURL: URL?

    init() {
        // NOTE: store.load() is deliberately NOT called until BrushStore is
        // implemented (Wave 1C) — its stub traps. The integration wave adds it.
    }

    func goCapture() { screen = .capture }
    func goCanvas() { screen = .canvas }
    func startProcessing(videoURL: URL) {
        processingVideoURL = videoURL
        screen = .processing
    }
}
