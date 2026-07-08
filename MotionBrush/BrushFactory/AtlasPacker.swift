import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// =============================================================================
// Pure shelf-packing core (§9.6) — no CoreGraphics rendering, so it can be
// unit tested directly.
// =============================================================================

/// An integer pixel rect within an atlas page (top-left origin).
struct AtlasRect: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

/// Simple shelf bin-packer: sort by height desc, fill rows left-to-right,
/// wrap to a new shelf when a row is full, wrap to a new page when a page is
/// full. `gutter` px separate every rect from its neighbors and from the page
/// edge to prevent atlas sampling bleed (§9.6).
enum ShelfPacker {
    struct Placement: Equatable {
        let originalIndex: Int
        let page: Int
        let rect: AtlasRect
    }

    /// - Parameters:
    ///   - sizes: `(index, size)` pairs identifying each item to place; sizes
    ///     must each individually fit within `pageEdge` (true for all MVP
    ///     stamps, capped at `K.maxStampEdge` ≪ `K.atlasPageEdge`).
    static func pack(sizes: [(index: Int, size: CGSize)], pageEdge: Int, gutter: Int) -> [Placement] {
        guard !sizes.isEmpty else { return [] }

        let order = sizes.enumerated().sorted { lhs, rhs in
            lhs.element.size.height > rhs.element.size.height
        }

        var placements: [Placement] = []
        var page = 0
        var shelfY = gutter
        var shelfHeight = 0
        var cursorX = gutter

        for item in order {
            let w = max(1, Int(item.element.size.width.rounded(.up)))
            let h = max(1, Int(item.element.size.height.rounded(.up)))

            // Wrap to a new shelf row if this item doesn't fit the remaining width.
            if cursorX + w + gutter > pageEdge {
                shelfY += shelfHeight + gutter
                shelfHeight = 0
                cursorX = gutter
            }
            // Wrap to a new page if this item doesn't fit the remaining height.
            if shelfY + h + gutter > pageEdge {
                page += 1
                shelfY = gutter
                shelfHeight = 0
                cursorX = gutter
            }

            let rect = AtlasRect(x: cursorX, y: shelfY, width: w, height: h)
            placements.append(Placement(originalIndex: item.element.index, page: page, rect: rect))

            cursorX += w + gutter
            shelfHeight = max(shelfHeight, h)
        }
        return placements
    }
}

// =============================================================================
// Real packer: renders pages, encodes HEIC, builds the manifest (§9.6, §10.2).
// =============================================================================

enum AtlasPacker {
    struct PackedAsset {
        let manifest: BrushManifest
        let pageImages: [CGImage]  // index-aligned with manifest.atlasPages
    }

    /// Packs the real (non-duplicate) stamps into atlas pages and builds the
    /// manifest, including `duplicateOf` frames which share the atlas rect of
    /// the real frame they duplicate (no pixels duplicated, §10.2).
    static func build(
        stamps: [StampData],
        brushID: String,
        name: String,
        sourceDuration: Double,
        createdAt: Date = Date()
    ) -> PackedAsset {
        let real = stamps.filter { $0.duplicateOf == nil }
        let sizes = real.map { (index: $0.index, size: $0.pixelSize) }
        let placements = ShelfPacker.pack(sizes: sizes, pageEdge: K.atlasPageEdge, gutter: K.atlasGutter)
        let placementByIndex = Dictionary(uniqueKeysWithValues: placements.map { ($0.originalIndex, $0) })
        let stampByIndex = Dictionary(uniqueKeysWithValues: real.map { ($0.index, $0) })

        let pageCount = (placements.map(\.page).max() ?? -1) + 1
        let pages: [CGImage] = (0..<max(pageCount, 0)).map { page in
            renderPage(page: page, placements: placements, stampByIndex: stampByIndex, edge: K.atlasPageEdge)
        }

        var frames: [FrameEntry] = []
        frames.reserveCapacity(stamps.count)
        for stamp in stamps.sorted(by: { $0.index < $1.index }) {
            let sourceIndex = stamp.duplicateOf ?? stamp.index
            guard let placement = placementByIndex[sourceIndex] else { continue }
            frames.append(FrameEntry(
                i: stamp.index,
                page: placement.page,
                rect: [placement.rect.x, placement.rect.y, placement.rect.width, placement.rect.height],
                anchor: [Double(stamp.anchor.x), Double(stamp.anchor.y)],
                duplicateOf: stamp.duplicateOf))
        }

        let manifest = BrushManifest(
            schemaVersion: BrushManifest.currentSchemaVersion,
            id: brushID,
            name: name,
            createdAt: createdAt,
            frameCount: frames.count,
            sourceDuration: sourceDuration,
            suggestedSpacingFactor: Double(K.spacingFactor),
            atlasPages: (0..<pages.count).map { "atlas-\($0).heic" },
            frames: frames
        )
        return PackedAsset(manifest: manifest, pageImages: pages)
    }

    /// Renders one atlas page. Atlas rects are top-left origin (image
    /// convention); `CGContext` is bottom-left origin, so drawing flips y.
    private static func renderPage(
        page: Int, placements: [ShelfPacker.Placement], stampByIndex: [Int: StampData], edge: Int
    ) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: edge * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

        for placement in placements where placement.page == page {
            guard let stamp = stampByIndex[placement.originalIndex] else { continue }
            let flippedY = edge - placement.rect.y - placement.rect.height
            let rect = CGRect(
                x: placement.rect.x, y: flippedY,
                width: placement.rect.width, height: placement.rect.height)
            context.draw(stamp.cgImage, in: rect)
        }
        return context.makeImage()!
    }

    /// Persists a page as HEIC with alpha (quality ~0.9, §9.6).
    static func writeHEIC(_ image: CGImage, to url: URL, quality: CGFloat = 0.9) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw BrushError.io
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw BrushError.io }
    }
}
