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
            continuation.finish(throwing: BrushError.reader("BrushFactory not yet implemented — Wave 1B"))
        }
    }
}
