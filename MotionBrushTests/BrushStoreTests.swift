import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MotionBrush

/// Exercises BrushStore in isolation (§14 tests 4 & 5), pointed at a scratch
/// temp directory instead of the real Application Support container.
@MainActor
final class BrushStoreTests: XCTestCase {
    private var scratchRoot: URL!

    override func setUp() {
        super.setUp()
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrushStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchRoot)
        scratchRoot = nil
        super.tearDown()
    }

    // MARK: - Fixture helpers

    /// A tiny valid RGBA atlas HEIC, encoded with CoreGraphics/ImageIO — big
    /// enough to hold one `size`×`size` frame at the origin.
    private func makeAtlasHEIC(size: Int = 64) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Could not create CGContext")
        }
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else {
            throw XCTSkip("Could not snapshot CGImage")
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            throw XCTSkip("HEIC encoding unavailable in this environment")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw XCTSkip("HEIC finalize failed in this environment")
        }
        return data as Data
    }

    /// Builds a synthetic "just-produced-by-BrushFactory" temp brush dir:
    /// manifest.json + atlas-0.heic, matching the real contract's shape.
    private func makeBuiltBrush(id: String, name: String, frameCount: Int = 1) throws -> BrushAsset {
        let tempDir = scratchRoot.appendingPathComponent("build-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let atlasData = try makeAtlasHEIC()
        try atlasData.write(to: tempDir.appendingPathComponent("atlas-0.heic"))

        var frames: [FrameEntry] = []
        for i in 0..<frameCount {
            frames.append(FrameEntry(i: i, page: 0, rect: [0, 0, 64, 64], anchor: [32, 32], duplicateOf: nil))
        }
        let manifest = BrushManifest(
            schemaVersion: BrushManifest.currentSchemaVersion,
            id: id,
            name: name,
            createdAt: Date(),
            frameCount: frameCount,
            sourceDuration: 2.0,
            suggestedSpacingFactor: 0.4,
            atlasPages: ["atlas-0.heic"],
            frames: frames
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"))

        return BrushAsset(id: id, name: name, manifest: manifest, directoryURL: tempDir)
    }

    private func makeStore() -> BrushStore {
        let base = scratchRoot.appendingPathComponent("appsupport-\(UUID().uuidString)", isDirectory: true)
        return BrushStore(baseURL: base)
    }

    // MARK: - manifest.json round-trip

    func testManifestJSONRoundTrips() throws {
        let manifest = BrushManifest(
            schemaVersion: BrushManifest.currentSchemaVersion,
            id: "brush-1",
            name: "Brush 1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            frameCount: 2,
            sourceDuration: 3.5,
            suggestedSpacingFactor: 0.4,
            atlasPages: ["atlas-0.heic"],
            frames: [
                FrameEntry(i: 0, page: 0, rect: [2, 2, 388, 500], anchor: [190.4, 261.0], duplicateOf: nil),
                FrameEntry(i: 1, page: 0, rect: [2, 2, 388, 500], anchor: [190.4, 261.0], duplicateOf: 0),
            ]
        )
        let data = try JSONEncoder().encode(manifest)
        let back = try JSONDecoder().decode(BrushManifest.self, from: data)
        XCTAssertEqual(manifest, back)
    }

    // MARK: - autoName

    func testAutoNameSequence() throws {
        let store = makeStore()
        store.load()
        XCTAssertEqual(store.autoName(), "Brush 1")

        try store.commit(makeBuiltBrush(id: store.newBrushID(), name: store.autoName()))
        XCTAssertEqual(store.autoName(), "Brush 2")

        try store.commit(makeBuiltBrush(id: store.newBrushID(), name: store.autoName()))
        XCTAssertEqual(store.autoName(), "Brush 3")
    }

    // MARK: - commit: preview, permanent move, selection, index

    func testCommitMovesIntoPlaceAndSelectsActive() throws {
        let store = makeStore()
        store.load()

        let id = store.newBrushID()
        let built = try makeBuiltBrush(id: id, name: "Brush 1")
        let committed = try store.commit(built)

        XCTAssertEqual(committed.id, id)
        XCTAssertEqual(store.activeBrushID, id)
        XCTAssertEqual(store.brushes.first?.id, id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.previewURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.manifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: built.directoryURL.path), "temp dir should be gone")
    }

    // MARK: - Atomicity (§14 test 4)

    func testAtomicityFailureAfterPreviewLeavesNoTrace() throws {
        try assertFailedCommitLeavesConsistentState(failPoint: .afterPreviewRender)
    }

    func testAtomicityFailureAfterMoveLeavesNoOrphan() throws {
        try assertFailedCommitLeavesConsistentState(failPoint: .afterMoveIntoPlace)
    }

    func testAtomicityFailureBeforeIndexRewriteLeavesIndexUntouched() throws {
        try assertFailedCommitLeavesConsistentState(failPoint: .beforeIndexRewrite)
    }

    private func assertFailedCommitLeavesConsistentState(
        failPoint: BrushStore.DebugFailPoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let base = scratchRoot.appendingPathComponent("appsupport-\(UUID().uuidString)", isDirectory: true)
        let store = BrushStore(baseURL: base)
        store.load()

        // A real prior brush, successfully committed, to prove existing state
        // survives untouched.
        let survivorID = store.newBrushID()
        try store.commit(makeBuiltBrush(id: survivorID, name: "Brush 1"))
        let indexURL = base.appendingPathComponent("Brushes/index.json")
        let indexBefore = try Data(contentsOf: indexURL)

        // Now attempt a second commit that is made to fail partway through.
        store.debugFailPoint = failPoint
        let failingID = store.newBrushID()
        let failingBuilt = try makeBuiltBrush(id: failingID, name: "Brush 2")

        XCTAssertThrowsError(try store.commit(failingBuilt), file: file, line: line) { error in
            XCTAssertEqual(error as? BrushError, .io, file: file, line: line)
        }

        // In-memory state: unchanged, still just the survivor, still active.
        XCTAssertEqual(store.brushes.map(\.id), [survivorID], file: file, line: line)
        XCTAssertEqual(store.activeBrushID, survivorID, file: file, line: line)

        // On-disk index: byte-identical to before the failed commit.
        let indexAfter = try Data(contentsOf: indexURL)
        XCTAssertEqual(indexBefore, indexAfter, file: file, line: line)

        // No half-written brush anywhere: neither the original temp dir nor a
        // partially-moved permanent dir survives.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: failingBuilt.directoryURL.path),
            "temp dir should be cleaned up", file: file, line: line
        )
        let permanentDir = base.appendingPathComponent("Brushes/\(failingID)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: permanentDir.path),
            "no orphan brush directory should remain", file: file, line: line
        )

        // A fresh store instance loading from disk sees exactly the survivor.
        let reloaded = BrushStore(baseURL: base)
        reloaded.load()
        XCTAssertEqual(reloaded.brushes.map(\.id), [survivorID], file: file, line: line)
        XCTAssertEqual(reloaded.activeBrushID, survivorID, file: file, line: line)
    }

    // MARK: - delete re-activates next most recent (FR-17)

    func testDeleteActiveReactivatesNextMostRecent() throws {
        let store = makeStore()
        store.load()

        let idA = store.newBrushID()
        try store.commit(makeBuiltBrush(id: idA, name: "Brush 1"))
        let idB = store.newBrushID()
        try store.commit(makeBuiltBrush(id: idB, name: "Brush 2"))
        let idC = store.newBrushID()
        try store.commit(makeBuiltBrush(id: idC, name: "Brush 3"))

        // Most-recent-first: [C, B, A], C active.
        XCTAssertEqual(store.brushes.map(\.id), [idC, idB, idA])
        XCTAssertEqual(store.activeBrushID, idC)

        try store.delete(idC)
        XCTAssertEqual(store.brushes.map(\.id), [idB, idA])
        XCTAssertEqual(store.activeBrushID, idB)

        try store.delete(idA)
        XCTAssertEqual(store.brushes.map(\.id), [idB])
        XCTAssertEqual(store.activeBrushID, idB, "deleting a non-active brush must not change selection")

        try store.delete(idB)
        XCTAssertTrue(store.brushes.isEmpty)
        XCTAssertNil(store.activeBrushID)
    }

    // MARK: - load skips a corrupt brush (§13)

    func testLoadSkipsCorruptBrushAndReactivatesNext() throws {
        let base = scratchRoot.appendingPathComponent("appsupport-\(UUID().uuidString)", isDirectory: true)
        let store = BrushStore(baseURL: base)
        store.load()

        let goodID = store.newBrushID()
        try store.commit(makeBuiltBrush(id: goodID, name: "Brush 1"))
        let corruptID = store.newBrushID()
        try store.commit(makeBuiltBrush(id: corruptID, name: "Brush 2"))

        // corruptID is now active (most recent). Corrupt it on disk by
        // truncating its manifest.json to invalid JSON.
        let corruptManifestURL = base.appendingPathComponent("Brushes/\(corruptID)/manifest.json")
        try Data("not valid json".utf8).write(to: corruptManifestURL)

        let reloaded = BrushStore(baseURL: base)
        reloaded.load()

        XCTAssertEqual(reloaded.brushes.map(\.id), [goodID], "corrupt brush must be skipped, never crash")
        XCTAssertEqual(reloaded.activeBrushID, goodID, "corrupt active brush must fall back to next survivor")
    }

    // MARK: - canvas persistence (FR-26)

    func testCanvasSaveAndLoadRoundTrips() {
        let store = makeStore()
        store.load()
        XCTAssertNil(store.loadCanvasPNG())

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03])
        store.saveCanvas(png)
        XCTAssertEqual(store.loadCanvasPNG(), png)
    }
}
