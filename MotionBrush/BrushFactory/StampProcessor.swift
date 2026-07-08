import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Stage 3 (§9.5): composites the source frame with the picked instance's
/// full-resolution matte via `CIBlendWithMask` (premultiplied RGBA output),
/// tightly crops to the alpha bounding box (outset by `K.cropPadding`),
/// downsamples so the longest edge is at most `K.maxStampEdge`, and computes
/// the alpha-weighted centroid anchor in cropped-stamp coordinates. No size
/// normalization across frames (FR-11).
enum StampProcessor {
    /// Shared Metal-backed CIContext, created once (§9.5).
    private static let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext(options: nil)
    }()

    /// Produces a stamp for a hit frame. Returns nil if the composited matte
    /// has no pixels above the alpha threshold (a degenerate/empty matte —
    /// the caller treats this like a miss and reuses the previous stamp,
    /// FR-9).
    static func makeStamp(index: Int, pixelBuffer: CVPixelBuffer, matte: CVPixelBuffer) -> StampData? {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let maskImage = CIImage(cvPixelBuffer: matte)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: source.extent)

        guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
        blend.setValue(source, forKey: kCIInputImageKey)
        blend.setValue(clear, forKey: kCIInputBackgroundImageKey)
        blend.setValue(maskImage, forKey: kCIInputMaskImageKey)
        guard let composited = blend.outputImage else { return nil }

        guard let alphaBox = alphaBoundingBox(of: composited, extent: source.extent) else {
            return nil
        }

        let longestSide = max(alphaBox.width, alphaBox.height)
        let padding = longestSide * K.cropPadding
        let padded = alphaBox.insetBy(dx: -padding, dy: -padding).intersection(source.extent)
        guard !padded.isEmpty, !padded.isInfinite, padded.width > 0, padded.height > 0 else {
            return nil
        }

        let cropped = composited
            .cropped(to: padded)
            .transformed(by: CGAffineTransform(translationX: -padded.origin.x, y: -padded.origin.y))

        let longestEdge = max(padded.width, padded.height)
        let downScale = longestEdge > CGFloat(K.maxStampEdge) ? CGFloat(K.maxStampEdge) / longestEdge : 1.0
        let scaled = downScale < 1.0
            ? cropped.transformed(by: CGAffineTransform(scaleX: downScale, y: downScale))
            : cropped

        let outSize = CGSize(
            width: max(1, (padded.width * downScale).rounded(.down)),
            height: max(1, (padded.height * downScale).rounded(.down)))
        let renderRect = CGRect(origin: .zero, size: outSize)

        guard let cgImage = ciContext.createCGImage(
            scaled, from: renderRect, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else {
            return nil
        }

        guard let anchor = alphaWeightedCentroid(cgImage: cgImage) else { return nil }

        return StampData(index: index, cgImage: cgImage, anchor: anchor, pixelSize: outSize, duplicateOf: nil)
    }

    // MARK: - Alpha analysis

    /// Tight bounding box of pixels with alpha > 0.02, in `extent`'s
    /// coordinate space (§9.5).
    private static func alphaBoundingBox(of image: CIImage, extent: CGRect) -> CGRect? {
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            ciContext.render(
                image, toBitmap: base, rowBytes: width * 4,
                bounds: extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }

        var minX = width, maxX = -1, minY = height, maxY = -1
        let threshold = UInt8(0.02 * 255)
        for y in 0..<height {
            let rowBase = y * width * 4
            for x in 0..<width {
                let a = pixels[rowBase + x * 4 + 3]
                if a > threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: extent.origin.x + CGFloat(minX), y: extent.origin.y + CGFloat(minY),
            width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }

    /// Alpha-weighted centroid of a premultiplied RGBA image, in the image's
    /// own pixel coordinates (top-left origin) — the anchor that rides the
    /// stroke path (§9.5).
    private static func alphaWeightedCentroid(cgImage: CGImage) -> CGPoint? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data)
        else { return nil }

        let bytesPerRow = cgImage.bytesPerRow
        var sumX = 0.0, sumY = 0.0, sumA = 0.0
        for y in 0..<height {
            let rowBase = y * bytesPerRow
            for x in 0..<width {
                let a = Double(ptr[rowBase + x * 4 + 3])
                guard a > 0 else { continue }
                sumX += Double(x) * a
                sumY += Double(y) * a
                sumA += a
            }
        }
        guard sumA > 0 else {
            return CGPoint(x: Double(width) / 2, y: Double(height) / 2)
        }
        return CGPoint(x: sumX / sumA, y: sumY / sumA)
    }
}
