import AppKit

/// A column in the horizontal scroll container, holding one or more vertically-stacked panes.
@MainActor
public final class ColumnModel {
  /// Stable identity across reloads — also persisted through
  /// `SessionState.ColumnState.id` so the sidebar's `collapsedIds`
  /// set survives a save/restore round-trip.
  public let id: ULID
  public var panes: [PaneModel]
  public var focusedPaneIndex: Int = 0

  /// Width constraint for the column's container view. Created at
  /// `required - 1` priority so the minimum-width floor below wins
  /// when the requested constant is below the floor; this constraint
  /// then expresses the column's preferred width.
  public var widthConstraint: NSLayoutConstraint?
  /// Minimum-width floor enforced by Auto Layout regardless of which
  /// path writes to `widthConstraint.constant` (drag handles, cycle-
  /// width preset, session restore). Deactivated by the fold path so
  /// the 30pt folded strip is allowed; reactivated on unfold.
  public var minimumWidthConstraint: NSLayoutConstraint?
  /// Height constraint pinning the column to its hosting workspace's
  /// stack view, with the constant set to `-(outerMargin * 2)` so the
  /// outer perimeter reserves room on top and bottom. Held weakly
  /// because the constraint is owned by the active layout, not by
  /// this model. Live-updating the gap rewrites `constant` through
  /// this reference.
  public weak var heightPin: NSLayoutConstraint?
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

  /// Keeps `foldedLabelView.layer.cornerRadius` in sync with the
  /// active `CornerRadiusPreset`. Without this observer the folded
  /// strip kept the OS default (no rounding) and visibly diverged
  /// from the rest of the pane chrome after a preset change. Held
  /// as a stored property so the listener stays registered for the
  /// column's lifetime; the observer unregisters itself in `deinit`.
  private let foldedLabelCornerObserver: SurfaceCornerObserver

  public var focusedPane: PaneModel? {
    panes[safe: focusedPaneIndex]
  }

  public init(pane: PaneModel, id: ULID = ULID()) {
    self.id = id
    self.panes = [pane]
    self.foldedLabelCornerObserver = SurfaceCornerObserver(applyingTo: foldedLabelView)
  }
}
