import AppKit

/// Thin transparent strip pinned to the window's leading edge. Fires
/// hover-in / hover-out callbacks so the sidebar state machine can
/// reveal the hidden sidebar without stealing click routing from the
/// workspace content sitting behind it.
///
/// `hitTest` returns nil so mouseDown passes through to the pane
/// underneath (e.g. the left-most terminal's resize handle or a browser
/// column's URL bar). `NSTrackingArea` fires on cursor position
/// regardless of hit-test routing, so pass-through does not disable
/// hover detection.
///
/// The tracking rect spans the whole leading edge. Arc Browser famously
/// added a traffic-light exclusion zone here, but Arc kept its traffic
/// lights visible at all times — e05 ties their visibility to the
/// sidebar state, so while the sidebar is hidden the buttons are
/// `alpha=0` and cannot be clicked, and while the sidebar is revealed
/// the sidebar overlay itself occludes the edge zone.
@MainActor
final class EdgeHoverHitZoneView: NSView {
    /// Width of the hot strip. Narrow enough to avoid accidental
    /// triggering, wide enough to survive the cursor's sub-pixel
    /// movement on high-DPI displays.
    static let width: CGFloat = 8

    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) { onEnter?() }
    override func mouseExited(with _: NSEvent) { onExit?() }
}
