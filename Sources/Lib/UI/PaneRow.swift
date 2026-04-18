import AppKit

/// One row in the sidebar worklane section representing a single pane.
/// Indented under its owning workspace header. The currently focused
/// pane gets a 2pt border in the current workspace's accent color
/// (matching the in-content focus border) so the sidebar mirrors the
/// workspace focus state. Clicking fires `onClick` which the sidebar
/// routes to `PaneContainerViewController.focusPane(id:)` (cross-WS
/// safe via the stage 0-A API).
@MainActor
final class PaneRow: NSView {
    static let height: CGFloat = 24

    let paneId: ULID
    var onClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "")

    init(paneId: ULID, title: String, accentColor: NSColor, isCurrent: Bool) {
        self.paneId = paneId
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setupLayout()
        configure(title: title, accentColor: accentColor, isCurrent: isCurrent)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func setupLayout() {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.drawsBackground = false
        label.font = NSFont.systemFont(ofSize: 12)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            // Indent so pane rows sit visually to the right of the
            // workspace indicator (8pt margin + 3pt indicator + 10pt gap = 21pt).
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func configure(title: String, accentColor: NSColor, isCurrent: Bool) {
        label.stringValue = title
        label.alphaValue = isCurrent ? 1.0 : 0.8
        if isCurrent {
            layer?.borderWidth = 2
            layer?.borderColor = accentColor.cgColor
            layer?.cornerRadius = 4
        } else {
            layer?.borderWidth = 0
            layer?.borderColor = nil
            layer?.cornerRadius = 0
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
