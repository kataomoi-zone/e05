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
    /// the sidebar sits on top of them in `subviews` z-order.
    func installSidebar() {
        let vc = SidebarViewController()
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
    }
}
