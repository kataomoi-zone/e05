import AppKit

/// Transparent overlay view that paints a dashed rectangular border.
/// Used to mark panes and worklane rows belonging to a private
/// workspace so the user can tell at a glance which surface is
/// running in the ephemeral data store.
///
/// `draw(_:)` redraws on every layout pass, so the overlay can use a
/// plain autoresizing mask and the border path always tracks the
/// current bounds — a `CAShapeLayer` would have needed manual path
/// updates on every resize. The view is hit-test transparent so
/// clicks fall through to the surface beneath; a private pane's
/// content stays interactive.
@MainActor
final class DottedBorderOverlay: NSView {
  /// Stroke color. Mirrors the workspace's accent so the dotted
  /// indicator carries the same colour identity as the solid focus
  /// border on non-private workspaces.
  var borderColor: NSColor = .systemBlue {
    didSet { needsDisplay = true }
  }

  /// Stroke width. The default 2pt matches the historical
  /// `focusBorderWidth` so the initial dotted-vs-solid swap
  /// preserves the layout footprint; in practice the focus apply
  /// path overwrites this with `AppMetrics.focusedPaneBorderWidth`
  /// so the dotted private-pane border tracks the same Appearance
  /// preset as the solid border.
  var borderWidth: CGFloat = 2 {
    didSet { needsDisplay = true }
  }

  /// Dash pattern in points (`[on, off]`). Defaults match the visual
  /// weight of macOS's own focus rings while staying clearly
  /// "dotted" rather than "dashed".
  var dashPattern: [CGFloat] = [4, 3] {
    didSet { needsDisplay = true }
  }

  /// Corner radius. Set to the pane container view's `cornerRadius`
  /// (12pt) so the dotted border traces the same rounded rectangle.
  var cornerRadius: CGFloat = 12 {
    didSet { needsDisplay = true }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    autoresizingMask = [.width, .height]
    // The overlay paints transparently around its border — opting out
    // of layer backing avoids the extra compositing cost the host
    // pane already pays through its own layer.
    wantsLayer = false
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  override var isOpaque: Bool { false }

  /// Click pass-through so a private pane's content is fully
  /// interactive — the overlay only exists for visual indication.
  override func hitTest(_: NSPoint) -> NSView? { nil }

  override func draw(_: NSRect) {
    let inset = borderWidth / 2
    let rect = bounds.insetBy(dx: inset, dy: inset)
    // Shrink the corner radius by the same amount we inset the rect
    // so the stroke's outer arc traces the host layer's masked
    // corner instead of overshooting it: a host with
    // `layer.cornerRadius = 12` clips the stroke at radius 12, but a
    // path drawn with the same 12 radius on an inset rect places its
    // arc center 1pt inwards, which left dashes at the corners
    // partially clipped (visible against `CALayer.borderWidth`'s
    // inward stroke). Matching the inset gives a continuous dashed
    // outline that reads identically to the solid border.
    let strokedRadius = max(0, cornerRadius - inset)
    let path: NSBezierPath
    if strokedRadius > 0 {
      path = NSBezierPath(
        roundedRect: rect, xRadius: strokedRadius, yRadius: strokedRadius
      )
    } else {
      path = NSBezierPath(rect: rect)
    }
    path.lineWidth = borderWidth
    path.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
    borderColor.setStroke()
    path.stroke()
  }
}
