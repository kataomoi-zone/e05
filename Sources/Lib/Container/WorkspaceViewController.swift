import AppKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "Workspace")

/// One workspace's horizontal column strip. Owns its own scrollView +
/// stackView so that switching workspaces reduces to swapping the visible
/// child view — enabling `NSViewController.transition(from:to:options:)`
/// for a native slide animation without the layer-backed NSView pitfalls
/// that doomed the earlier `layer.transform` / `animator().frame` attempts.
///
/// Constructed once per `WorkspaceModel` and retained by the container as
/// long as the workspace exists. Column container views live inside this
/// VC's stackView across workspace switches — no detach/re-attach needed.
@MainActor
public final class WorkspaceViewController: NSViewController {
  /// Outer margin painted around the column strip on every side.
  /// Matches `PaneResizeHandle.handleSize` so the gap between panes
  /// and the gap around them feel like a single rhythm.
  ///
  /// Surfaced at the type level so `addColumn` can subtract twice
  /// this value from the column-height constraint: each column is
  /// pinned to `stackView.heightAnchor`, and an exact equal-height
  /// pin would crush the top/bottom inset that this margin reserves.
  /// Likely to become user-configurable later; until then the literal
  /// stays here as a single source paired with the handle size.
  static let outerMargin: CGFloat = PaneResizeHandle.handleSize

  public let workspace: WorkspaceModel
  let scrollView = OverlayScrollView()
  let stackView = NSStackView()

  /// Top constraint pinning this VC's root view to the container's top.
  /// The container animates this constraint's `constant` to slide the
  /// workspace in and out of view. Stored here so the container doesn't
  /// need a side-dictionary to find it at animation time.
  weak var topConstraint: NSLayoutConstraint?

  public init(workspace: WorkspaceModel) {
    self.workspace = workspace
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  public override func loadView() {
    logger.debug("WorkspaceVC.loadView wsId=\(String(describing: self.workspace.id), privacy: .public)")
    // Constraint-driven layout — the container installs leading/trailing/
    // height/top constraints and animates `topConstraint.constant` to
    // slide this view vertically. Autoresizing mask is turned off to
    // avoid fighting the constraint system.
    let root = NSView()
    root.translatesAutoresizingMaskIntoConstraints = false
    // Layer-backed so the animated constraint change produces a smooth
    // layer-compositor animation rather than a series of redraws.
    root.wantsLayer = true
    view = root

    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = false
    scrollView.drawsBackground = true
    scrollView.backgroundColor = NSColor(white: 0.5, alpha: 1.0)  // neutral gray
    scrollView.horizontalScrollElasticity = .allowed
    scrollView.verticalScrollElasticity = .none
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true

    stackView.orientation = .horizontal
    stackView.spacing = 0  // handles serve as spacing between panes
    stackView.detachesHiddenViews = false
    // Outer margin around the column strip so panes don't touch the
    // window edges (and the sidebar's right edge while pinned). See
    // `outerMargin` for the rationale and the column-height pin
    // adjustment that this inset depends on.
    stackView.edgeInsets = NSEdgeInsets(
      top: Self.outerMargin,
      left: Self.outerMargin,
      bottom: Self.outerMargin,
      right: Self.outerMargin
    )

    scrollView.documentView = stackView
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    stackView.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(scrollView)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: root.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

      stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
      stackView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
    ])
  }

}
