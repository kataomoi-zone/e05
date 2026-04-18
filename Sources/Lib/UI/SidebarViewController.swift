import AppKit

/// Stage 1 sidebar view controller: always-on (equivalent to
/// `SidebarState.pinnedOpen`), fixed 260pt wide. Owns a single
/// `SidebarOverlayView` that renders the Liquid Glass background and
/// header. The hover / hidden / pinned state machine is introduced in
/// stage 4; at that point this class will track `SidebarState` and
/// animate its leading offset accordingly.
@MainActor
final class SidebarViewController: NSViewController {
    private let overlay = SidebarOverlayView()

    override func loadView() {
        view = overlay
    }
}
