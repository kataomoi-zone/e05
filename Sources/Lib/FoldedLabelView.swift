import AppKit

/// A view that displays text rotated 90° clockwise (top-to-bottom), for folded column strips.
/// Includes an expand button at the top that unfolds the column.
@MainActor
public final class FoldedLabelView: NSView {
    private let label: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 11, weight: .medium)
        tf.textColor = NSColor(white: 0.8, alpha: 1.0)
        tf.lineBreakMode = .byTruncatingTail
        tf.alignment = .center
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.isEditable = false
        tf.isSelectable = false
        return tf
    }()

    /// Expand button shown at the top of the folded strip.
    private let expandButton: NSButton = {
        let btn = HoverIconButton()
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        if let image = NSImage(systemSymbolName: "arrow.left.and.line.vertical.and.arrow.right",
                               accessibilityDescription: "Expand")?
            .withSymbolConfiguration(config)
        {
            btn.image = image
            btn.imagePosition = .imageOnly
        } else {
            btn.title = "\u{25B6}"
        }
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.contentTintColor = NSColor(white: 0.7, alpha: 1.0)
        btn.toolTip = "Expand column"
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    /// Called when the strip is clicked (anywhere except expand button).
    public var onClicked: (() -> Void)?
    /// Called when the expand button is clicked.
    public var onExpandClicked: (() -> Void)?

    public var text: String = "" {
        didSet {
            label.stringValue = text
            needsLayout = true
        }
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor

        // Rotate label -90° (clockwise) so text reads top-to-bottom (Watchtower-style).
        label.frameCenterRotation = -90
        addSubview(label)

        expandButton.target = self
        expandButton.action = #selector(expandAction)
        addSubview(expandButton)
        NSLayoutConstraint.activate([
            expandButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            expandButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            expandButton.widthAnchor.constraint(equalToConstant: 22),
            expandButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @objc private func expandAction() {
        onExpandClicked?()
    }

    public override func mouseDown(with event: NSEvent) {
        onClicked?()
        super.mouseDown(with: event)
    }

    public override func layout() {
        super.layout()

        // Reserve space at top for expand button (24pt) + padding
        let topReserved: CGFloat = 28
        let bottomPadding: CGFloat = 8

        // Label extends vertically from below the button to near bottom.
        // Before rotation: width = vertical extent, height = the font's line height.
        let verticalExtent = max(0, bounds.height - topReserved - bottomPadding)
        // intrinsicContentSize adapts to font changes; fall back to 20 if it's zero
        // (e.g. empty string with certain font configs).
        let labelHeight = max(20, ceil(label.intrinsicContentSize.height))
        let labelSize = NSSize(width: verticalExtent, height: labelHeight)

        // Set frame in non-rotated coordinates, then re-apply rotation —
        // NSView's frame setter interprets the rect as a post-rotation bounding
        // box, so the zero-rotation roundtrip is required to place the
        // un-rotated content at the intended size and origin.
        label.frameCenterRotation = 0
        label.frame = NSRect(origin: .zero, size: labelSize)

        // Center horizontally; vertically center within the area below the button.
        let availableTop = bottomPadding
        let availableBottom = bounds.height - topReserved
        let centerY = (availableTop + availableBottom) / 2
        label.setFrameOrigin(NSPoint(
            x: bounds.midX - labelSize.width / 2,
            y: centerY - labelSize.height / 2
        ))
        label.frameCenterRotation = -90
    }
}
