import Foundation
import Observation
import SwiftUI

/// The three-state navigation machine (§9.2) plus the glue that runs the
/// capture → pipeline → commit → canvas loop. Held in one `@Observable` model.
@Observable
@MainActor
final class AppModel {
    enum Screen: Equatable {
        case canvas
        case capture
        case processing
    }

    var screen: Screen = .canvas

    let store = BrushStore()
    let capture = CaptureService()
    let factory = BrushFactory()

    /// Controller handle to the live CanvasView (set by CanvasHost).
    let canvas = CanvasController()

    /// The clip currently being turned into a brush (nil unless processing).
    var processingVideoURL: URL?

    /// A transient message shown as a toast (FR-2 "Hold longer", FR-10 no-subject, E9 io).
    var toast: String?

    init() {
        store.load()
    }

    // MARK: Navigation

    func goCapture() { screen = .capture }

    func goCanvas() {
        screen = .canvas
    }

    /// Capture handed us a clip — enter the theater and start the pipeline.
    func startProcessing(videoURL: URL) {
        processingVideoURL = videoURL
        screen = .processing
    }

    // MARK: Pipeline outcomes (called by ProcessingScreen)

    /// Pipeline produced a brush in a temp dir — commit it atomically, select it,
    /// and return to canvas (FR-14).
    func finishBrushCreation(built: BrushAsset) {
        do {
            let committed = try store.commit(built)
            cleanupClip()
            store.select(committed.id)
            canvas.setBrush(store.activeBrush)
            screen = .canvas
        } catch {
            cleanupClip()
            showToast("Couldn't save brush")   // E9 / BrushError.io
            screen = .canvas
        }
    }

    /// Pipeline failed — surface the right message and route back (FR-10, §13).
    func failBrushCreation(_ error: Error) {
        cleanupClip()
        if case BrushError.cancelled = error {
            screen = .canvas
            return
        }
        // noSubject and everything else route back to Capture so the user retries.
        let message: String
        if case BrushError.noSubject = error {
            message = "Couldn't find a subject — try filming something that moves."
        } else {
            message = "Something went wrong — try again."
        }
        showToast(message)
        screen = .capture
    }

    private func cleanupClip() {
        if let url = processingVideoURL {
            try? FileManager.default.removeItem(at: url)   // FR-4: clip is temporary
        }
        processingVideoURL = nil
    }

    // MARK: Toast

    func showToast(_ message: String) {
        toast = message
        let capture = message
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if self.toast == capture { self.toast = nil }
        }
    }

    // MARK: Persistence lifecycle (FR-26)

    func persistCanvas() {
        if let png = canvas.exportPNG() {
            store.saveCanvas(png)
        }
    }
}
