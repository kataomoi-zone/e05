import AppKit

/// Stage 1 sidebar view controller: always-on (equivalent to
/// `SidebarState.pinnedOpen`), fixed 260pt wide. Hosts a
/// `SidebarOverlayView` for Liquid Glass background + header + mode
/// area + places section. The hover / hidden / pinned state machine is
/// introduced in stage 4.
///
/// Stage 2 added the worklane tree and `reloadWorklane()`. Stage 3-A
/// adds mode switching (`currentMode`, `setMode`) and subscribes to
/// `DownloadsManager` mutations so the Downloads row badge tracks the
/// active count live.
@MainActor
final class SidebarViewController: NSViewController {
    /// Back-reference to the pane container. Set by `installSidebar()`
    /// right after the VC is created. `weak` because the container owns
    /// the VC (via `addChild`) and retaining it back would cycle.
    weak var container: PaneContainerViewController?

    private let overlay = SidebarOverlayView()
    private(set) var currentMode: SidebarMode = .tabs
    private var downloadsListenerToken: DownloadsListenerToken?

    override func loadView() {
        view = overlay
        overlay.places.onSelect = { [weak self] mode in self?.setMode(mode) }
        applyMode(currentMode)
    }

    /// Wire up container-dependent state. Called exactly once by
    /// `installSidebar()` after `container` has been set. The Downloads
    /// listener registration is guarded against double-install for
    /// defensive hygiene, but the bookmarks view is unconditionally
    /// replaced — earlier bookmarks views' listeners would leak if this
    /// ever gets called more than once.
    func attachContainer() {
        guard let container else { return }
        if let previous = downloadsListenerToken {
            container.downloadsManager.removeListener(previous)
        }
        downloadsListenerToken = container.downloadsManager.addListener { [weak self] in
            self?.refreshDownloadsBadge()
        }
        refreshDownloadsBadge()

        let bookmarksView = BookmarksSidebarView(bookmarks: container.bookmarks)
        bookmarksView.onOpen = { [weak container] urlString in
            guard let container, let url = URL(string: urlString) else { return }
            // UX policy: always open in a new browser column in the
            // current workspace.
            container.addColumn(address: PaneAddress(url))
        }
        bookmarksView.onOpenInNewWorkspace = { [weak container] urlString in
            guard let container, let url = URL(string: urlString),
                  container.canCreateWorkspace else { return }
            // UX policy: always open in a newly created workspace.
            // `createWorkspace()` auto-adds a terminal column; the
            // bookmark's browser column lands alongside it. Replacing
            // the auto-terminal is deferred until we see the ergonomics
            // in practice. Guarded on `canCreateWorkspace` so that at
            // the workspace cap we no-op instead of falling through to
            // `addColumn` which would silently land the bookmark in
            // the current workspace.
            container.createWorkspace()
            container.addColumn(address: PaneAddress(url))
        }
        overlay.setBookmarksView(bookmarksView)

        let historyView = HistorySidebarView(history: container.browsingHistory)
        historyView.onOpen = { [weak container] urlString in
            guard let container, let url = URL(string: urlString) else { return }
            // UX policy: open history entries in a new browser column
            // of the current workspace, matching bookmarks. A future
            // variant could instead navigate the focused column to
            // preserve the browser-history-as-session-recovery metaphor,
            // but that would conflict with users who use history as a
            // scratchpad for side-by-side comparison.
            container.addColumn(address: PaneAddress(url))
        }
        historyView.onOpenInNewWorkspace = { [weak container] urlString in
            guard let container, let url = URL(string: urlString),
                  container.canCreateWorkspace else { return }
            // UX policy: open in a newly created workspace. Same guard
            // story as bookmarks — at the workspace cap we no-op to
            // avoid accidentally polluting the current workspace.
            container.createWorkspace()
            container.addColumn(address: PaneAddress(url))
        }
        overlay.setHistoryView(historyView)

        // Re-apply the current mode so the newly installed mode views'
        // visibility matches the state machine.
        applyMode(currentMode)
    }

    // NOTE: No deinit cleanup for the Downloads listener. The closure
    // captures `self` weakly, so post-dealloc invocations are no-ops.
    // Removing the registration from a nonisolated deinit would need
    // a MainActor hop through a weak container reference that's
    // already nil in practice (the container owns the sidebar VC and
    // tears down first).

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

    /// Switch the sidebar's mode area to show the given mode's content.
    /// No-op if the mode is already active.
    func setMode(_ mode: SidebarMode) {
        guard mode != currentMode else { return }
        currentMode = mode
        applyMode(mode)
    }

    private func applyMode(_ mode: SidebarMode) {
        overlay.places.setCurrentMode(mode)
        overlay.worklane.isHidden = mode != .tabs
        overlay.bookmarksView?.isHidden = mode != .bookmarks
        overlay.historyView?.isHidden = mode != .history
        // Placeholder covers the modes that don't have a real content
        // view yet (downloads). Tabs, bookmarks, and history always
        // have a real view by the time a user can select them.
        overlay.placeholder.isHidden = mode == .tabs || mode == .bookmarks || mode == .history
        // Always assign — clearing on modes with a real view — so the
        // hidden placeholder never carries a stale string from the
        // previously active mode.
        overlay.placeholder.message = mode.placeholderMessage
    }

    private func refreshDownloadsBadge() {
        guard let container else { return }
        overlay.places.setDownloadsBadge(count: container.downloadsManager.activeCount)
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
