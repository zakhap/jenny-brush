import XCTest
@testable import MotionBrush

/// Placeholder so the test target compiles from the foundation on. Each Wave-1
/// agent adds its own tests (Stamper determinism, IoU picker, AtlasPacker,
/// BrushStore atomicity, manifest round-trip — §14).
final class FoundationTests: XCTestCase {
    func testConstantsPresent() {
        XCTAssertEqual(K.maxFrames, 96)
        // spacingFactor / stampScale are feel tunables — assert they're sane, not exact.
        XCTAssertGreaterThan(K.spacingFactor, 0)
        XCTAssertGreaterThan(K.stampScale, 0)
    }

    func testManifestRoundTrips() throws {
        let m = BrushManifest(
            schemaVersion: 1, id: "abc", name: "Brush 1",
            createdAt: Date(timeIntervalSince1970: 0), frameCount: 1,
            sourceDuration: 2, suggestedSpacingFactor: 0.4,
            atlasPages: ["atlas-0.heic"],
            frames: [FrameEntry(i: 0, page: 0, rect: [2, 2, 100, 120], anchor: [50, 60], duplicateOf: nil)]
        )
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(BrushManifest.self, from: data)
        XCTAssertEqual(m, back)
    }
}
