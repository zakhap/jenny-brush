import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

// =============================================================================
// FROZEN CONTRACTS — the interface between modules.
//
// Parallel agents building CanvasEngine / BrushFactory / BrushStore /
// CaptureService MUST NOT modify this file. If you believe a contract needs to
// change, STOP and report it — do not edit here (it would conflict across
// worktrees). Everything below is what crosses a module boundary.
// =============================================================================

// MARK: - Errors

/// Brush-creation failures (§13 error matrix).
enum BrushError: Error, Equatable {
    case noSubject          // FR-10: fewer than K.minUsableFrames usable frames
    case io                 // disk write failure (E9)
    case cancelled          // user backed out of processing (E5)
    case reader(String)     // AVAssetReader / Vision threw mid-job
}

/// Capture failures (§13).
enum CaptureError: Error, Equatable {
    case tooShort           // FR-2: clip < K.minClipSec, camera stays open
    case notAuthorized      // E1
    case noCamera
    case failed(String)
}

// MARK: - Camera authorization (E1)

enum CameraAuthStatus: Equatable {
    case notDetermined
    case authorized
    case denied
}

// MARK: - Pipeline intermediates (§9.3 – §9.5)

/// Output of FrameSampler (stage 1). Buffers are upright (preferredTransform applied).
struct SampledFrame {
    let index: Int
    let pixelBuffer: CVPixelBuffer
    let time: CMTime
}

/// Output of StampProcessor (stage 3) — one matted, cropped, premultiplied RGBA stamp.
struct StampData {
    let index: Int
    let cgImage: CGImage        // premultiplied RGBA cutout
    let anchor: CGPoint         // alpha-weighted centroid, in cropped-stamp px coords
    let pixelSize: CGSize       // stamp pixel dimensions (no size normalization, FR-11)
    let duplicateOf: Int?       // FR-9: miss frame reusing an earlier stamp's pixels
}

// MARK: - Persisted brush format (manifest.json, §10.2)

struct BrushManifest: Codable, Equatable {
    var schemaVersion: Int
    var id: String
    var name: String
    var createdAt: Date
    var frameCount: Int
    var sourceDuration: Double
    var suggestedSpacingFactor: Double
    var atlasPages: [String]        // filenames relative to brush dir, e.g. ["atlas-0.heic"]
    var frames: [FrameEntry]

    static let currentSchemaVersion = 1
}

struct FrameEntry: Codable, Equatable {
    var i: Int
    var page: Int
    var rect: [Int]        // [x, y, w, h] in atlas px
    var anchor: [Double]   // [x, y] in stamp px
    var duplicateOf: Int?  // nil for real frames; index of reused stamp for miss frames
}

// MARK: - Runtime brush handle

/// A brush as passed around the app: its manifest plus the directory holding its
/// atlas pages, preview, and manifest. During creation this points at a temp dir;
/// after BrushStore.commit it points at the permanent `Brushes/<id>/` dir.
struct BrushAsset: Identifiable, Equatable {
    let id: String
    var name: String
    let manifest: BrushManifest
    let directoryURL: URL

    var manifestURL: URL { directoryURL.appendingPathComponent("manifest.json") }
    var previewURL: URL { directoryURL.appendingPathComponent("preview.gif") }
    func atlasURL(page: Int) -> URL {
        directoryURL.appendingPathComponent(manifest.atlasPages[page])
    }
}

// MARK: - Processing progress (BrushFactory → ProcessingScreen "theater", FR-12)

enum BrushProgress {
    /// A freshly segmented cutout for the stacking animation. `total` is the
    /// expected final frame count so the theater can render "n of N".
    case frame(index: Int, total: Int, cutout: CGImage)
    /// Pipeline finished; the BrushAsset lives in a TEMP dir. The caller
    /// (BrushStore.commit) generates the preview and moves it into place.
    case built(BrushAsset)
}
