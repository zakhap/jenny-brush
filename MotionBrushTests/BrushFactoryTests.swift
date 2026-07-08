import AVFoundation
import CoreGraphics
import XCTest
@testable import MotionBrush

/// Rigorous unit tests for BrushFactory's pure logic (§14):
/// (1) the IoU subject picker, (2) AtlasPacker shelf-packing, (3) manifest
/// round-trip through AtlasPacker's builder. A best-effort synthetic-video
/// smoke test is included at the bottom but never asserts on Vision finding a
/// subject (per the task brief: real end-to-end validation happens later with
/// camera input).
final class BrushFactoryTests: XCTestCase {

    // MARK: - Helpers

    /// A trivial square mask centered at `center` (normalized 0...1) with the
    /// given normalized radius, rendered into a `size x size` grid.
    private func mask(size: Int, centerX: Double, centerY: Double, radius: Double) -> BinaryMask {
        var bits = [Bool](repeating: false, count: size * size)
        let cx = centerX * Double(size)
        let cy = centerY * Double(size)
        let r = radius * Double(size)
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) + 0.5 - cx
                let dy = Double(y) + 0.5 - cy
                if abs(dx) <= r, abs(dy) <= r {
                    bits[y * size + x] = true
                }
            }
        }
        return BinaryMask(width: size, height: size, bits: bits)
    }

    private func candidate(
        instance: Int, centerX: Double, centerY: Double, radius: Double, size: Int = 32
    ) -> SubjectCandidate {
        let m = mask(size: size, centerX: centerX, centerY: centerY, radius: radius)
        let onCount = m.bits.filter { $0 }.count
        let area = Double(onCount) / Double(size * size)
        let bbox = CGRect(
            x: centerX - radius, y: centerY - radius, width: radius * 2, height: radius * 2)
        return SubjectCandidate(instanceIndex: instance, bbox: bbox, area: area, mask: m)
    }

    // MARK: - IoU picker: first-frame dominant pick

    func testFirstFrameDominantPickChoosesHighestScoreAboveAreaGate() {
        // A big, centered subject should beat a bigger-but-off-center subject
        // once center bias is applied, and both beat a tiny subject that fails
        // the area gate outright is not in this candidate set — this test
        // isolates the score comparison.
        let centered = candidate(instance: 1, centerX: 0.5, centerY: 0.5, radius: 0.2)
        let offCenter = candidate(instance: 2, centerX: 0.9, centerY: 0.9, radius: 0.2)

        let (pick, state) = SubjectPicker.pick(candidates: [centered, offCenter], previous: .none)

        XCTAssertEqual(pick, .hit(instanceIndex: 1))
        guard case .tracking(let bbox, _) = state else {
            return XCTFail("expected tracking state after a hit")
        }
        XCTAssertEqual(bbox.midX, 0.5, accuracy: 0.05)
    }

    func testFirstFrameMissWhenAllCandidatesBelowAreaGate() {
        // K.minSubjectArea is 0.005 (0.5%); a radius this small yields area
        // far below that.
        let tiny = candidate(instance: 1, centerX: 0.5, centerY: 0.5, radius: 0.01)

        let (pick, state) = SubjectPicker.pick(candidates: [tiny], previous: .none)

        XCTAssertEqual(pick, .miss)
        XCTAssertEqual(state, .none, "state must not advance on a gate-failure miss")
    }

    func testEmptyCandidatesAlwaysMissesAndPreservesState() {
        let priorState = TrackState.tracking(
            bbox: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2),
            mask: mask(size: 16, centerX: 0.4, centerY: 0.4, radius: 0.1))

        let (pick, state) = SubjectPicker.pick(candidates: [], previous: priorState)

        XCTAssertEqual(pick, .miss)
        XCTAssertEqual(state, priorState)
    }

    // MARK: - IoU picker: tracking pick

    func testTrackingPickPrefersMaskIoUAmongGatedCandidates() {
        let size = 32
        let previousMask = mask(size: size, centerX: 0.5, centerY: 0.5, radius: 0.2)
        let previousState = TrackState.tracking(
            bbox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), mask: previousMask)

        // Both candidates pass the bbox-IoU gate (nearby), but "closeMatch"
        // has near-identical mask overlap with the previous mask, while
        // "shifted" overlaps less.
        let closeMatch = candidate(instance: 1, centerX: 0.51, centerY: 0.51, radius: 0.2, size: size)
        let shifted = candidate(instance: 2, centerX: 0.65, centerY: 0.65, radius: 0.2, size: size)

        let (pick, state) = SubjectPicker.pick(candidates: [closeMatch, shifted], previous: previousState)

        XCTAssertEqual(pick, .hit(instanceIndex: 1))
        guard case .tracking = state else { return XCTFail("expected tracking state") }
    }

    func testTrackingGateExcludesCandidateBelowMinTrackIoU() {
        let size = 32
        let previousMask = mask(size: size, centerX: 0.1, centerY: 0.1, radius: 0.08)
        let previousState = TrackState.tracking(
            bbox: CGRect(x: 0.02, y: 0.02, width: 0.16, height: 0.16), mask: previousMask)

        // Far away in frame — should fail the bbox IoU gate against the tiny
        // previous bbox even though it's a big, well-centered subject, and
        // thus must NOT be picked by the tracking branch's gated comparison
        // (it can still resurface via the reacquire fallback — verified in
        // a separate test with zero passing candidates).
        let farAway = candidate(instance: 9, centerX: 0.9, centerY: 0.9, radius: 0.05, size: size)
        let nearMatch = candidate(instance: 1, centerX: 0.11, centerY: 0.11, radius: 0.08, size: size)

        let (pick, _) = SubjectPicker.pick(candidates: [farAway, nearMatch], previous: previousState)

        XCTAssertEqual(pick, .hit(instanceIndex: 1), "must track the gated candidate, not the ungated one")
    }

    // MARK: - IoU picker: gate-failure reacquisition

    func testGateFailureReacquiresViaDominantPickRule() {
        let previousMask = mask(size: 32, centerX: 0.1, centerY: 0.1, radius: 0.05)
        let previousState = TrackState.tracking(
            bbox: CGRect(x: 0.05, y: 0.05, width: 0.1, height: 0.1), mask: previousMask)

        // Nothing near the old bbox — subject "jumped". Should reacquire via
        // dominant-pick (big, centered) rather than emit a miss.
        let jumped = candidate(instance: 5, centerX: 0.5, centerY: 0.5, radius: 0.25, size: 32)

        let (pick, state) = SubjectPicker.pick(candidates: [jumped], previous: previousState)

        XCTAssertEqual(pick, .hit(instanceIndex: 5))
        guard case .tracking(let bbox, _) = state else { return XCTFail("expected tracking state") }
        XCTAssertEqual(bbox.midX, 0.5, accuracy: 0.05)
    }

    func testGateFailureReacquisitionCanStillMissIfBelowAreaGate() {
        let previousMask = mask(size: 32, centerX: 0.1, centerY: 0.1, radius: 0.05)
        let previousState = TrackState.tracking(
            bbox: CGRect(x: 0.05, y: 0.05, width: 0.1, height: 0.1), mask: previousMask)

        // Far away AND tiny — fails the gate, and the reacquire fallback's
        // own area gate also fails, so this must resolve as a miss (state
        // unchanged) rather than a spurious hit.
        let tinyAndFar = candidate(instance: 5, centerX: 0.9, centerY: 0.9, radius: 0.01, size: 32)

        let (pick, state) = SubjectPicker.pick(candidates: [tinyAndFar], previous: previousState)

        XCTAssertEqual(pick, .miss)
        XCTAssertEqual(state, previousState)
    }

    // MARK: - BinaryMask IoU sanity

    func testBinaryMaskIoUIdenticalMasksIsOne() {
        let m = mask(size: 16, centerX: 0.5, centerY: 0.5, radius: 0.2)
        XCTAssertEqual(BinaryMask.iou(m, m), 1.0, accuracy: 0.0001)
    }

    func testBinaryMaskIoUDisjointMasksIsZero() {
        let a = mask(size: 16, centerX: 0.1, centerY: 0.1, radius: 0.05)
        let b = mask(size: 16, centerX: 0.9, centerY: 0.9, radius: 0.05)
        XCTAssertEqual(BinaryMask.iou(a, b), 0.0, accuracy: 0.0001)
    }

    func testBboxIoUKnownValue() {
        let a = CGRect(x: 0, y: 0, width: 1, height: 1)
        let b = CGRect(x: 0.5, y: 0, width: 1, height: 1)
        // Intersection area 0.5, union area 1.5 => IoU = 1/3
        XCTAssertEqual(SubjectPicker.bboxIoU(a, b), 1.0 / 3.0, accuracy: 0.0001)
    }

    // MARK: - AtlasPacker: shelf packing

    func testShelfPackerPlacesAllRectsWithinPageBounds() {
        var sizes: [(index: Int, size: CGSize)] = []
        for i in 0..<40 {
            let w: CGFloat = CGFloat(80 + (i % 5) * 40)
            let h: CGFloat = CGFloat(60 + (i % 7) * 30)
            sizes.append((index: i, size: CGSize(width: w, height: h)))
        }
        let pageEdge = 512
        let gutter = 2
        let placements = ShelfPacker.pack(sizes: sizes, pageEdge: pageEdge, gutter: gutter)

        XCTAssertEqual(placements.count, sizes.count)
        for p in placements {
            XCTAssertGreaterThanOrEqual(p.rect.x, gutter)
            XCTAssertGreaterThanOrEqual(p.rect.y, gutter)
            XCTAssertLessThanOrEqual(p.rect.x + p.rect.width + gutter, pageEdge)
            XCTAssertLessThanOrEqual(p.rect.y + p.rect.height + gutter, pageEdge)
        }
    }

    func testShelfPackerRectsDoNotOverlapOnTheSamePage() {
        var sizes: [(index: Int, size: CGSize)] = []
        for i in 0..<30 {
            let w: CGFloat = CGFloat(100 + (i % 3) * 50)
            let h: CGFloat = CGFloat(90 + (i % 4) * 20)
            sizes.append((index: i, size: CGSize(width: w, height: h)))
        }
        let placements = ShelfPacker.pack(sizes: sizes, pageEdge: 512, gutter: 2)

        let byPage = Dictionary(grouping: placements, by: { $0.page })
        for (_, group) in byPage {
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    let a = group[i].rect
                    let b = group[j].rect
                    let overlapsX = a.x < b.x + b.width && b.x < a.x + a.width
                    let overlapsY = a.y < b.y + b.height && b.y < a.y + a.height
                    XCTAssertFalse(overlapsX && overlapsY, "rects \(a) and \(b) overlap")
                }
            }
        }
    }

    func testShelfPackerRespectsGutterBetweenAdjacentRects() {
        // Two items that fit on the same shelf row; verify the horizontal gap
        // between them is at least `gutter`.
        let sizes: [(index: Int, size: CGSize)] = [
            (0, CGSize(width: 100, height: 100)),
            (1, CGSize(width: 100, height: 100)),
        ]
        let gutter = 2
        let placements = ShelfPacker.pack(sizes: sizes, pageEdge: 512, gutter: gutter)
            .sorted { $0.rect.x < $1.rect.x }

        XCTAssertEqual(placements.count, 2)
        let gap = placements[1].rect.x - (placements[0].rect.x + placements[0].rect.width)
        XCTAssertGreaterThanOrEqual(gap, gutter)
    }

    func testShelfPackerOverflowsToASecondPage() {
        // Items sized so only one fits per page at all (page edge barely
        // bigger than one item) forces each item onto its own page.
        let pageEdge = 110
        let sizes: [(index: Int, size: CGSize)] = (0..<3).map { ($0, CGSize(width: 100, height: 100)) }
        let placements = ShelfPacker.pack(sizes: sizes, pageEdge: pageEdge, gutter: 2)

        let pages = Set(placements.map(\.page))
        XCTAssertEqual(pages.count, 3, "each oversized-relative-to-page item should land on its own page")
    }

    // MARK: - Manifest round-trip via AtlasPacker

    func testAtlasPackerManifestRoundTripsThroughJSON() throws {
        let stampA = StampData(
            index: 0, cgImage: Self.solidCGImage(width: 40, height: 60),
            anchor: CGPoint(x: 20, y: 30), pixelSize: CGSize(width: 40, height: 60), duplicateOf: nil)
        let stampB = StampData(
            index: 1, cgImage: Self.solidCGImage(width: 50, height: 70),
            anchor: CGPoint(x: 25, y: 35), pixelSize: CGSize(width: 50, height: 70), duplicateOf: nil)
        // A miss frame duplicating stampA's pixels.
        let stampDup = StampData(
            index: 2, cgImage: stampA.cgImage, anchor: stampA.anchor,
            pixelSize: stampA.pixelSize, duplicateOf: 0)

        let packed = AtlasPacker.build(
            stamps: [stampA, stampB, stampDup], brushID: "test-brush", name: "Brush 1",
            sourceDuration: 2.5, createdAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(packed.manifest.frameCount, 3)
        XCTAssertEqual(packed.manifest.atlasPages.count, packed.pageImages.count)
        XCTAssertFalse(packed.pageImages.isEmpty)

        // Duplicate frame must share its source frame's rect and record duplicateOf.
        let dupEntry = try XCTUnwrap(packed.manifest.frames.first { $0.i == 2 })
        let sourceEntry = try XCTUnwrap(packed.manifest.frames.first { $0.i == 0 })
        XCTAssertEqual(dupEntry.rect, sourceEntry.rect)
        XCTAssertEqual(dupEntry.duplicateOf, 0)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(packed.manifest)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BrushManifest.self, from: data)

        XCTAssertEqual(decoded, packed.manifest)
    }

    private static func solidCGImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // MARK: - Best-effort pipeline smoke test (synthetic fixture video)

    /// Runs the full pipeline against a tiny synthesized clip. This does NOT
    /// assert Vision finds a subject on synthetic (non-photographic) content
    /// — only that the pipeline either produces a well-formed asset or fails
    /// with `.noSubject`, and never crashes or hangs. Real end-to-end
    /// validation happens later with camera input.
    func testPipelineSmokeTestOnSyntheticClip() async throws {
        guard let url = try? Self.makeSyntheticClip() else {
            throw XCTSkip("could not synthesize a fixture clip in this environment")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let factory = BrushFactory()
        var builtAsset: BrushAsset?
        do {
            for try await progress in factory.makeBrush(from: url, name: "Test Brush", brushID: UUID().uuidString) {
                if case .built(let asset) = progress {
                    builtAsset = asset
                }
            }
        } catch BrushError.noSubject {
            // Acceptable on synthetic content — Vision may find nothing usable.
            return
        } catch {
            XCTFail("pipeline threw an unexpected error on synthetic input: \(error)")
            return
        }

        if let asset = builtAsset {
            XCTAssertTrue(FileManager.default.fileExists(atPath: asset.manifestURL.path))
            try? FileManager.default.removeItem(at: asset.directoryURL)
        }
    }

    /// Synthesizes a ~1.5s, 320x480, solid-color-with-moving-square clip using
    /// AVAssetWriter so the smoke test has no bundled fixture dependency.
    private static func makeSyntheticClip() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = 320, height = 480
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameCount = 30
        for i in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                usleep(1000)
            }
            var pixelBufferOut: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &pixelBufferOut)
            guard let pixelBuffer = pixelBufferOut else { continue }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                // Fill white, draw a moving dark square as a pseudo-"subject".
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = y * bytesPerRow + x * 4
                        ptr[offset] = 255
                        ptr[offset + 1] = 255
                        ptr[offset + 2] = 255
                        ptr[offset + 3] = 255
                    }
                }
                let squareX = 40 + (i * 4) % (width - 100)
                let squareY = height / 2 - 50
                for y in squareY..<(squareY + 100) where y >= 0 && y < height {
                    for x in squareX..<(squareX + 100) where x >= 0 && x < width {
                        let offset = y * bytesPerRow + x * 4
                        ptr[offset] = 255
                        ptr[offset + 1] = 20
                        ptr[offset + 2] = 20
                        ptr[offset + 3] = 20
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let time = CMTime(value: Int64(i), timescale: 15)
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        return url
    }
}
