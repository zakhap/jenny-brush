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

    private let paths: StorePaths
    private let fileManager: FileManager

    /// Test-only seam: when set, `commit` throws `.io` right after the named
    /// step instead of completing, so atomicity can be exercised
    /// deterministically without racing a real crash (§14 test 4).
    var debugFailPoint: DebugFailPoint?

    enum DebugFailPoint {
        case afterPreviewRender
        case afterMoveIntoPlace
        case beforeIndexRewrite
    }

    init() {
        self.paths = StorePaths(baseURL: StorePaths.defaultBaseURL())
        self.fileManager = .default
    }

    /// Internal seam for tests: point the store at an arbitrary base directory
    /// instead of the real Application Support container. Does not change the
    /// public `init()` contract used by the App module.
    init(baseURL: URL, fileManager: FileManager = .default) {
        self.paths = StorePaths(baseURL: baseURL)
        self.fileManager = fileManager
    }

    /// Read index.json + each manifest into `brushes`. Corrupt brushes are skipped
    /// and logged; if the active one is corrupt, activate the next (§13). Never throws.
    func load() {
        brushes = []
        activeBrushID = nil

        do {
            try ensureDirectories()
        } catch {
            log("load: could not create Brushes/Canvas directories: \(error)")
            return
        }

        guard let indexData = try? Data(contentsOf: paths.indexURL) else {
            // No index yet — fresh install, zero brushes. Not an error.
            return
        }
        guard let index = try? JSONDecoder().decode(BrushIndex.self, from: indexData) else {
            log("load: index.json unreadable/corrupt — starting with zero brushes")
            return
        }

        var loaded: [BrushAsset] = []
        for id in index.order {
            if let asset = loadBrush(id: id) {
                loaded.append(asset)
            } else {
                log("load: skipping corrupt brush \(id)")
            }
        }

        brushes = loaded
        if let active = index.activeID, loaded.contains(where: { $0.id == active }) {
            activeBrushID = active
        } else {
            // Active brush was corrupt (or missing) — activate the next most
            // recent survivor, per §13.
            activeBrushID = loaded.first?.id
        }

        // Best-effort: if we dropped corrupt entries or re-picked the active
        // brush, persist the corrected index so future loads don't re-derive it.
        if activeBrushID != index.activeID || loaded.count != index.order.count {
            try? writeIndex(BrushIndex(order: loaded.map(\.id), activeID: activeBrushID))
        }
    }

    /// A fresh UUID string for a new brush's id/directory name.
    func newBrushID() -> String { UUID().uuidString }

    /// Next auto name: "Brush 1", "Brush 2", … (FR-14) — one past the highest
    /// existing "Brush N" name currently on the shelf.
    func autoName() -> String {
        let highest = brushes.compactMap { asset -> Int? in
            guard asset.name.hasPrefix("Brush ") else { return nil }
            return Int(asset.name.dropFirst("Brush ".count))
        }.max() ?? 0
        return "Brush \(highest + 1)"
    }

    /// Atomically commit a freshly built brush (its `directoryURL` is a temp dir
    /// with manifest.json + atlas-*.heic). Generates preview.gif (§10.4), moves the
    /// dir into Brushes/<id>/, rewrites index.json, selects it active (§10.3, FR-14).
    /// Returns the committed asset (pointing at its permanent dir). Throws `.io`.
    @discardableResult
    func commit(_ built: BrushAsset) throws -> BrushAsset {
        let destDir = paths.brushDir(built.id)
        do {
            try ensureDirectories()

            // 1. Render the shelf preview into the temp dir, before it ever
            //    touches the permanent location (§10.4).
            let previewURL = built.directoryURL.appendingPathComponent("preview.gif")
            try PreviewRenderer.renderPreviewGIF(
                manifest: built.manifest,
                brushDirectory: built.directoryURL,
                to: previewURL
            )
            if debugFailPoint == .afterPreviewRender { throw BrushError.io }

            // 2. Move the whole temp dir into place. On the same volume this is
            //    an atomic rename; falls back to copy+delete cross-volume.
            try moveIntoPlace(from: built.directoryURL, to: destDir)
            if debugFailPoint == .afterMoveIntoPlace { throw BrushError.io }

            // 3. Rewrite index.json (write-temp-then-rename, §10.3).
            var newOrder = brushes.map(\.id)
            newOrder.removeAll { $0 == built.id }
            newOrder.insert(built.id, at: 0)
            if debugFailPoint == .beforeIndexRewrite { throw BrushError.io }
            try writeIndex(BrushIndex(order: newOrder, activeID: built.id))

            // 4. Update in-memory state.
            let committed = BrushAsset(
                id: built.id,
                name: built.name,
                manifest: built.manifest,
                directoryURL: destDir
            )
            brushes.removeAll { $0.id == committed.id }
            brushes.insert(committed, at: 0)
            activeBrushID = committed.id
            return committed
        } catch {
            // Never leave a half-written brush behind: clean up both the
            // original temp dir (if still there) and any partially-moved
            // destination dir. index.json is untouched until step 3 succeeds,
            // so on any earlier failure the on-disk index still matches
            // in-memory `brushes` exactly.
            try? fileManager.removeItem(at: built.directoryURL)
            try? fileManager.removeItem(at: destDir)
            throw BrushError.io
        }
    }

    /// Select a brush as active (FR-16).
    func select(_ id: String) {
        guard brushes.contains(where: { $0.id == id }) else { return }
        activeBrushID = id
        try? writeIndex(BrushIndex(order: brushes.map(\.id), activeID: id))
    }

    /// Delete a brush; if it was active, activate the next most recent (FR-17).
    func delete(_ id: String) throws {
        guard let idx = brushes.firstIndex(where: { $0.id == id }) else { return }
        let asset = brushes[idx]

        if fileManager.fileExists(atPath: asset.directoryURL.path) {
            do {
                try fileManager.removeItem(at: asset.directoryURL)
            } catch {
                throw BrushError.io
            }
        }

        brushes.remove(at: idx)
        if activeBrushID == id {
            // "Next most recent": the shelf is most-recent-first, so the item
            // that slides into the deleted slot (formerly idx+1) is next most
            // recent; if the deleted brush was the oldest, fall back to the
            // one before it (now the new oldest).
            if brushes.isEmpty {
                activeBrushID = nil
            } else if idx < brushes.count {
                activeBrushID = brushes[idx].id
            } else {
                activeBrushID = brushes[brushes.count - 1].id
            }
        }

        do {
            try writeIndex(BrushIndex(order: brushes.map(\.id), activeID: activeBrushID))
        } catch {
            throw BrushError.io
        }
    }

    // MARK: Canvas bitmap persistence (FR-26)

    /// Persist the current canvas PNG (called on scene background).
    func saveCanvas(_ png: Data) {
        do {
            try ensureDirectories()
            try png.write(to: paths.canvasPNGURL, options: .atomic)
        } catch {
            log("saveCanvas failed: \(error)")
        }
    }

    /// The restored canvas PNG, or nil if none saved yet.
    func loadCanvasPNG() -> Data? {
        try? Data(contentsOf: paths.canvasPNGURL)
    }

    // MARK: - Private helpers

    private func loadBrush(id: String) -> BrushAsset? {
        let dir = paths.brushDir(id)
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(BrushManifest.self, from: data)
        else {
            return nil
        }
        for page in manifest.atlasPages {
            guard fileManager.fileExists(atPath: dir.appendingPathComponent(page).path) else {
                return nil
            }
        }
        return BrushAsset(id: id, name: manifest.name, manifest: manifest, directoryURL: dir)
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: paths.brushesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.canvasDir, withIntermediateDirectories: true)
    }

    private func moveIntoPlace(from source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            // Cross-volume fallback (e.g. system temp dir on a different
            // volume than the sandbox container in some test environments).
            try fileManager.copyItem(at: source, to: destination)
            try? fileManager.removeItem(at: source)
        }
    }

    /// `.atomic` makes `Data.write` write to an auxiliary file and rename it
    /// into place — the write-temp-then-rename semantics §10.3 asks for.
    private func writeIndex(_ index: BrushIndex) throws {
        try ensureDirectories()
        let data = try JSONEncoder().encode(index)
        try data.write(to: paths.indexURL, options: .atomic)
    }

    private func log(_ message: String) {
        print("[BrushStore] \(message)")
    }
}
