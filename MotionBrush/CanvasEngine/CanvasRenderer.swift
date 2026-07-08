import CoreGraphics
import ImageIO
import Metal
import MetalKit
import UniformTypeIdentifiers

// =============================================================================
// The Metal side of §11: committedTexture + live stroke, instanced quad
// drawing of the brush atlas, undo/clear, export, brush loading. Everything
// here is Metal/UIKit-adjacent — the pure geometry (Stamper/StrokeBuilder)
// lives in separate files and knows nothing about this one.
// =============================================================================

/// Per-instance quad data uploaded to the GPU. Field order/types must match
/// `StampInstance` in Shaders.metal exactly (both are 8-byte-aligned SIMD2s
/// followed by two 4-byte scalars — no padding surprises).
struct StampInstanceData {
    var center: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var uvMin: SIMD2<Float>
    var uvMax: SIMD2<Float>
    var rotation: Float   // K.rotateToTangent scaffold — always 0 in MVP
    var page: UInt32
}

struct RendererUniforms {
    var canvasSize: SIMD2<Float>
}

/// One brush frame's GPU-relevant data, resolved from `BrushManifest.frames`
/// at brush-load time (§9.6).
struct BrushFrameGPU {
    let anchor: CGPoint     // px, within the stamp, from FrameEntry.anchor
    let pixelSize: CGSize   // native px size, from FrameEntry.rect[2..3]
    let uvMin: SIMD2<Float>
    let uvMax: SIMD2<Float>
    let pageIndex: Int
}

/// A brush's atlas pages loaded into one `texture2d_array` plus its resolved
/// frame table. Kept alive only for the active brush (§9.6) — plus whatever
/// committed strokes in the undo stack still reference it, so replay stays
/// correct across a brush switch.
final class RuntimeBrush {
    let id: String
    let arrayTexture: MTLTexture
    let frames: [BrushFrameGPU]

    init(id: String, arrayTexture: MTLTexture, frames: [BrushFrameGPU]) {
        self.id = id
        self.arrayTexture = arrayTexture
        self.frames = frames
    }

    var stamperBrush: StamperBrush {
        StamperBrush(frames: frames.map { StamperBrushFrame(width: $0.pixelSize.width) })
    }
}

final class CanvasRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let blitPipeline: MTLRenderPipelineState
    private let stampPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let quadCornersBuffer: MTLBuffer

    private weak var mtkView: MTKView?

    // Canvas-sized textures (bgra8Unorm, matching the drawable's format).
    private(set) var baseTexture: MTLTexture?       // replay base: white or restored PNG
    private(set) var committedTexture: MTLTexture?  // base + all strokes currently in the undo window

    private(set) var currentBrush: RuntimeBrush?
    private let undoStack = UndoStack()

    private var strokeBuilder: StrokeBuilder?
    private var liveConfirmedInstances: [StampInstanceData] = []
    private var livePredictedInstances: [StampInstanceData] = []

    private enum PendingRestore { case png(Data); case blank }
    private var pendingRestore: PendingRestore?

    init?(mtkView: MTKView) {
        guard let device = mtkView.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.autoResizeDrawable = false
        mtkView.framebufferOnly = true
        self.mtkView = mtkView

        guard let library = device.makeDefaultLibrary(),
              let vertexFn = library.makeFunction(name: "stampVertex"),
              let blitFragmentFn = library.makeFunction(name: "blitFragment"),
              let stampFragmentFn = library.makeFunction(name: "stampFragment") else { return nil }

        let blitDesc = MTLRenderPipelineDescriptor()
        blitDesc.vertexFunction = vertexFn
        blitDesc.fragmentFunction = blitFragmentFn
        blitDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        blitDesc.colorAttachments[0].isBlendingEnabled = false

        let stampDesc = MTLRenderPipelineDescriptor()
        stampDesc.vertexFunction = vertexFn
        stampDesc.fragmentFunction = stampFragmentFn
        stampDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        stampDesc.colorAttachments[0].isBlendingEnabled = true
        // Premultiplied source-over (§11.1, FR-22).
        stampDesc.colorAttachments[0].rgbBlendOperation = .add
        stampDesc.colorAttachments[0].alphaBlendOperation = .add
        stampDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        stampDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        stampDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        stampDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            blitPipeline = try device.makeRenderPipelineState(descriptor: blitDesc)
            stampPipeline = try device.makeRenderPipelineState(descriptor: stampDesc)
        } catch {
            return nil
        }

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else { return nil }
        self.sampler = sampler

        // Triangle strip corners in [-1,1]^2.
        var corners: [SIMD2<Float>] = [
            SIMD2<Float>(-1, -1), SIMD2<Float>(1, -1), SIMD2<Float>(-1, 1), SIMD2<Float>(1, 1),
        ]
        guard let cornersBuffer = device.makeBuffer(bytes: &corners, length: MemoryLayout<SIMD2<Float>>.stride * corners.count, options: .storageModeShared) else { return nil }
        self.quadCornersBuffer = cornersBuffer

        super.init()
        mtkView.delegate = self
    }

    // MARK: - Canvas sizing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        allocateCanvasTexturesIfNeeded(pixelSize: size)
    }

    private func allocateCanvasTexturesIfNeeded(pixelSize: CGSize) {
        let w = max(Int(pixelSize.width.rounded()), 1)
        let h = max(Int(pixelSize.height.rounded()), 1)
        if let existing = committedTexture, existing.width == w, existing.height == h { return }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .shared
        guard let newBase = device.makeTexture(descriptor: desc),
              let newCommitted = device.makeTexture(descriptor: desc) else { return }

        fillWhite(newBase)
        fillWhite(newCommitted)
        baseTexture = newBase
        committedTexture = newCommitted
        undoStack.removeAll()

        applyPendingRestoreIfPossible()
        requestRedraw()
    }

    private func requestRedraw() {
        mtkView?.setNeedsDisplay()
    }

    // MARK: - Brush loading (setBrush, §9.6)

    func setBrush(_ brush: BrushAsset?) {
        guard let brush else {
            currentBrush = nil
            return
        }
        currentBrush = Self.loadRuntimeBrush(brush, device: device, commandQueue: commandQueue)
    }

    private static func loadRuntimeBrush(_ brush: BrushAsset, device: MTLDevice, commandQueue: MTLCommandQueue) -> RuntimeBrush? {
        let loader = MTKTextureLoader(device: device)
        var pageTextures: [MTLTexture] = []
        for pageIdx in brush.manifest.atlasPages.indices {
            let url = brush.atlasURL(page: pageIdx)
            guard let data = try? Data(contentsOf: url),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            // .topLeft keeps texture row 0 == image row 0, matching the
            // top-down pixel coordinates AtlasPacker records in manifest rects.
            let options: [MTKTextureLoader.Option: Any] = [
                .SRGB: false,
                .origin: MTKTextureLoader.Origin.topLeft,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            ]
            guard let tex = try? loader.newTexture(cgImage: cgImage, options: options) else { return nil }
            pageTextures.append(tex)
        }
        guard let firstPage = pageTextures.first else { return nil }

        let arrayDesc = MTLTextureDescriptor()
        arrayDesc.textureType = .type2DArray
        arrayDesc.pixelFormat = firstPage.pixelFormat
        arrayDesc.width = firstPage.width
        arrayDesc.height = firstPage.height
        arrayDesc.arrayLength = pageTextures.count
        arrayDesc.usage = [.shaderRead]
        guard let arrayTexture = device.makeTexture(descriptor: arrayDesc),
              let cmd = commandQueue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return nil }
        for (i, tex) in pageTextures.enumerated() {
            blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1),
                      to: arrayTexture, destinationSlice: i, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let edgeW = Float(max(firstPage.width, 1))
        let edgeH = Float(max(firstPage.height, 1))
        var frames: [BrushFrameGPU] = []
        for entry in brush.manifest.frames.sorted(by: { $0.i < $1.i }) {
            guard entry.rect.count == 4, entry.anchor.count == 2 else { continue }
            let rx = Float(entry.rect[0]), ry = Float(entry.rect[1])
            let rw = Float(entry.rect[2]), rh = Float(entry.rect[3])
            frames.append(BrushFrameGPU(
                anchor: CGPoint(x: entry.anchor[0], y: entry.anchor[1]),
                pixelSize: CGSize(width: CGFloat(rw), height: CGFloat(rh)),
                uvMin: SIMD2<Float>(rx / edgeW, ry / edgeH),
                uvMax: SIMD2<Float>((rx + rw) / edgeW, (ry + rh) / edgeH),
                pageIndex: entry.page
            ))
        }
        guard !frames.isEmpty else { return nil }
        return RuntimeBrush(id: brush.id, arrayTexture: arrayTexture, frames: frames)
    }

    private func resolve(_ stamps: [Stamp], brush: RuntimeBrush) -> [StampInstanceData] {
        stamps.compactMap { stamp -> StampInstanceData? in
            guard stamp.frame >= 0, stamp.frame < brush.frames.count else { return nil }
            let f = brush.frames[stamp.frame]
            let halfW = Float(f.pixelSize.width / 2)
            let halfH = Float(f.pixelSize.height / 2)
            let topLeftX = Float(stamp.center.x) - Float(f.anchor.x)
            let topLeftY = Float(stamp.center.y) - Float(f.anchor.y)
            return StampInstanceData(
                center: SIMD2<Float>(topLeftX + halfW, topLeftY + halfH),
                halfSize: SIMD2<Float>(halfW, halfH),
                uvMin: f.uvMin, uvMax: f.uvMax,
                rotation: 0, // K.rotateToTangent scaffold, off in MVP
                page: UInt32(f.pageIndex)
            )
        }
    }

    // MARK: - Stroke lifecycle (touch → path → stamps, §11.2)

    func beginStroke(at point: CGPoint) {
        guard let brush = currentBrush else { return }
        let sb = StrokeBuilder(brush: brush.stamperBrush)
        sb.begin(at: point)
        strokeBuilder = sb
        liveConfirmedInstances = []
        livePredictedInstances = []
        requestRedraw()
    }

    func addStrokePoints(_ points: [CGPoint]) {
        guard let sb = strokeBuilder, let brush = currentBrush, !points.isEmpty else { return }
        let newStamps = sb.addPoints(points)
        if !newStamps.isEmpty {
            liveConfirmedInstances.append(contentsOf: resolve(newStamps, brush: brush))
        }
        requestRedraw()
    }

    func addPredictedPoints(_ points: [CGPoint]) {
        guard let sb = strokeBuilder, let brush = currentBrush else {
            livePredictedInstances = []
            return
        }
        let predicted = sb.predictedStamps(for: points)
        livePredictedInstances = resolve(predicted, brush: brush)
        requestRedraw()
    }

    /// Ends the in-progress stroke, committing it. Returns true if a stroke
    /// was actually committed (false if there was no active brush/stroke).
    @discardableResult
    func endStroke() -> Bool {
        defer {
            strokeBuilder = nil
            liveConfirmedInstances = []
            livePredictedInstances = []
            requestRedraw()
        }
        guard let sb = strokeBuilder, let brush = currentBrush else { return false }
        let finalStamps = sb.end()
        guard !finalStamps.isEmpty else { return false }
        let instances = resolve(finalStamps, brush: brush)
        commitStroke(instances: instances, texture: brush.arrayTexture)
        return true
    }

    private func commitStroke(instances: [StampInstanceData], texture: MTLTexture) {
        guard let committed = committedTexture else { return }
        renderInstances(instances, texture: texture, into: committed)
        let evicted = undoStack.push(CommittedStroke(instances: instances, atlasTexture: texture))
        if let evicted, let base = baseTexture {
            // Stroke aged out of the undo window: bake it into the replay
            // base so it stays visible but is no longer individually undoable.
            renderInstances(evicted.instances, texture: evicted.atlasTexture, into: base)
        }
    }

    // MARK: - Undo & clear (§11.4)

    func undo() {
        guard let base = baseTexture, let committed = committedTexture else { return }
        guard undoStack.popLast() != nil else { return }
        replayAll(into: committed, from: base)
        requestRedraw()
    }

    func clear() {
        guard let base = baseTexture, let committed = committedTexture else { return }
        undoStack.removeAll()
        fillWhite(base)
        fillWhite(committed)
        requestRedraw()
    }

    private func replayAll(into target: MTLTexture, from base: MTLTexture) {
        guard let cmd = commandQueue.makeCommandBuffer() else { return }
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: base, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: base.width, height: base.height, depth: 1),
                      to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            var uniforms = RendererUniforms(canvasSize: SIMD2<Float>(Float(target.width), Float(target.height)))
            enc.setRenderPipelineState(stampPipeline)
            enc.setVertexBuffer(quadCornersBuffer, offset: 0, index: 0)
            for stroke in undoStack.strokes {
                guard let buffer = makeInstanceBuffer(stroke.instances) else { continue }
                enc.setVertexBuffer(buffer, offset: 0, index: 1)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<RendererUniforms>.stride, index: 2)
                enc.setFragmentTexture(stroke.atlasTexture, index: 0)
                enc.setFragmentSamplerState(sampler, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: stroke.instances.count)
            }
            enc.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    private func renderInstances(_ instances: [StampInstanceData], texture: MTLTexture, into target: MTLTexture) {
        guard !instances.isEmpty, let buffer = makeInstanceBuffer(instances) else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store
        guard let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var uniforms = RendererUniforms(canvasSize: SIMD2<Float>(Float(target.width), Float(target.height)))
        enc.setRenderPipelineState(stampPipeline)
        enc.setVertexBuffer(quadCornersBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(buffer, offset: 0, index: 1)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<RendererUniforms>.stride, index: 2)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    private func fillWhite(_ texture: MTLTexture) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        guard let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    private func makeInstanceBuffer(_ data: [StampInstanceData]) -> MTLBuffer? {
        guard !data.isEmpty else { return nil }
        return device.makeBuffer(bytes: data, length: MemoryLayout<StampInstanceData>.stride * data.count, options: .storageModeShared)
    }

    private func copyTexture(_ source: MTLTexture, to destination: MTLTexture) {
        guard let cmd = commandQueue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                  to: destination, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    // MARK: - Restore (FR-26)

    func restore(canvasPNG data: Data?) {
        pendingRestore = data.map { .png($0) } ?? .blank
        applyPendingRestoreIfPossible()
    }

    private func applyPendingRestoreIfPossible() {
        guard let base = baseTexture, let committed = committedTexture, let pending = pendingRestore else { return }
        undoStack.removeAll()
        switch pending {
        case .blank:
            fillWhite(base)
            fillWhite(committed)
        case .png(let data):
            if let src = CGImageSourceCreateWithData(data as CFData, nil),
               let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil),
               uploadImage(cgImage, into: base) {
                copyTexture(base, to: committed)
            } else {
                fillWhite(base)
                fillWhite(committed)
            }
        }
        pendingRestore = nil
    }

    private func uploadImage(_ cgImage: CGImage, into texture: MTLTexture) -> Bool {
        let width = texture.width
        let height = texture.height
        guard width > 0, height > 0 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return false }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let region = MTLRegionMake2D(0, 0, width, height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: &pixels, bytesPerRow: width * 4)
        return true
    }

    // MARK: - Export (FR-25)

    func exportPNG() -> Data? {
        guard let committed = committedTexture else { return nil }
        let width = committed.width
        let height = committed.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let region = MTLRegionMake2D(0, 0, width, height)
        committed.getBytes(&pixels, bytesPerRow: width * 4, from: region, mipmapLevel: 0)

        // committedTexture is always fully opaque by construction (base is
        // opaque white; premultiplied source-over onto an opaque destination
        // stays opaque), so this readback already IS "composited over opaque
        // white" (FR-25) — no extra compositing pass needed.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let cgImage = ctx.makeImage() else { return nil }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    // MARK: - Draw (§11.1)

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let committed = committedTexture,
              let cmd = commandQueue.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let canvasSize = SIMD2<Float>(Float(committed.width), Float(committed.height))
        var uniforms = RendererUniforms(canvasSize: canvasSize)

        encoder.setVertexBuffer(quadCornersBuffer, offset: 0, index: 0)

        // Pass 1: blit committedTexture across the full canvas (opaque).
        var fullQuad = StampInstanceData(
            center: canvasSize / 2, halfSize: canvasSize / 2,
            uvMin: SIMD2<Float>(0, 0), uvMax: SIMD2<Float>(1, 1),
            rotation: 0, page: 0
        )
        encoder.setRenderPipelineState(blitPipeline)
        encoder.setVertexBytes(&fullQuad, length: MemoryLayout<StampInstanceData>.stride, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<RendererUniforms>.stride, index: 2)
        encoder.setFragmentTexture(committed, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)

        // Pass 2: in-progress stroke's stamps on top (confirmed + ephemeral predicted).
        let liveInstances = liveConfirmedInstances + livePredictedInstances
        if !liveInstances.isEmpty, let atlas = currentBrush?.arrayTexture, let buffer = makeInstanceBuffer(liveInstances) {
            encoder.setRenderPipelineState(stampPipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RendererUniforms>.stride, index: 2)
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: liveInstances.count)
        }

        encoder.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
