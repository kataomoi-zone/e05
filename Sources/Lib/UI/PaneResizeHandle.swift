import AppKit

/// Thin view between panes/columns that handles drag-to-resize.
/// Transparent by default, shows indicator on hover.
@MainActor
public final class PaneResizeHandle: NSView {
  public enum Orientation {
    case horizontal  // between columns (left-right drag)
    case vertical  // between panes within a column (up-down drag)
  }

  static let handleSize: CGFloat = 6

  public let orientation: Orientation

  /// Called during drag with the delta along the resize axis.
  public var onDrag: ((_ delta: CGFloat) -> Void)?

  /// Only active handles (adjacent to focused pane) show resize cursor and respond to drag.
  public var isActive: Bool = false {
    didSet { window?.invalidateCursorRects(for: self) }
  }

  private var dragStartPos: CGFloat = 0
  private var isHovering = false
  private var isDragging = false
  private var cursorPushed = false

  public init(orientation: Orientation) {
    self.orientation = orientation
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = nil
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  private var resizeCursor: NSCursor {
    orientation == .horizontal ? .resizeLeftRight : .resizeUpDown
  }

  // MARK: - Tracking & Cursor

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self
      ))
  }

  public override func mouseEntered(with _: NSEvent) {
    guard isActive else { return }
    isHovering = true
    layer?.backgroundColor = NSColor.separatorColor.cgColor
    if !cursorPushed {
      resizeCursor.push()
      cursorPushed = true
    }
  }

  public override func mouseExited(with _: NSEvent) {
    guard isHovering else { return }
    isHovering = false
    guard !isDragging else { return }
    layer?.backgroundColor = nil
    if cursorPushed {
      NSCursor.pop()
      cursorPushed = false
    }
  }

  public override func resetCursorRects() {
    if isActive {
      addCursorRect(bounds, cursor: resizeCursor)
    }
  }

  // MARK: - Drag

  public override func mouseDown(with event: NSEvent) {
    guard isActive else { return }
    isDragging = true
    dragStartPos =
      orientation == .horizontal
      ? event.locationInWindow.x
      : event.locationInWindow.y
  }

  public override func mouseDragged(with event: NSEvent) {
    guard isActive, isDragging else { return }
    let currentPos =
      orientation == .horizontal
      ? event.locationInWindow.x
      : event.locationInWindow.y
    let delta = currentPos - dragStartPos
    dragStartPos = currentPos
    onDrag?(delta)
  }

  public override func mouseUp(with _: NSEvent) {
    isDragging = false
    if !isHovering {
      layer?.backgroundColor = nil
      if cursorPushed {
        NSCursor.pop()
        cursorPushed = false
      }
    }
  }

  // MARK: - Constraints

  public static func makeConstraints(for handle: PaneResizeHandle) -> [NSLayoutConstraint] {
    handle.translatesAutoresizingMaskIntoConstraints = false
    return switch handle.orientation {
    case .horizontal:
      [handle.widthAnchor.constraint(equalToConstant: handleSize)]
    case .vertical:
      [handle.heightAnchor.constraint(equalToConstant: handleSize)]
    }
  }
}
