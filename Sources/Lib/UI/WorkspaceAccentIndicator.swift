import AppKit

/// 3pt-wide vertical bar that marks each workspace row in the
/// sidebar. Renders either a solid rounded pill (normal workspaces)
/// or a vertical dashed line (private workspaces) so the worklane
/// header carries the same visual cue as the in-content focus
/// border.
@MainActor
final class WorkspaceAccentIndicator: NSView {
  /// Tint shared with the workspace's pane focus border.
  var color: NSColor = .clear { didSet { needsDisplay = true } }

  /// `true` switches the rendering from a solid rounded pill to a
  /// dashed vertical line — same accent colour, different visual
  /// vocabulary. Mirrors the `DottedBorderOverlay` style used on
  /// private panes.
  var isPrivate: Bool = false { didSet { needsDisplay = true } }

  /// Dash pattern for the private rendering (`[on, off]` in points).
  /// 3pt-on / 3pt-off reads cleanly at the 3pt bar width without
  /// tipping into "blocks of colour" territory.
  var dashPattern: [CGFloat] = [3, 3]

  /// Corner radius for the solid rendering. Mirrors the original
  /// `layer.cornerRadius = 1.5` look so swapping a non-private row
  /// to the custom view doesn't reshape its pill.
  var cornerRadius: CGFloat = 1.5

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = false
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  override var isOpaque: Bool { false }

  override func draw(_: NSRect) {
    if isPrivate {
      // Vertical dashed line rendered as a thick stroke down the
      // middle. Stroking with `lineWidth = bounds.width` and butt
      // line caps fills the bar's full width while the dash pattern
      // breaks it into segments — much simpler than tiling a list
      // of small rectangles.
      let path = NSBezierPath()
      path.move(to: NSPoint(x: bounds.midX, y: bounds.minY))
      path.line(to: NSPoint(x: bounds.midX, y: bounds.maxY))
      path.lineWidth = bounds.width
      path.lineCapStyle = .butt
      path.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
      color.setStroke()
      path.stroke()
    } else {
      let path = NSBezierPath(
        roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius
      )
      color.setFill()
      path.fill()
    }
  }
}
