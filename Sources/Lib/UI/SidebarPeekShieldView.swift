import AppKit

/// Transparent absorber view that sits between the workspace pane
/// hierarchy and the sidebar overlay. Activated only while the
/// sidebar is in the unpinned hover-peek state, when the workspace
/// scroll view is *not* inset and panes (browser / terminal /
/// finder) physically extend under the glass.
///
/// `NSGlassEffectView`'s transparent regions don't claim cursor
/// rects, mouse-tracking events, or — through their hit-test
/// fall-through path — clicks; AppKit otherwise descends past the
/// sidebar overlay into the panes underneath. The shield lives in
/// the same parent view as the sidebar (one level above the
/// workspace VC), so the responder/cursor/hit-test machinery picks
/// it up *before* reaching the panes:
///
/// - `hitTest` returns `self` for any in-bounds point so click and
///   drag events stop here instead of leaking through to a pane.
/// - `resetCursorRects` claims the full bounds for `NSCursor.arrow`
///   so the column-resize cursor on a finder pane edge or the
///   pointing-hand cursor on a link the glass blurs over no longer
///   shows through the sidebar's transparent gaps.
/// - Empty `mouseDown` / `mouseDragged` / `mouseUp` overrides catch
///   any responder-chain ascent that bypasses the hit-test path.
///
/// `acceptsFirstMouse` returns `true` so a click that lands on the
/// shield while the window is inactive is absorbed in one go rather
/// than being consumed as a window-activation click that then falls
/// through to the pane on the second click.
///
/// CSS `:hover` inside the WebView is *not* addressed here — that's
/// driven by WebKit's internal `mouseMoved` tracking, which fires
/// independently of any sibling tracking area. Suppressing it cleanly
/// would require dropping `mouseMoved` at the application event
/// queue, which broke AppKit's mouse-entered/-exited synthesis for
/// the sidebar's own rows in earlier attempts; the link-hover bleed
/// is the one remaining cosmetic leak in the unpinned peek state.
@MainActor
final class SidebarPeekShieldView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard !isHidden, window != nil, bounds.contains(local) else { return nil }
    return self
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .arrow)
  }

  override func mouseDown(with _: NSEvent) {}
  override func mouseDragged(with _: NSEvent) {}
  override func mouseUp(with _: NSEvent) {}

  override var acceptsFirstResponder: Bool { false }
  override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}
