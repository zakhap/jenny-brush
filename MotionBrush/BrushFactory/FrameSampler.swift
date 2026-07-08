import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// Stage 1 (§9.3): reads the video track via `AVAssetReader` +
/// `AVAssetReaderTrackOutput`, requesting `kCVPixelFormatType_32BGRA`, and keeps
/// a stride-sampled subsequence of frames down to `K.samplingFPS`, capped at
/// `K.maxFrames` (FR-7). Buffers are rotated upright using the track's
/// `preferredTransform` before being handed downstream. Runs entirely off the
/// main thread.
///
/// Never uses `AVAssetImageGenerator` (an order of magnitude slower for
/// sequential reads, per §9.3).
enum FrameSampler {
    /// Produces the ordered frame stream plus a `release` callback the
    /// consumer calls once per frame after it no longer needs to hold the
    /// stream's internal slot for that frame. This throttles the reader to at
    /// most `maxInFlight` frames ahead of the consumer (§9.6 concurrency note,
    /// §14 memory budget) — AVAssetReader can decode far faster than Vision
    /// segments, and without this gate the producer could buffer all ~96
    /// full-resolution BGRA frames (hundreds of MB) ahead of a slow consumer.
    static func sample(
        url: URL, maxInFlight: Int = 2
    ) -> (stream: AsyncThrowingStream<SampledFrame, Error>, release: @Sendable () async -> Void) {
        let gate = InFlightGate(capacity: maxInFlight)
        let stream = AsyncThrowingStream<SampledFrame, Error> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await run(url: url, gate: gate, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: BrushError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, { await gate.release() })
    }

    private static func run(
        url: URL,
        gate: InFlightGate,
        continuation: AsyncThrowingStream<SampledFrame, Error>.Continuation
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw BrushError.reader("no video track")
        }

        let nominalFPS = try await track.load(.nominalFrameRate)
        let transform = try await track.load(.preferredTransform)

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw BrushError.reader("cannot add track output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw BrushError.reader(reader.error?.localizedDescription ?? "startReading failed")
        }

        let sourceFPS = nominalFPS > 0 ? Double(nominalFPS) : K.samplingFPS
        let stride = max(1, Int((sourceFPS / K.samplingFPS).rounded()))

        var sourceIndex = 0
        var keptIndex = 0

        while keptIndex < K.maxFrames {
            try Task.checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }

            if sourceIndex % stride == 0 {
                if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let upright = uprighted(imageBuffer, transform: transform)
                    await gate.acquire()
                    continuation.yield(SampledFrame(index: keptIndex, pixelBuffer: upright, time: time))
                    keptIndex += 1
                }
            }
            sourceIndex += 1
        }

        if reader.status == .failed {
            throw BrushError.reader(reader.error?.localizedDescription ?? "reader failed mid-read")
        }
    }

    // MARK: - Upright rotation

    private static let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext(options: nil)
    }()

    /// Applies the track's `preferredTransform` so the buffer is upright
    /// before segmentation (§9.3).
    private static func uprighted(_ buffer: CVPixelBuffer, transform: CGAffineTransform) -> CVPixelBuffer {
        guard !transform.isIdentity else { return buffer }

        let source = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
        let extent = source.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
            return buffer
        }
        let normalized = source.transformed(
            by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))

        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(extent.width), Int(extent.height),
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out)
        guard status == kCVReturnSuccess, let out else { return buffer }

        ciContext.render(
            normalized, to: out,
            bounds: CGRect(origin: .zero, size: extent.size),
            colorSpace: CGColorSpaceCreateDeviceRGB())
        return out
    }
}

/// A tiny async semaphore bounding how many frames the producer may read
/// ahead of what the consumer has finished with.
private actor InFlightGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(capacity: Int) {
        available = max(1, capacity)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
