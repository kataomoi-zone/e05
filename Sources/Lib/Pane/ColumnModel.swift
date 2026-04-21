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

  /// Whether the column is folded (collapsed to a narrow strip showing only title).
  public var isFolded: Bool = false
  /// Width before folding — used to restore on unfold.
  public var unfoldedWidth: CGFloat = 0

  /// Vertical stack view holding the pane terminal views.
  public let containerView: NSStackView = {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 0  // vertical resize handles serve as spacing
    stack.distribution = .fill
    // Keep hidden panes in the arrangedSubviews when folded so equal-height
    // constraints stay intact and unfold restores the original ratios.
    stack.detachesHiddenViews = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  /// Equal height constraints between panes. Deactivated when user drags to resize.
  var equalHeightConstraints: [NSLayoutConstraint] = []

  /// Vertical-text label shown when the column is folded.
  public let foldedLabelView: FoldedLabelView = {
    let label = FoldedLabelView()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.isHidden = true
    return label
  }()

  public var focusedPane: PaneModel? {
    panes[safe: focusedPaneIndex]
  }

  public init(pane: PaneModel) {
    self.panes = [pane]
  }
}
