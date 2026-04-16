import AppKit

/// NSButton subclass that provides hover feedback: pointing-hand cursor and subtle background tint.
@MainActor
public final class HoverIconButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateHoverAppearance() }
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isEnabled: Bool {
        didSet {
            // Clear stale hover state if the button becomes disabled while hovered,
            // so the tint doesn't linger until the next mouseExited.
            if !isEnabled { isHovering = false }
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func cursorUpdate(with event: NSEvent) {
        if isEnabled {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = isEnabled
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
    }

    private func updateHoverAppearance() {
        layer?.backgroundColor = isHovering
            ? NSColor(white: 1.0, alpha: 0.1).cgColor
            : nil
    }
}
