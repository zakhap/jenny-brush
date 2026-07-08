import AVFoundation
import CoreGraphics
import Foundation

/// The full brush-creation pipeline: video URL → BrushAsset (§9.3–§9.6).
///
/// PUBLIC API IS A FROZEN CONTRACT. The Wave-1B agent implements the four
/// pipeline stages (FrameSampler, SubjectSegmenter, StampProcessor, AtlasPacker)
/// as private files inside BrushFactory/, but MUST keep this entry point stable.
struct BrushFactory {
    init() {}

    /// Runs the pipeline, streaming `.frame` progress for the theater (FR-12) and
    /// finishing with `.built(BrushAsset)` whose `directoryURL` is a TEMP dir
    /// containing manifest.json + atlas-*.heic. The caller (BrushStore.commit)
    /// generates the preview and atomically moves it into place (§10.3).
    ///
    /// The stream throws `BrushError.noSubject` if fewer than K.minUsableFrames
    /// frames yield a usable mask (FR-10), `.cancelled` on task cancellation (E5),
    /// or `.reader`/`.io` on lower-level failures (§13).
    ///
    /// - Parameters:
    ///   - videoURL: local temp `.mov` from CaptureService.
    ///   - name: auto-generated display name (from BrushStore.autoName()).
    ///   - brushID: UUID string; also the temp/permanent directory name.
    func makeBrush(from videoURL: URL, name: String, brushID: String)
        -> AsyncThrowingStream<BrushProgress, Error>
    {
        AsyncThrowingStream { continuation in
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("BrushFactory-\(brushID)", isDirectory: true)

            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await Self.run(
                        videoURL: videoURL, name: name, brushID: brushID,
                        tempDir: tempDir, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    Self.cleanup(tempDir)
                    continuation.finish(throwing: BrushError.cancelled)
                } catch let error as BrushError {
                    Self.cleanup(tempDir)
                    continuation.finish(throwing: error)
                } catch {
                    Self.cleanup(tempDir)
                    continuation.finish(throwing: BrushError.reader("\(error)"))
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    task.cancel()
                }
            }
        }
    }

    // MARK: - Orchestration

    /// Stages 1→2 pipelined (segmentation is sequential by nature — each pick
    /// depends on the previous track state); stage 3 (stamp production) for a
    /// hit frame runs concurrently with segmentation of the following frame,
    /// then is awaited and its progress emitted in order before the next hit's
    /// stamp task is started (§9.6 concurrency note).
    private static func run(
        videoURL: URL, name: String, brushID: String, tempDir: URL,
        continuation: AsyncThrowingStream<BrushProgress, Error>.Continuation
    ) async throws {
        let probeAsset = AVURLAsset(url: videoURL)
        let duration = try await probeAsset.load(.duration).seconds
        var currentTotal = max(1, min(K.maxFrames, Int((duration * K.samplingFPS).rounded(.up))))

        let segmenter = SubjectSegmenter()
        var stamps: [StampData] = []
        var lastStamp: StampData?

        // The most recently spawned stamp-processing task whose progress
        // event has not yet been emitted. Resolved just before it would be
        // superseded by a new pick, or at the end of the stream — giving
        // stage 3 the whole subsequent segmentation call to run in the
        // background before we need its result.
        var pending: (index: Int, task: Task<StampData?, Never>)?

        func resolvePending() async {
            guard let p = pending else { return }
            pending = nil
            if let stamp = await p.task.value {
                stamps.append(stamp)
                lastStamp = stamp
                continuation.yield(.frame(index: p.index, total: currentTotal, cutout: stamp.cgImage))
            } else if let prev = lastStamp {
                // Degenerate matte at hit time: fall back to duplicating the
                // previous stamp, same as a miss (FR-9).
                let dup = duplicate(of: prev, index: p.index)
                stamps.append(dup)
                continuation.yield(.frame(index: p.index, total: currentTotal, cutout: dup.cgImage))
            }
        }

        let (stream, release) = FrameSampler.sample(url: videoURL)

        do {
            for try await frame in stream {
                try Task.checkCancellation()
                currentTotal = max(currentTotal, frame.index + 1)

                switch segmenter.process(frame.pixelBuffer) {
                case .hit(let matte):
                    let idx = frame.index
                    let pixelBuffer = frame.pixelBuffer
                    let stampTask = Task.detached(priority: .userInitiated) { () -> StampData? in
                        StampProcessor.makeStamp(index: idx, pixelBuffer: pixelBuffer, matte: matte)
                    }
                    await resolvePending()
                    pending = (idx, stampTask)

                case .miss:
                    await resolvePending()
                    if let prev = lastStamp {
                        let dup = duplicate(of: prev, index: frame.index)
                        stamps.append(dup)
                        continuation.yield(.frame(index: frame.index, total: currentTotal, cutout: dup.cgImage))
                    }
                    // No previous stamp yet (misses before the first hit):
                    // nothing to show or reuse; the frame is simply dropped.
                }

                await release()
            }
        } catch is CancellationError {
            throw BrushError.cancelled
        } catch {
            // Reader/Vision throw mid-job (§13): proceed with what we have if
            // there are enough hits already, otherwise it's the same failure
            // mode as finding no subject at all.
            if segmenter.hitCount < K.minUsableFrames {
                throw BrushError.noSubject
            }
        }

        await resolvePending()

        guard segmenter.hitCount >= K.minUsableFrames else {
            throw BrushError.noSubject
        }

        try Task.checkCancellation()

        let packed = AtlasPacker.build(
            stamps: stamps, brushID: brushID, name: name, sourceDuration: duration)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for (i, page) in packed.pageImages.enumerated() {
            try AtlasPacker.writeHEIC(page, to: tempDir.appendingPathComponent("atlas-\(i).heic"))
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(packed.manifest)
        do {
            try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"), options: .atomic)
        } catch {
            throw BrushError.io
        }

        let asset = BrushAsset(id: brushID, name: name, manifest: packed.manifest, directoryURL: tempDir)
        continuation.yield(.built(asset))
    }

    private static func duplicate(of prev: StampData, index: Int) -> StampData {
        StampData(
            index: index, cgImage: prev.cgImage, anchor: prev.anchor,
            pixelSize: prev.pixelSize, duplicateOf: prev.duplicateOf ?? prev.index)
    }

    private static func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}
