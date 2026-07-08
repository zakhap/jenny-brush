import Foundation

/// On-disk schema for `Brushes/index.json` (§10.1): the ordered list of brush
/// ids (most-recent-first, matching `BrushStore.brushes`) plus the active id.
/// Internal to BrushStore — nothing else reads this file.
struct BrushIndex: Codable, Equatable {
    var order: [String]
    var activeID: String?

    static let empty = BrushIndex(order: [], activeID: nil)
}
