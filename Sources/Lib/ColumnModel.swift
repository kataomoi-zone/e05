import AppKit

/// A column in the horizontal scroll container, holding one or more vertically-stacked panes.
@MainActor
public final class ColumnModel {
    public let id = ULID()
    public var panes: [PaneModel]
    public var focusedPaneIndex: Int = 0

    /// Width constraint for the column's container view.
    public var widthConstraint: NSLayoutConstraint?
    /// Currently applied width preset. nil = default fixed width.
    public var currentPreset: PaneWidthPreset?

    /// Vertical stack view holding the pane terminal views.
    public let containerView: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0  // vertical resize handles serve as spacing
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    /// Equal height constraints between panes. Deactivated when user drags to resize.
    var equalHeightConstraints: [NSLayoutConstraint] = []

    public var focusedPane: PaneModel? {
        panes[safe: focusedPaneIndex]
    }

    public init(pane: PaneModel) {
        self.panes = [pane]
    }
}
