import AppKit

/// Top 36pt strip inside the sidebar overlay. The left portion sits under
/// the OS traffic lights (which remain at their default position thanks to
/// `titlebarAppearsTransparent`), while the trailing edge hosts the pin
/// toggle button. Stage 1 wires the button as a placeholder only — the real
/// hover ↔ pinned state machine lands in stage 4.
@MainActor
final class SidebarHeaderView: NSView {
    static let height: CGFloat = 36

    let pinButton: HoverIconButton = {
        let b = HoverIconButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Toggle sidebar pin")
        b.imageScaling = .scaleProportionallyDown
        b.toolTip = "Toggle sidebar pin"
        return b
    }()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupLayout()
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

    // Stage 1 placeholder — the real pin/unpin toggle ships in stage 4
    // once the `SidebarState` state machine is in place.
    @objc private func pinTapped(_: NSButton) {
        NSLog("[e05/sidebar] pin button tapped (placeholder, wiring in stage 4)")
    }
}
