import AppKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "EdgeHover")

/// Thin transparent strip pinned to the window's leading edge. Fires
/// hover-in / hover-out callbacks so the sidebar state machine can
/// reveal the hidden sidebar without stealing click routing from the
/// workspace content sitting behind it.
///
/// `hitTest` returns nil so mouseDown passes through to the pane
/// underneath (e.g. the left-most terminal's resize handle or a browser
/// column's URL bar). `NSTrackingArea` fires on cursor position
/// regardless of hit-test routing, so pass-through does not disable
/// hover detection.
///
/// The tracking rect spans the whole leading edge. Arc Browser famously
/// added a traffic-light exclusion zone here, but Arc kept its traffic
/// lights visible at all times — e05 ties their visibility to the
/// sidebar state, so while the sidebar is hidden the buttons are
/// `alpha=0` and cannot be clicked, and while the sidebar is revealed
/// the sidebar overlay itself occludes the edge zone.
@MainActor
final class EdgeHoverHitZoneView: NSView {
  /// Width of the hot strip. Narrow enough to avoid accidental
  /// triggering, wide enough to survive the cursor's sub-pixel
  /// movement on high-DPI displays.
  static let width: CGFloat = 8

  /// Height for top-edge variants of the strip (e.g. the per-pane
  /// URL bar peek hit zone). Wider than `width` because pane
  /// vertical splits squeeze the cursor target tighter than a
  /// window edge, so a deliberate flick to the top still has room
  /// to land.
  static let topEdgeHeight: CGFloat = 12

  var onEnter: (() -> Void)?
  var onExit: (() -> Void)?

  private var trackingArea: NSTrackingArea?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  override func hitTest(_: NSPoint) -> NSView? { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let old = trackingArea { removeTrackingArea(old) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    trackingArea = area
    syncHoverWithCurrentCursor()
  }

  override func mouseEntered(with _: NSEvent) {
    logger.debug("mouseEntered")
    onEnter?()
  }

  override func mouseExited(with _: NSEvent) {
    logger.debug("mouseExited")
    onExit?()
  }

  /// AppKit skips the synthesised `mouseEntered` when a freshly
  /// installed tracking area already contains the cursor — classically
  /// observed as "edge hover does nothing at launch; ⌘B reveals the
  /// sidebar and afterwards edge hover starts working". Probe the
  /// cursor ourselves after every rebuild and, if it's already inside,
  /// fire `onEnter` so the state machine can catch up. Do *not* probe
  /// `onExit`: `updateTrackingAreas` runs on every layout pass, and a
  /// spurious exit would bump the sidebar's state generation and
  /// invalidate a pending `scheduleHoverIn` asyncAfter — the exact
  /// regression that turned this fix into "edge hover never fires".
  /// `mouseExited` continues to handle real cursor exits through the
  /// normal event path.
  private func syncHoverWithCurrentCursor() {
    guard let window else { return }
    let mouseInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    if bounds.contains(mouseInView) {
      onEnter?()
    }
  }
}
