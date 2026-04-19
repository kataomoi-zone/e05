import AppKit

/// Top 36pt strip inside the sidebar overlay. The left portion sits
/// under the OS traffic lights (which stay at their default position
/// thanks to `titlebarAppearsTransparent`); the trailing edge hosts the
/// pin toggle button. Click invokes `onTogglePin`, which the view
/// controller routes into the `SidebarState` machine.
@MainActor
final class SidebarHeaderView: NSView {
    static let height: CGFloat = 36

    let pinButton: HoverIconButton = {
        let b = HoverIconButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.imageScaling = .scaleProportionallyDown
        return b
    }()

    /// Invoked when the user clicks the pin toggle. The view controller
    /// owns the state machine — this view only reports intent.
    var onTogglePin: (() -> Void)?

    /// Drives the pin icon glyph and accessibility text. When `true`,
    /// the filled pin emphasises the "currently pinned" state; when
    /// `false`, the outline pin signals the action the click will take
    /// (pin the sidebar).
    var isPinned: Bool = false {
        didSet { updatePinAppearance() }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupLayout()
        updatePinAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func setupLayout() {
        pinButton.target = self
        pinButton.action = #selector(pinTapped(_:))
        addSubview(pinButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            pinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 22),
            pinButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    private func updatePinAppearance() {
        let symbol = isPinned ? "pin.fill" : "pin"
        let description = isPinned ? "Unpin sidebar" : "Pin sidebar"
        pinButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        pinButton.toolTip = description
    }

    @objc private func pinTapped(_: NSButton) {
        onTogglePin?()
    }
}
