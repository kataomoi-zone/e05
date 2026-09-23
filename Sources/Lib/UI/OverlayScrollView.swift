import AppKit

/// NSScrollView that forces overlay scrollers regardless of system preference.
/// Overrides the getter to always return .overlay, and re-applies on system
/// preference changes (e.g. mouse connect/disconnect).
final class OverlayScrollView: NSScrollView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    NotificationCenter.default.addObserver(
      self, selector: #selector(scrollerStyleDidChange),
      name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil
    )
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { NotificationCenter.default.removeObserver(self) }

  override var scrollerStyle: NSScroller.Style {
    get { .overlay }
    set { super.scrollerStyle = .overlay }
  }

  /// Set while the pane map has this workspace laid out as one of its
  /// rows. AppKit scrolls a clip view on its own to reveal things — the
  /// first responder after a layout pass, a view asking to be visible —
  /// and in the map that drags the row's columns sideways under a map that
  /// is not moving, which reads as the whole thing jumping. Writes from
  /// e05 itself go to the clip view's bounds and are unaffected.
  var freezesScrolling = false

  override func scroll(_ clipView: NSClipView, to point: NSPoint) {
    guard !freezesScrolling else { return }
    super.scroll(clipView, to: point)
  }

  @objc private func scrollerStyleDidChange(_ notification: Notification) {
    super.scrollerStyle = .overlay
  }
}
