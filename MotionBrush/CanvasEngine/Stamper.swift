import CoreGraphics
import Foundation

// =============================================================================
// Pure, Metal-free arc-length stamper (§11.2). Deliberately has zero
// dependencies on UIKit/Metal so it can be unit tested directly
// (MotionBrushTests/CanvasEngineTests.swift, §14 test #1).
// =============================================================================

/// A single frame's spacing-relevant width, as seen by the Stamper. Real
/// brushes derive this from `FrameEntry.rect[2]` (the frame's native pixel
/// width); tests synthesize it directly.
struct StamperBrushFrame: Equatable {
    let width: CGFloat
}

/// The minimal view of a brush the Stamper needs: an ordered list of frame
/// widths. `CanvasRenderer` builds one of these from a loaded `RuntimeBrush`;
/// tests build one directly with synthetic widths.
struct StamperBrush: Equatable {
    let frames: [StamperBrushFrame]
    var frameCount: Int { frames.count }
}

/// One positioned stamp: where its brush frame's anchor should land on the
/// canvas, and which frame of the brush to draw.
struct Stamp: Equatable {
    let center: CGPoint
    let frame: Int
}

/// Arc-length stamper — mirrors the §11.2 pseudocode exactly (including the
/// quirk that `spacing` is computed once per polyline segment, from the frame
/// index active at the *start* of that segment, even though `frameIdx` may
/// advance multiple times within the segment's while-loop). This exact
/// behavior is what CanvasEngineTests pins down for determinism.
///
/// `residual` (distance carried over from the previous `consume` call) and
/// `frameIdx` (which loops forward across `brush.frameCount`) both persist
/// across calls so a stroke can be fed in touch-batch-sized chunks.
struct Stamper {
    private(set) var residual: CGFloat = 0
    private(set) var frameIdx: Int = 0

    init() {}

    /// FR-20: frame index (and residual) resets at the start of every stroke.
    /// `K.resetFrameIndexPerStroke` is true in MVP; scaffolded for a future
    /// mode where a brush could continue its cycle across strokes.
    mutating func resetForNewStroke() {
        residual = 0
        if K.resetFrameIndexPerStroke {
            frameIdx = 0
        }
    }

    /// Consumes a flattened polyline (already Catmull-Rom smoothed) and
    /// returns the stamps produced along it, advancing `residual`/`frameIdx`.
    @discardableResult
    mutating func consume(polyline: [CGPoint], brush: StamperBrush) -> [Stamp] {
        guard brush.frameCount > 0, polyline.count >= 2 else { return [] }
        var out: [Stamp] = []
        for i in 0..<(polyline.count - 1) {
            let p0 = polyline[i]
            let p1 = polyline[i + 1]
            let d = Stamper.distance(p0, p1)
            guard d > 0 else { continue }
            var t0: CGFloat = 0
            // K.velocitySpacing is false in MVP: spacing is purely a function
            // of the current frame's width, per §11.2. (Velocity modulation
            // is a scaffolded post-MVP hook, §16 — deliberately not wired.)
            let width = brush.frames[frameIdx].width
            let spacing = width * K.spacingFactor
            guard spacing > 0 else { residual += d - t0; continue }
            while residual + (d - t0) >= spacing {
                t0 += spacing - residual
                residual = 0
                let p = Stamper.lerp(p0, p1, t0 / d)
                out.append(Stamp(center: p, frame: frameIdx))
                frameIdx = (frameIdx + 1) % brush.frameCount
            }
            residual += d - t0
        }
        return out
    }

    /// E8: a tap with no movement places a single frame-0 stamp.
    func tapStamp(at point: CGPoint) -> Stamp {
        Stamp(center: point, frame: 0)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}
