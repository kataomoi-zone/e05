import AppKit

/// Thin view between panes/columns that handles drag-to-resize.
/// Transparent by default, shows indicator on hover.
@MainActor
public final class PaneResizeHandle: NSView {
  public enum Orientation {
    case horizontal  // between columns (left-right drag)
    case vertical  // between panes within a column (up-down drag)
  }

  /// Current handle thickness, driven by the ``PaneGapPreset`` the
  /// user has selected. Read at handle-creation time and re-read on
  /// the live-update fan-out (see ``PaneContainerViewController``
  /// `applyPaneGap`). Defaults to the historical 6pt when no
  /// preference is set.
  static var handleSize: CGFloat {
    PaneGapPreset.resolve(PreferencesStore.shared.preferences.paneGap).value
  }

  public let orientation: Orientation

  /// Active width (`.horizontal`) or height (`.vertical`) constraint
  /// for this handle. Held weakly because the constraint is owned by
  /// the layout; the gap preset rewrites `.constant` through this
  /// reference to drive a live update without rebuilding the handle.
  public weak var sizeConstraint: NSLayoutConstraint?

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

  public override func mouseUp(with event: NSEvent) {
    isDragging = false
    // AppKit suppresses mouseEntered/Exited while a button is held, so the
    // resize drag often ends with the cursor pushed off the handle (the
    // divider moved out from under it) without an exit ever firing. Re-derive
    // hover state from the actual pointer location instead of trusting the
    // stale flag, otherwise the highlight and resize cursor get stranded.
    isHovering = bounds.contains(convert(event.locationInWindow, from: nil))
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
    let sizeConstraint: NSLayoutConstraint =
      switch handle.orientation {
      case .horizontal:
        handle.widthAnchor.constraint(equalToConstant: handleSize)
      case .vertical:
        handle.heightAnchor.constraint(equalToConstant: handleSize)
      }
    handle.sizeConstraint = sizeConstraint
    return [sizeConstraint]
  }
}
