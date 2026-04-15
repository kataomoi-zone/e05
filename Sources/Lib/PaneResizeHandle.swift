import AppKit

/// Thin view between panes that handles drag-to-resize.
/// Transparent by default, shows indicator on hover.
@MainActor
public final class PaneResizeHandle: NSView {
    static let handleWidth: CGFloat = 6

    /// Called during drag with the horizontal delta.
    public var onDrag: ((_ deltaX: CGFloat) -> Void)?

    /// Only active handles (adjacent to focused pane) show resize cursor and respond to drag.
    public var isActive: Bool = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    private var dragStartX: CGFloat = 0
    private var isHovering = false
    private var isDragging = false
    private var cursorPushed = false

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = nil // transparent by default
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    // MARK: - Tracking & Cursor

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
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
            NSCursor.resizeLeftRight.push()
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
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }

    // MARK: - Drag

    public override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        isDragging = true
        dragStartX = event.locationInWindow.x
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isActive, isDragging else { return }
        let deltaX = event.locationInWindow.x - dragStartX
        dragStartX = event.locationInWindow.x
        onDrag?(deltaX)
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
        return [handle.widthAnchor.constraint(equalToConstant: handleWidth)]
    }
}
