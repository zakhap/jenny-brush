import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Plays a looping GIF (the shelf preview, §10.4) cheaply via UIImageView's
/// animatedImage — no per-cell Metal rendering, so 50-brush scrolling stays smooth (FR-18).
struct AnimatedImageView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        iv.image = Self.animatedImage(from: url)
        iv.startAnimating()
        return iv
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        if uiView.image == nil { uiView.image = Self.animatedImage(from: url) }
        uiView.startAnimating()
    }

    static func animatedImage(from url: URL) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        var frames: [UIImage] = []
        var duration: Double = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            duration += Self.frameDelay(src, i)
        }
        guard !frames.isEmpty else { return nil }
        if duration <= 0 { duration = Double(frames.count) / 12.0 }
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    private static func frameDelay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        return unclamped ?? clamped ?? 0.1
    }
}
