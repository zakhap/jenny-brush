import Metal

// =============================================================================
// Undo & clear (§11.4). Strokes are kept as GPU-ready stamp lists (resolved
// against whatever brush/atlas texture was active when the stroke was drawn),
// so undo-replay is correct even if the user switched the active brush
// afterwards — the stroke's own texture reference travels with it.
// =============================================================================

/// One committed stroke, ready to redraw: its instanced-quad data plus the
/// atlas texture those instances sample from.
struct CommittedStroke {
    let instances: [StampInstanceData]
    let atlasTexture: MTLTexture
}

/// Bounded stack of the last `K.undoDepth` strokes. Pushing beyond capacity
/// evicts (and returns) the oldest stroke so the caller can bake it into the
/// replay base texture — it stays visible on canvas, it just stops being
/// individually undoable (FR-23).
final class UndoStack {
    private(set) var strokes: [CommittedStroke] = []

    var isEmpty: Bool { strokes.isEmpty }

    /// Pushes a newly committed stroke. Returns the evicted stroke, if any.
    @discardableResult
    func push(_ stroke: CommittedStroke) -> CommittedStroke? {
        strokes.append(stroke)
        if strokes.count > K.undoDepth {
            return strokes.removeFirst()
        }
        return nil
    }

    /// Pops the most recent stroke (undo). Returns nil if the stack is empty.
    func popLast() -> CommittedStroke? {
        strokes.popLast()
    }

    /// Clear-canvas: empties the stack entirely (FR-23).
    func removeAll() {
        strokes.removeAll()
    }
}
