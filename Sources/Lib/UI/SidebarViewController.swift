import AppKit

/// Stage 1 sidebar view controller: always-on (equivalent to
/// `SidebarState.pinnedOpen`), fixed 260pt wide. Hosts a
/// `SidebarOverlayView` for Liquid Glass background + header + worklane
/// sections. The hover / hidden / pinned state machine is introduced in
/// stage 4.
///
/// Stage 2 additions: `container` back-reference and `reloadWorklane()`
/// entry point. The container pushes updates via
/// `notifySidebarWorklaneDidChange()` on every focus / pane / workspace
/// change.
@MainActor
final class SidebarViewController: NSViewController {
    /// Back-reference to the pane container. Set by `installSidebar()`
    /// right after the VC is created. `weak` because the container owns
    /// the VC (via `addChild`) and retaining it back would cycle.
    weak var container: PaneContainerViewController?

    private let overlay = SidebarOverlayView()

    override func loadView() {
        view = overlay
    }

    /// Rebuild the worklane tree from the container's current state.
    /// Safe to call repeatedly; the implementation wipes and rebuilds
    /// `arrangedSubviews` each time (stage 5 may switch to diff-based).
    /// No-op if the container reference has been lost.
    func reloadWorklane() {
        guard let container else { return }
        let focusedPaneId: ULID? = {
            guard container.workspaces.indices.contains(container.focusedWorkspaceIndex)
            else { return nil }
            let ws = container.workspaces[container.focusedWorkspaceIndex]
            return ws.columns[safe: ws.focusedColumnIndex]?.focusedPane?.id
        }()
        overlay.worklane.reload(.init(
            workspaces: container.workspaces,
            focusedWorkspaceIndex: container.focusedWorkspaceIndex,
            focusedPaneId: focusedPaneId,
            accentColor: { PaneContainerViewController.accentColor(forWorkspaceAt: $0) },
            paneTitle: Self.displayTitle(for:),
            onWorkspaceClick: { [weak container] index in
                container?.switchWorkspace(to: index)
            },
            onPaneClick: { [weak container] id in
                container?.focusPane(id: id)
            }
        ))
    }

    /// Fallback-aware display title. Terminal and browser panes frequently
    /// start with an empty `title` (populated via ghostty / WebKit callbacks
    /// later), so the sidebar row falls back to the address kind or host so
    /// rows are never blank.
    private static func displayTitle(for pane: PaneModel) -> String {
        if !pane.title.isEmpty { return pane.title }
        switch pane.address.kind {
        case .terminal: return "Terminal"
        case .browser:
            return pane.address.url.host() ?? pane.address.url.absoluteString
        case .history: return "History"
        case .bookmarks: return "Bookmarks"
        case .downloads: return "Downloads"
        case .settings: return "Settings"
        case .unknown: return "(unknown)"
        }
    }
}
