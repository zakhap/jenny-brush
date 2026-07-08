import CoreGraphics
import Foundation
import Observation

/// Persistence, index, previews, and the canvas bitmap (§10, FR-15…FR-18, FR-26).
///
/// PUBLIC API IS A FROZEN CONTRACT. The Wave-1C agent implements the bodies and
/// adds private files inside BrushStore/, keeping these signatures stable.
///
/// On-disk layout (§10.1):
///   Application Support/Brushes/index.json
///   Application Support/Brushes/<uuid>/{manifest.json, atlas-*.heic, preview.gif}
///   Application Support/Canvas/canvas.png
@Observable
@MainActor
final class BrushStore {
    /// Loaded brushes, most-recent-first (FR-15).
    private(set) var brushes: [BrushAsset] = []
    /// The active brush id; exactly one when the shelf is non-empty (FR-16).
    private(set) var activeBrushID: String?

    var activeBrush: BrushAsset? {
        guard let id = activeBrushID else { return nil }
        return brushes.first { $0.id == id }
    }

    init() {}

    /// Read index.json + each manifest into `brushes`. Corrupt brushes are skipped
    /// and logged; if the active one is corrupt, activate the next (§13). Never throws.
    func load() {
        _stub("BrushStore.load")
    }

    /// A fresh UUID string for a new brush's id/directory name.
    func newBrushID() -> String { UUID().uuidString }

    /// Next auto name: "Brush 1", "Brush 2", … (FR-14).
    func autoName() -> String {
        _stub("BrushStore.autoName")
    }

    /// Atomically commit a freshly built brush (its `directoryURL` is a temp dir
    /// with manifest.json + atlas-*.heic). Generates preview.gif (§10.4), moves the
    /// dir into Brushes/<id>/, rewrites index.json, selects it active (§10.3, FR-14).
    /// Returns the committed asset (pointing at its permanent dir). Throws `.io`.
    @discardableResult
    func commit(_ built: BrushAsset) throws -> BrushAsset {
        _stub("BrushStore.commit")
    }

    /// Select a brush as active (FR-16).
    func select(_ id: String) {
        _stub("BrushStore.select")
    }

    /// Delete a brush; if it was active, activate the next most recent (FR-17).
    func delete(_ id: String) throws {
        _stub("BrushStore.delete")
    }

    // MARK: Canvas bitmap persistence (FR-26)

    /// Persist the current canvas PNG (called on scene background).
    func saveCanvas(_ png: Data) {
        _stub("BrushStore.saveCanvas")
    }

    /// The restored canvas PNG, or nil if none saved yet.
    func loadCanvasPNG() -> Data? {
        _stub("BrushStore.loadCanvasPNG")
    }

    private func _stub(_ what: String) -> Never {
        fatalError("\(what) not yet implemented — Wave 1C")
    }
}
