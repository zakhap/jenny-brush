import CoreGraphics
import Foundation
import MetalKit
import QuartzCore
import UIKit

/// The drawing surface: a Metal-backed UIView hosting committed + live stroke
/// textures, arc-length stamping, undo, clear, export (§11, FR-19…FR-25).
///
/// PUBLIC API IS A FROZEN CONTRACT. This view hosts an internal `MTKView`
/// (bgra8Unorm, draw-on-demand) and forwards touches to `CanvasRenderer`,
/// which owns all Metal state, the `StrokeBuilder`/`Stamper`, and the
/// `UndoStack`.
final class CanvasView: UIView {
    /// Called after each committed stroke (App autosaves the canvas, FR-26).
    var onStrokeCommitted: (() -> Void)?

    private let metalView: MTKView
    private let renderer: CanvasRenderer

    private var activeTouch: UITouch?

    private var demoDisplayLink: CADisplayLink?
    private var demoPoints: [CGPoint] = []
    private var demoFedCount: Int = 0
    private var demoStartTime: CFTimeInterval = 0

    override init(frame: CGRect) {
        let mtkView = MTKView(frame: .zero)
        guard let device = MTLCreateSystemDefaultDevice() else {
            // §13: Metal device unavailable is fatal (should not occur on iOS 17 hardware).
            fatalError("Metal is not available on this device")
        }
        mtkView.device = device
        guard let renderer = CanvasRenderer(mtkView: mtkView) else {
            fatalError("Failed to initialize CanvasRenderer")
        }
        self.metalView = mtkView
        self.renderer = renderer
        super.init(frame: frame)

        backgroundColor = .white
        isMultipleTouchEnabled = false
        metalView.isUserInteractionEnabled = false // this view handles touches itself
        addSubview(metalView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds

        // Canvas pixel size = view point size × K.canvasScale, regardless of
        // the device's native screen scale (FR-19). autoResizeDrawable is
        // off, so we own drawableSize explicitly.
        let pixelSize = CGSize(width: bounds.width * K.canvasScale, height: bounds.height * K.canvasScale)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        if metalView.drawableSize != pixelSize {
            metalView.drawableSize = pixelSize
        }
    }

    // MARK: - Public API (frozen contract)

    /// Set the active brush; loads its atlas pages into MTLTextures for the
    /// active brush only (§9.6). Pass nil to draw nothing.
    func setBrush(_ brush: BrushAsset?) {
        renderer.setBrush(brush)
    }

    /// Restore the committed canvas from a saved PNG (base for replay, FR-26).
    /// Pass nil for a fresh white canvas.
    func restore(canvasPNG: Data?) {
        renderer.restore(canvasPNG: canvasPNG)
    }

    /// Revert the most recent stroke via replay (FR-23).
    func undo() {
        renderer.undo()
    }

    /// Erase everything to white and empty the undo stack (FR-23, behind a confirm in UI).
    func clear() {
        renderer.clear()
    }

    /// The committed canvas composited over opaque white as PNG (FR-25 export & FR-26 persist).
    func exportPNG() -> Data? {
        renderer.exportPNG()
    }

    /// Programmatically draw the demo S-curve with the active brush over
    /// K.demoStrokeDuration, feeding points through the normal stroke path (FR-24).
    func playDemoStroke() {
        stopDemoStrokeIfNeeded()
        let canvasSize = CGSize(width: bounds.width * K.canvasScale, height: bounds.height * K.canvasScale)
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }

        demoPoints = Self.demoSCurvePoints(canvasSize: canvasSize)
        guard let first = demoPoints.first else { return }

        // Feeds through the SAME beginStroke/addStrokePoints/endStroke path a
        // real touch sequence uses — not a special case (FR-24, §12).
        renderer.beginStroke(at: first)
        demoFedCount = 1
        demoStartTime = CACurrentMediaTime()

        let link = CADisplayLink(target: self, selector: #selector(demoStep))
        link.add(to: .main, forMode: .common)
        demoDisplayLink = link
    }

    @objc private func demoStep() {
        let elapsed = CACurrentMediaTime() - demoStartTime
        let fraction = min(elapsed / K.demoStrokeDuration, 1.0)
        let targetCount = min(demoPoints.count, Int((Double(demoPoints.count - 1) * fraction).rounded()) + 1)
        if targetCount > demoFedCount {
            let newPoints = Array(demoPoints[demoFedCount..<targetCount])
            renderer.addStrokePoints(newPoints)
            demoFedCount = targetCount
        }
        if fraction >= 1.0 {
            stopDemoStrokeIfNeeded()
            if renderer.endStroke() {
                onStrokeCommitted?()
            }
        }
    }

    private func stopDemoStrokeIfNeeded() {
        demoDisplayLink?.invalidate()
        demoDisplayLink = nil
    }

    /// A smooth S-curve across the upper-middle canvas (FR-24): two opposing
    /// half-sine humps, Catmull-Rom smoothed like any other stroke input.
    private static func demoSCurvePoints(canvasSize: CGSize) -> [CGPoint] {
        let y0 = canvasSize.height * 0.28
        let xStart = canvasSize.width * 0.15
        let xEnd = canvasSize.width * 0.85
        let amplitude = canvasSize.height * 0.10
        let sampleCount = 96

        var raw: [CGPoint] = []
        raw.reserveCapacity(sampleCount + 1)
        for i in 0...sampleCount {
            let t = CGFloat(i) / CGFloat(sampleCount)
            let x = xStart + (xEnd - xStart) * t
            let y = y0 + amplitude * sin(2 * .pi * t)
            raw.append(CGPoint(x: x, y: y))
        }
        return CatmullRom.smooth(points: raw, stepsPerSegment: 4)
    }

    // MARK: - Touch handling (§11.2, FR-21)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        stopDemoStrokeIfNeeded() // a real touch always takes over from a demo stroke
        activeTouch = touch
        renderer.beginStroke(at: canvasPoint(for: touch))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        renderer.addStrokePoints(coalesced.map { canvasPoint(for: $0) })

        let predicted = event?.predictedTouches(for: touch)?.map { canvasPoint(for: $0) } ?? []
        renderer.addPredictedPoints(predicted)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishStroke(touches: touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // E6: stroke is committed as-is at touch cancellation (e.g. backgrounding).
        finishStroke(touches: touches)
    }

    private func finishStroke(touches: Set<UITouch>) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        activeTouch = nil
        if renderer.endStroke() {
            onStrokeCommitted?()
        }
    }

    private func canvasPoint(for touch: UITouch) -> CGPoint {
        let p = touch.location(in: self)
        return CGPoint(x: p.x * K.canvasScale, y: p.y * K.canvasScale)
    }
}
