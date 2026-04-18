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

    /// Wire up container-dependent state. Called by `installSidebar()`
    /// once `container` has been set. Safe to call repeatedly; the
    /// listener slot is replaced on each call.
    func attachContainer() {
        guard let container else { return }
        if let previous = downloadsListenerToken {
            container.downloadsManager.removeListener(previous)
        }
        downloadsListenerToken = container.downloadsManager.addListener { [weak self] in
            self?.refreshDownloadsBadge()
        }
        refreshDownloadsBadge()
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
        overlay.placeholder.isHidden = mode == .tabs
        // Always assign — clearing on `.tabs` too — so the hidden
        // placeholder never carries a stale string from the previously
        // active mode.
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
