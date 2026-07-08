import AVFoundation

/// Bridges `AVCaptureFileOutputRecordingDelegate`'s Objective-C completion callback
/// to a plain Swift closure. `CaptureService` itself is not an `NSObject` (it stays a
/// plain `@Observable @MainActor` class per the frozen contract), so this small
/// adapter is what AVFoundation actually holds as the delegate.
///
/// AVFoundation calls `fileOutput(_:didFinishRecordingTo:from:error:)` on an internal
/// queue, not necessarily the main thread — callers MUST hop back to the main actor
/// themselves before touching `CaptureService` state.
final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let completion: (URL, Error?) -> Void

    init(completion: @escaping (URL, Error?) -> Void) {
        self.completion = completion
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        completion(outputFileURL, error)
    }
}
