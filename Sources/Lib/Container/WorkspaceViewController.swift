import AppKit

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
    public let workspace: WorkspaceModel
    let scrollView = OverlayScrollView()
    let stackView = NSStackView()

    /// Top constraint pinning this VC's root view to the container's top.
    /// The container animates this constraint's `constant` to slide the
    /// workspace in and out of view. Stored here so the container doesn't
    /// need a side-dictionary to find it at animation time.
    weak var topConstraint: NSLayoutConstraint?

    /// Leading constraint offsetting this VC's root view from the
    /// container's leading edge. Animated alongside the sidebar state
    /// machine: constant = 0 when the sidebar is hidden or hover-peek
    /// (overlay behaviour), `sidebarWidth` when pinned open (push
    /// behaviour).
    weak var leadingConstraint: NSLayoutConstraint?

    public init(workspace: WorkspaceModel) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    public override func loadView() {
        NSLog("[e05/ws] WorkspaceVC.loadView wsId=%@", String(describing: workspace.id))
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
        scrollView.backgroundColor = NSColor(white: 0.5, alpha: 1.0) // neutral gray
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true

        stackView.orientation = .horizontal
        stackView.spacing = 0 // handles serve as spacing between panes
        stackView.detachesHiddenViews = false

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
