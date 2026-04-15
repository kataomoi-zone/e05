import AppKit

/// A column in the horizontal scroll container, holding one or more vertically-stacked panes.
@MainActor
public final class ColumnModel {
    public let id = UUID()
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
        stack.spacing = 2
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    public var focusedPane: PaneModel? {
        panes[safe: focusedPaneIndex]
    }

    public init(pane: PaneModel) {
        self.panes = [pane]
    }
}
