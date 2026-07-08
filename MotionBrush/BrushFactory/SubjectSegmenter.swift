import CoreGraphics
import CoreVideo
import Foundation
import Vision

// =============================================================================
// Pure, testable selection core (§9.4).
//
// Everything down to `SubjectPicker.pick` has no Vision/CoreImage dependency
// so BrushFactoryTests can drive it with synthetic candidate sets.
// =============================================================================

/// A small occupancy grid used for cheap mask-IoU comparisons at
/// `K.maskCompareEdge` resolution. Row-major, top-left origin.
struct BinaryMask: Equatable {
    let width: Int
    let height: Int
    let bits: [Bool]

    init(width: Int, height: Int, bits: [Bool]) {
        precondition(bits.count == width * height, "BinaryMask bits must be width*height")
        self.width = width
        self.height = height
        self.bits = bits
    }

    /// Intersection-over-union of two same-sized masks. Masks of mismatched
    /// size are treated as non-overlapping (IoU 0) rather than trapping,
    /// since a mismatch only happens if callers mix comparison resolutions.
    static func iou(_ a: BinaryMask, _ b: BinaryMask) -> Double {
        guard a.width == b.width, a.height == b.height, !a.bits.isEmpty else { return 0 }
        var intersection = 0
        var union = 0
        for i in 0..<a.bits.count {
            let x = a.bits[i]
            let y = b.bits[i]
            if x || y { union += 1 }
            if x && y { intersection += 1 }
        }
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }
}

/// One instance candidate for a single frame, evaluated at the cheap
/// `K.maskCompareEdge` comparison resolution (§9.4).
struct SubjectCandidate: Equatable {
    let instanceIndex: Int
    let bbox: CGRect     // normalized [0,1] frame coordinates
    let area: Double     // fraction of frame pixels "on" in the comparison mask
    let mask: BinaryMask

    init(instanceIndex: Int, bbox: CGRect, area: Double, mask: BinaryMask) {
        self.instanceIndex = instanceIndex
        self.bbox = bbox
        self.area = area
        self.mask = mask
    }
}

/// Result of picking a subject for one frame.
enum SubjectPick: Equatable {
    case hit(instanceIndex: Int)
    case miss
}

/// Temporal tracking state carried between frames (§9.4).
enum TrackState: Equatable {
    case none
    case tracking(bbox: CGRect, mask: BinaryMask)
}

/// Pure implementation of the temporal-anchoring selection algorithm in §9.4:
/// first usable frame picks the dominant subject; subsequent frames track by
/// bbox-IoU gate refined with mask IoU; a gate failure reacquires via the
/// dominant-pick rule rather than giving up.
enum SubjectPicker {
    /// Dominant-subject scoring (§9.4), used both for the first usable frame
    /// and as the reacquisition fallback when tracking loses the subject.
    /// Returns nil if no candidate clears `K.minSubjectArea`.
    static func dominantPick(among candidates: [SubjectCandidate]) -> SubjectCandidate? {
        guard !candidates.isEmpty else { return nil }
        var best: (score: Double, candidate: SubjectCandidate)?
        for c in candidates {
            let dx = c.bbox.midX - 0.5
            let dy = c.bbox.midY - 0.5
            let distanceToCenter = (dx * dx + dy * dy).squareRoot()
            let score = c.area * (1.0 - K.centerBias * distanceToCenter)
            if best == nil || score > best!.score {
                best = (score, c)
            }
        }
        guard let winner = best, winner.candidate.area >= K.minSubjectArea else { return nil }
        return winner.candidate
    }

    /// Normalized bbox IoU — the cheap gate before the mask-IoU refine.
    static func bboxIoU(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        guard unionArea > 0 else { return 0 }
        return Double(interArea / unionArea)
    }

    /// Runs one frame of the §9.4 algorithm. `candidates` empty means the
    /// observation had zero instances (emit `.miss`, state unchanged — the
    /// next real frame still tracks against the last known-good bbox/mask).
    static func pick(
        candidates: [SubjectCandidate], previous: TrackState
    ) -> (pick: SubjectPick, state: TrackState) {
        guard !candidates.isEmpty else {
            return (.miss, previous)
        }

        switch previous {
        case .none:
            guard let winner = dominantPick(among: candidates) else {
                return (.miss, previous)
            }
            return (.hit(instanceIndex: winner.instanceIndex), .tracking(bbox: winner.bbox, mask: winner.mask))

        case .tracking(let prevBBox, let prevMask):
            let gated = candidates.filter { bboxIoU($0.bbox, prevBBox) >= K.minTrackIoU }
            guard !gated.isEmpty else {
                // Subject may have jumped: reacquire rather than miss.
                guard let winner = dominantPick(among: candidates) else {
                    return (.miss, previous)
                }
                return (.hit(instanceIndex: winner.instanceIndex), .tracking(bbox: winner.bbox, mask: winner.mask))
            }
            var best: (iou: Double, candidate: SubjectCandidate)?
            for c in gated {
                let iou = BinaryMask.iou(c.mask, prevMask)
                if best == nil || iou > best!.iou {
                    best = (iou, c)
                }
            }
            let winner = best!.candidate
            return (.hit(instanceIndex: winner.instanceIndex), .tracking(bbox: winner.bbox, mask: winner.mask))
        }
    }
}

// =============================================================================
// Vision-facing wrapper (§9.4).
// =============================================================================

/// Stage 2: per-frame `VNGenerateForegroundInstanceMaskRequest` with temporal
/// anchoring. Wraps `SubjectPicker` with real Vision calls, producing the
/// full-resolution matte for the picked instance only.
final class SubjectSegmenter {
    enum Outcome {
        /// A usable instance was picked; `matte` is the full-resolution
        /// single-channel mask for that instance only (for StampProcessor).
        case hit(matte: CVPixelBuffer)
        case miss
    }

    private var state: TrackState = .none

    /// Count of `.hit` frames so far — gates FR-10 (`K.minUsableFrames`).
    private(set) var hitCount = 0

    /// Segments one upright frame, updating internal tracking state. Never
    /// throws: a Vision failure for a single frame is treated as a `.miss`
    /// (§13 — only accumulated hit count below `K.minUsableFrames` fails the
    /// whole job).
    func process(_ pixelBuffer: CVPixelBuffer) -> Outcome {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            return .miss
        }
        guard let observation = request.results?.first else {
            return .miss
        }

        let instances = observation.allInstances
        guard !instances.isEmpty else { return .miss }

        guard let candidates = Self.buildCandidates(observation: observation, instances: instances) else {
            return .miss
        }

        let (pickResult, newState) = SubjectPicker.pick(candidates: candidates, previous: state)
        state = newState

        switch pickResult {
        case .miss:
            return .miss
        case .hit(let instanceIndex):
            do {
                let matte = try observation.generateScaledMaskForImage(
                    forInstances: IndexSet(integer: instanceIndex), from: handler)
                hitCount += 1
                return .hit(matte: matte)
            } catch {
                return .miss
            }
        }
    }

    // MARK: - Candidate construction from the cheap instance-label buffer

    private static func buildCandidates(
        observation: VNInstanceMaskObservation, instances: IndexSet
    ) -> [SubjectCandidate]? {
        guard let grid = LabelGrid(pixelBuffer: observation.instanceMask, longestEdge: K.maskCompareEdge) else {
            return nil
        }

        var candidates: [SubjectCandidate] = []
        for instance in instances {
            var bits = [Bool](repeating: false, count: grid.width * grid.height)
            var minX = grid.width, maxX = -1, minY = grid.height, maxY = -1
            var onCount = 0
            for y in 0..<grid.height {
                let rowBase = y * grid.width
                for x in 0..<grid.width {
                    guard grid.values[rowBase + x] == instance else { continue }
                    bits[rowBase + x] = true
                    onCount += 1
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
            guard onCount > 0 else { continue }
            let area = Double(onCount) / Double(grid.width * grid.height)
            let bbox = CGRect(
                x: Double(minX) / Double(grid.width),
                y: Double(minY) / Double(grid.height),
                width: Double(maxX - minX + 1) / Double(grid.width),
                height: Double(maxY - minY + 1) / Double(grid.height)
            )
            candidates.append(SubjectCandidate(
                instanceIndex: instance, bbox: bbox, area: area,
                mask: BinaryMask(width: grid.width, height: grid.height, bits: bits)))
        }
        return candidates.isEmpty ? nil : candidates
    }
}

/// Nearest-neighbor-sampled view over Vision's low-resolution instance-label
/// buffer, downsampled (if needed) to `K.maskCompareEdge` on the longest edge.
/// Label buffers must never be filtered/interpolated (values are instance
/// indices, not intensities) — hence manual nearest-neighbor rather than
/// CoreImage/Lanczos scaling. Handles the plausible pixel formats for
/// `VNInstanceMaskObservation.instanceMask` defensively since Apple does not
/// pin the exact format in the header.
private struct LabelGrid {
    let width: Int
    let height: Int
    let values: [Int]

    init?(pixelBuffer: CVPixelBuffer, longestEdge: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard srcWidth > 0, srcHeight > 0 else { return nil }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        func label(atX x: Int, y: Int) -> Int {
            let row = base + y * bytesPerRow
            switch format {
            case kCVPixelFormatType_OneComponent16:
                return Int(row.assumingMemoryBound(to: UInt16.self)[x])
            case kCVPixelFormatType_OneComponent32Float:
                return Int(row.assumingMemoryBound(to: Float32.self)[x].rounded())
            default: // kCVPixelFormatType_OneComponent8 and any other 8bpp label buffer
                return Int(row.assumingMemoryBound(to: UInt8.self)[x])
            }
        }

        let scale = Double(longestEdge) / Double(max(srcWidth, srcHeight))
        let dstWidth = scale < 1 ? max(1, Int((Double(srcWidth) * scale).rounded())) : srcWidth
        let dstHeight = scale < 1 ? max(1, Int((Double(srcHeight) * scale).rounded())) : srcHeight

        var out = [Int](repeating: 0, count: dstWidth * dstHeight)
        for dy in 0..<dstHeight {
            let sy = min(srcHeight - 1, Int(Double(dy) * Double(srcHeight) / Double(dstHeight)))
            for dx in 0..<dstWidth {
                let sx = min(srcWidth - 1, Int(Double(dx) * Double(srcWidth) / Double(dstWidth)))
                out[dy * dstWidth + dx] = label(atX: sx, y: sy)
            }
        }
        self.width = dstWidth
        self.height = dstHeight
        self.values = out
    }
}
