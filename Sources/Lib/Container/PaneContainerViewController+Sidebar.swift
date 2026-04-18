import AppKit

extension PaneContainerViewController {
    /// Fixed sidebar width in points. Stage 1 pins the sidebar open, so
    /// every workspace view gets this as a leading inset via
    /// `installWorkspaceView`. Kept as a class-level constant so future
    /// stages (hover reveal, drag-resize) animate the same anchor.
    public static let sidebarWidth: CGFloat = 260

    /// Instantiate the sidebar child VC and pin its view to the container's
    /// left edge, full height. Called from `viewDidLoad` after the initial
    /// workspace VC and any session-restored workspaces are installed, so
    /// the sidebar sits on top of them in `subviews` z-order. Performs an
    /// initial `reloadWorklane()` so the tree reflects the restored state
    /// before the user sees anything.
    func installSidebar() {
        let vc = SidebarViewController()
        vc.container = self
        addChild(vc)
        let sv = vc.view
        sv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sv)
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: view.topAnchor),
            sv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sv.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
        ])
        sidebarVC = vc
        // `attachContainer()` wires the DownloadsManager listener for
        // the places-section badge. Called after `sidebarVC` is set so
        // the sidebar reads through the same weak back-reference as
        // subsequent reloads.
        sidebarVC.attachContainer()
        sidebarVC.reloadWorklane()
    }

    /// Tell the sidebar worklane to rebuild from the current state. Called
    /// from `setFocus` (which every pane/column/workspace mutation path
    /// eventually funnels into). Skipped while a workspace switch animation
    /// is in flight to avoid mid-slide flicker — the animation's completion
    /// calls `restoreFocusInCurrentWorkspace` → `setFocus`, which re-fires
    /// this notify once the animation settles.
    ///
    /// Nil-guarded on `sidebarVC` because the first `setFocus` (from the
    /// initial `addColumn` in `viewDidLoad`) runs before `installSidebar()`.
    func notifySidebarWorklaneDidChange() {
        guard let sidebarVC, !isAnimatingWorkspaceSwitch else { return }
        sidebarVC.reloadWorklane()
    }
}
