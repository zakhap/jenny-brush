import CoreGraphics
import Foundation

/// Every tunable in the spec's §T table lives here — and NOWHERE else.
/// Do not scatter magic numbers through the modules; reference `K.x`.
enum K {
    // MARK: Sampling (FR-7)
    static let samplingFPS: Double = 12
    static let maxFrames: Int = 96

    // MARK: Capture (FR-2)
    static let minClipSec: Double = 1.0
    static let maxClipSec: Double = 8.0

    // MARK: Segmentation / tracking (§9.4)
    static let minSubjectArea: Double = 0.005   // fraction of frame, first-frame gate
    static let centerBias: Double = 0.5         // first-frame dominant scoring
    static let minTrackIoU: Double = 0.10       // bbox gate before mask-IoU refine
    static let maskCompareEdge: Int = 128       // px, cheap comparison mask size
    static let minUsableFrames: Int = 8         // FR-10: fewer than this → noSubject

    // MARK: Stamp production (FR-11)
    static let cropPadding: Double = 0.04       // of crop's longest side
    static let maxStampEdge: Int = 512          // px

    // MARK: Atlas (§9.6)
    static let atlasPageEdge: Int = 4096        // px
    static let atlasGutter: Int = 2             // px between rects

    // MARK: Drawing (FR-20)
    static let spacingFactor: CGFloat = 0.12    // × current (rendered) frame width — tighter = denser stamps
    static let stampScale: CGFloat = 0.72       // display scale applied to every stamp (smaller than native)
    static let resetFrameIndexPerStroke = true
    static let rotateToTangent = false          // scaffolded, off in MVP
    static let velocitySpacing = false          // scaffolded, off in MVP

    // MARK: Undo / demo (FR-23, FR-24)
    static let undoDepth: Int = 20
    static let demoStrokeDuration: Double = 1.5 // seconds

    // MARK: Canvas
    static let canvasScale: CGFloat = 2.0       // canvas px = point size × 2 (FR-19)

    // MARK: Shelf preview (§10.4)
    static let previewStampCount: Int = 12
    static let previewSize = CGSize(width: 240, height: 120)  // points
}
