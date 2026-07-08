import Foundation

/// Filesystem locations for BrushStore persistence (§10.1).
///
/// `baseURL` stands in for "Application Support" in production, but is
/// injectable so tests can point the whole store at an isolated temp
/// directory without ever touching the real app container.
struct StorePaths {
    let baseURL: URL

    var brushesDir: URL {
        baseURL.appendingPathComponent("Brushes", isDirectory: true)
    }

    var indexURL: URL {
        brushesDir.appendingPathComponent("index.json", isDirectory: false)
    }

    var canvasDir: URL {
        baseURL.appendingPathComponent("Canvas", isDirectory: true)
    }

    var canvasPNGURL: URL {
        canvasDir.appendingPathComponent("canvas.png", isDirectory: false)
    }

    func brushDir(_ id: String) -> URL {
        brushesDir.appendingPathComponent(id, isDirectory: true)
    }

    /// The real on-device location: `<Application Support>/`.
    static func defaultBaseURL(fileManager: FileManager = .default) -> URL {
        if let url = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return url
        }
        // Extremely unlikely on iOS, but never crash paths resolution.
        return fileManager.temporaryDirectory
    }
}
