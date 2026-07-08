import Foundation

/// Pure helpers factored out of `CaptureService` so the clamp/progress logic that
/// drives FR-2/FR-3 can be unit-tested without touching AVFoundation or a real
/// camera (the simulator has none). No side effects, no state.
enum CaptureMath {
    /// Progress toward the recording cap, 0...1, monotonic and clamped even if
    /// `elapsed` overshoots `maxClipSec` (e.g. a late timer tick before auto-stop
    /// tears things down).
    static func progress(elapsed: Double, maxClipSec: Double) -> Double {
        guard maxClipSec > 0 else { return 0 }
        return min(1, max(0, elapsed / maxClipSec))
    }

    /// FR-2: a finished clip shorter than `minClipSec` is discarded ("Hold longer")
    /// rather than handed off to the pipeline.
    static func isTooShort(duration: Double, minClipSec: Double) -> Bool {
        duration < minClipSec
    }
}
