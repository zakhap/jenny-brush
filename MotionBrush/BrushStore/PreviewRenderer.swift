import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders the shelf preview animated GIF for a freshly built brush (§10.4).
///
/// Runs once at brush-creation time (inside `BrushStore.commit`, before the
/// brush's temp directory is moved into place). Composites a fixed
/// `K.previewStampCount`-stamp S-curve stroke into accumulating frames at
/// `K.previewSize` and encodes them as a looping GIF via ImageIO. Pure
/// CoreGraphics/ImageIO — no Metal — since this is a one-shot offline render,
/// not part of the live canvas.
enum PreviewRenderer {
    /// Reads `manifest`'s atlas pages out of `brushDirectory`, stamps a
    /// 12-frame S-curve stroke, and writes a looping GIF to `destinationURL`.
    static func renderPreviewGIF(
        manifest: BrushManifest,
        brushDirectory: URL,
        to destinationURL: URL
    ) throws {
        guard manifest.frameCount > 0, !manifest.frames.isEmpty else {
            throw BrushError.io
        }

        let pages = try loadAtlasPages(manifest: manifest, brushDirectory: brushDirectory)
        let framesByIndex = Dictionary(uniqueKeysWithValues: manifest.frames.map { ($0.i, $0) })

        // Scale so the largest native stamp reads at a sensible size inside the
        // small preview canvas (native atlas stamps can be up to 512 px, far
        // larger than the 240×120 pt preview).
        let maxEdgePx = manifest.frames
            .map { CGFloat(max($0.rect[2], $0.rect[3])) }
            .max() ?? 1
        let targetMaxEdge = K.previewSize.height * 0.6
        let displayScale = maxEdgePx > 0 ? targetMaxEdge / maxEdgePx : 1

        let planned = planStamps(manifest: manifest, framesByIndex: framesByIndex, displayScale: displayScale)
        guard let totalLength = planned.last?.cumulativeLength, totalLength > 0 else {
            throw BrushError.io
        }

        let renderScale: CGFloat = 2
        let pixelSize = CGSize(
            width: K.previewSize.width * renderScale,
            height: K.previewSize.height * renderScale
        )

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: Int(pixelSize.width),
                height: Int(pixelSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw BrushError.io
        }

        // White background, matching the canvas itself (FR-19).
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: pixelSize))

        var gifFrames: [CGImage] = []
        for stamp in planned {
            guard
                let entry = framesByIndex[stamp.frameIndex],
                entry.page >= 0, entry.page < pages.count
            else { continue }

            let rect = CGRect(x: entry.rect[0], y: entry.rect[1], width: entry.rect[2], height: entry.rect[3])
            guard let stampImage = pages[entry.page].cropping(to: rect) else { continue }

            let t = stamp.cumulativeLength / totalLength
            draw(
                stampImage,
                entry: entry,
                atPathT: t,
                displayScale: displayScale,
                renderScale: renderScale,
                pixelSize: pixelSize,
                into: context
            )

            if let snapshot = context.makeImage() {
                gifFrames.append(snapshot)
            }
        }

        guard !gifFrames.isEmpty else { throw BrushError.io }
        try encodeGIF(frames: gifFrames, to: destinationURL)
    }

    // MARK: - Atlas loading

    private static func loadAtlasPages(manifest: BrushManifest, brushDirectory: URL) throws -> [CGImage] {
        var pages: [CGImage] = []
        for pageName in manifest.atlasPages {
            let url = brushDirectory.appendingPathComponent(pageName)
            guard
                let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw BrushError.io
            }
            pages.append(image)
        }
        guard !pages.isEmpty else { throw BrushError.io }
        return pages
    }

    // MARK: - Stamp planning (mirrors the production arc-length stamper, §11.2)

    private struct PlannedStamp {
        let frameIndex: Int
        let cumulativeLength: CGFloat
    }

    /// Lays out `K.previewStampCount` stamps, cycling through the brush's
    /// frames in order, spaced at ≈ scaled-frame-width × `K.spacingFactor`
    /// (§10.4). Returns cumulative arc-length position for each stamp so the
    /// caller can map position → S-curve parameter t ∈ [0, 1].
    private static func planStamps(
        manifest: BrushManifest,
        framesByIndex: [Int: FrameEntry],
        displayScale: CGFloat
    ) -> [PlannedStamp] {
        var planned: [PlannedStamp] = []
        var cumulative: CGFloat = 0
        for i in 0..<K.previewStampCount {
            let frameIdx = i % manifest.frameCount
            guard let entry = framesByIndex[frameIdx] else { continue }
            planned.append(PlannedStamp(frameIndex: frameIdx, cumulativeLength: cumulative))
            let widthPt = CGFloat(entry.rect[2]) * displayScale
            cumulative += widthPt * K.spacingFactor
        }
        return planned
    }

    // MARK: - Compositing

    /// Draws one stamp, anchored on the S-curve at parameter `t`, into `context`.
    ///
    /// Layout math (S-curve point, anchor offset) is done in a top-left-origin,
    /// y-down space matching how `FrameEntry.anchor` is defined (distance from
    /// the stamp's top-left, per §9.5); the result is flipped once into the
    /// CGContext's native bottom-left-origin space for the actual draw call.
    private static func draw(
        _ stampImage: CGImage,
        entry: FrameEntry,
        atPathT t: CGFloat,
        displayScale: CGFloat,
        renderScale: CGFloat,
        pixelSize: CGSize,
        into context: CGContext
    ) {
        let combinedScale = displayScale * renderScale
        let drawnSize = CGSize(
            width: CGFloat(entry.rect[2]) * combinedScale,
            height: CGFloat(entry.rect[3]) * combinedScale
        )
        let anchorScaled = CGPoint(
            x: entry.anchor[0] * combinedScale,
            y: entry.anchor[1] * combinedScale
        )

        let pathPointLayout = sCurvePoint(t: t, size: K.previewSize)
        let pathPointPx = CGPoint(x: pathPointLayout.x * renderScale, y: pathPointLayout.y * renderScale)

        let layoutOrigin = CGPoint(
            x: pathPointPx.x - anchorScaled.x,
            y: pathPointPx.y - anchorScaled.y
        )
        // Flip y (top-left layout space → bottom-left CG bitmap space).
        let cgOrigin = CGPoint(
            x: layoutOrigin.x,
            y: pixelSize.height - (layoutOrigin.y + drawnSize.height)
        )
        let destRect = CGRect(origin: cgOrigin, size: drawnSize)

        context.saveGState()
        context.setBlendMode(.normal) // premultiplied source-over
        context.draw(stampImage, in: destRect)
        context.restoreGState()
    }

    /// A smooth S-shape across `size` (top-left origin, y-down), t ∈ [0, 1].
    private static func sCurvePoint(t: CGFloat, size: CGSize) -> CGPoint {
        let marginX = size.width * 0.08
        let ampY = size.height * 0.28
        let midY = size.height * 0.5
        let p0 = CGPoint(x: marginX, y: midY + ampY)
        let p1 = CGPoint(x: size.width * 0.32, y: midY - ampY)
        let p2 = CGPoint(x: size.width * 0.68, y: midY + ampY)
        let p3 = CGPoint(x: size.width - marginX, y: midY - ampY)

        let mt = 1 - t
        let x = mt * mt * mt * p0.x + 3 * mt * mt * t * p1.x + 3 * mt * t * t * p2.x + t * t * t * p3.x
        let y = mt * mt * mt * p0.y + 3 * mt * mt * t * p1.y + 3 * mt * t * t * p2.y + t * t * t * p3.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - GIF encoding

    private static func encodeGIF(frames: [CGImage], to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.gif.identifier as CFString,
                frames.count,
                nil
            )
        else {
            throw BrushError.io
        }

        let loopProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(destination, loopProperties as CFDictionary)

        let perFrameDelay = K.demoStrokeDuration / Double(max(frames.count, 1))
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: perFrameDelay]
        ]
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw BrushError.io
        }
    }
}
