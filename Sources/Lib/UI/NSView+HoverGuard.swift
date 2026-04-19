import AppKit

extension NSView {
    /// Re-validate that the live cursor is still inside this view's
    /// bounds. Used to suppress spurious `mouseExited` events that
    /// AppKit delivers when the cursor crosses from a parent tracking
    /// area into a nested subview's tracking area (e.g. a hover-reveal
    /// button) — the parent receives an exit even though the cursor
    /// never actually left its rect.
    ///
    /// Intended only for views participating in hover-reveal tracking.
    /// Calling this from unrelated code pays a per-call `NSEvent.mouseLocation`
    /// read + coordinate conversion for no benefit — prefer the built-in
    /// `NSMouseInRect(point:bounds:flipped:)` when a point is already in hand.
    ///
    /// Returns `true` when the view has no window. A tearing-down cell
    /// (table reload, mode swap, sidebar dismantle) can't meaningfully
    /// check cursor position; treating it as "still inside" silences
    /// the teardown-time stray exit rather than triggering a reveal
    /// collapse as the view is already being removed.
    ///
    /// Uses `NSMouseInRect` over `bounds.contains` so a future flip of
    /// the view's `isFlipped` can't silently invert the check.
    func cursorIsStillInsideBounds() -> Bool {
        guard let window else { return true }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = convert(windowPoint, from: nil)
        return NSMouseInRect(localPoint, bounds, isFlipped)
    }
}
