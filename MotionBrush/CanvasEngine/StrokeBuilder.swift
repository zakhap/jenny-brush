import CoreGraphics
import Foundation

// =============================================================================
// Touch (or synthetic) point stream → smoothed polyline → Stamper (§11.2).
// =============================================================================

/// Centripetal Catmull-Rom smoothing (α = 0.5), flattened to line segments.
/// Pure geometry, independent of UIKit/Metal.
enum CatmullRom {
    /// Smooths `points` and flattens each interior segment into `stepsPerSegment`
    /// line steps. Requires at least 2 points; returns `points` unchanged if
    /// fewer than 3 (nothing to smooth between).
    static func smooth(points: [CGPoint], stepsPerSegment: Int = 8) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        guard points.count >= 3 else { return points }

        // Duplicate the endpoints so every real point gets a full [p0,p1,p2,p3]
        // neighborhood (standard open-curve Catmull-Rom extension).
        let extended = [points[0]] + points + [points[points.count - 1]]
        var result: [CGPoint] = []
        for i in 1..<(extended.count - 2) {
            let p0 = extended[i - 1]
            let p1 = extended[i]
            let p2 = extended[i + 1]
            let p3 = extended[i + 2]
            let segment = centripetalSegment(p0: p0, p1: p1, p2: p2, p3: p3, steps: stepsPerSegment)
            if result.isEmpty {
                result.append(contentsOf: segment)
            } else {
                result.append(contentsOf: segment.dropFirst())
            }
        }
        return result
    }

    private static func centripetalSegment(p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, steps: Int) -> [CGPoint] {
        func tj(_ ti: CGFloat, _ pi: CGPoint, _ pj: CGPoint) -> CGFloat {
            let dx = pj.x - pi.x
            let dy = pj.y - pi.y
            let l = pow(dx * dx + dy * dy, 0.25) // distance^(alpha/2), alpha = 0.5
            return ti + max(l, 1e-4)
        }
        let t0: CGFloat = 0
        let t1 = tj(t0, p0, p1)
        let t2 = tj(t1, p1, p2)
        let t3 = tj(t2, p2, p3)

        guard steps > 0 else { return [p1, p2] }
        var out: [CGPoint] = []
        out.reserveCapacity(steps + 1)
        for s in 0...steps {
            let t = t1 + (t2 - t1) * CGFloat(s) / CGFloat(steps)
            let a1 = interp(p0, p1, t0, t1, t)
            let a2 = interp(p1, p2, t1, t2, t)
            let a3 = interp(p2, p3, t2, t3, t)
            let b1 = interp(a1, a2, t0, t2, t)
            let b2 = interp(a2, a3, t1, t3, t)
            let c = interp(b1, b2, t1, t2, t)
            out.append(c)
        }
        return out
    }

    private static func interp(_ p0: CGPoint, _ p1: CGPoint, _ t0: CGFloat, _ t1: CGFloat, _ t: CGFloat) -> CGPoint {
        guard t1 != t0 else { return p0 }
        let a = (t1 - t) / (t1 - t0)
        let b = (t - t0) / (t1 - t0)
        return CGPoint(x: a * p0.x + b * p1.x, y: a * p0.y + b * p1.y)
    }
}

/// Owns one stroke's lifecycle: raw touch points in → smoothed polyline →
/// Stamper. Persists the Stamper across touch batches so residual/frameIdx
/// carry over for the whole stroke (§11.2). Predicted-touch stamps are
/// computed from a scratch copy of the Stamper so they never affect the
/// authoritative confirmed state (they are display-only and get dropped the
/// moment the next real batch arrives, per §11.1).
final class StrokeBuilder {
    private(set) var confirmedStamps: [Stamp] = []

    private var stamper = Stamper()
    private var rawPoints: [CGPoint] = []
    private var processedPolylineCount = 0
    private var brush: StamperBrush
    private var hasMoved = false
    private var startPoint: CGPoint = .zero

    init(brush: StamperBrush) {
        self.brush = brush
    }

    /// touchesBegan-equivalent. Resets all per-stroke state (FR-20).
    func begin(at point: CGPoint) {
        rawPoints = [point]
        stamper = Stamper()
        stamper.resetForNewStroke()
        confirmedStamps = []
        processedPolylineCount = 0
        hasMoved = false
        startPoint = point
    }

    /// touchesMoved-equivalent — feed coalesced real points. Returns the new
    /// stamps produced by this batch (for incremental committed-texture-free
    /// live rendering).
    @discardableResult
    func addPoints(_ points: [CGPoint]) -> [Stamp] {
        guard !points.isEmpty else { return [] }
        hasMoved = true
        rawPoints.append(contentsOf: points)

        let polyline = CatmullRom.smooth(points: rawPoints, stepsPerSegment: 8)
        guard polyline.count > processedPolylineCount else { return [] }

        // Overlap by one point so the new slice connects to the last
        // already-processed polyline point (keeps arc length continuous).
        let startIdx = max(processedPolylineCount - 1, 0)
        let newSlice = Array(polyline[startIdx...])
        processedPolylineCount = polyline.count
        guard newSlice.count >= 2 else { return [] }

        let newStamps = stamper.consume(polyline: newSlice, brush: brush)
        confirmedStamps.append(contentsOf: newStamps)
        return newStamps
    }

    /// Ephemeral preview stamps from UIKit's predicted touches. Never mutates
    /// the authoritative Stamper/confirmedStamps — recomputed from scratch
    /// each call and meant to be discarded wholesale on the next real batch.
    func predictedStamps(for predictedPoints: [CGPoint]) -> [Stamp] {
        guard hasMoved, !predictedPoints.isEmpty, let last = rawPoints.last else { return [] }
        var scratch = stamper
        let context = [last] + predictedPoints
        let polyline = CatmullRom.smooth(points: context, stepsPerSegment: 8)
        guard polyline.count >= 2 else { return [] }
        return scratch.consume(polyline: polyline, brush: brush)
    }

    /// touchesEnded/touchesCancelled-equivalent. Returns the final,
    /// authoritative stamp list for the whole stroke (E6: cancellation
    /// commits as-is). E8: a tap with no movement yields one frame-0 stamp.
    func end() -> [Stamp] {
        if !hasMoved {
            confirmedStamps = [stamper.tapStamp(at: startPoint)]
        }
        return confirmedStamps
    }
}
