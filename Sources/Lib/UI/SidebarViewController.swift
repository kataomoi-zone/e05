import AppKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "SidebarHover")

/// Sidebar view controller hosting the Liquid Glass overlay, the
/// worklane / mode views, and the places section. Owns the three-state
/// machine (`SidebarState`) driving reveal/hide: `.hidden` is the
/// default off state, `.hoverPeek` is a transient overlay triggered by
/// the edge hit zone, and `.pinnedOpen` is the user-pinned push layout.
///
/// The state machine lives here; the container (`PaneContainerViewController`)
/// is responsible for applying visual effects (sidebar leading,
/// workspace leading, traffic light visibility) via
/// `applySidebarLayout(state:animated:completion:)`, keeping the
/// Auto Layout machinery outside this class.
@MainActor
final class SidebarViewController: NSViewController {
  /// Back-reference to the pane container. Set by `installSidebar()`
  /// right after the VC is created. `weak` because the container owns
  /// the VC (via `addChild`) and retaining it back would cycle.
  weak var container: PaneContainerViewController?

  private let overlay = SidebarOverlayView()
  private(set) var currentMode: SidebarMode = .tabs
  private var downloadsListenerToken: DownloadsListenerToken?

  /// Outline-view items the user has collapsed in the worklane —
  /// both `WorkspaceModel.id` and `ColumnModel.id` ULIDs share this
  /// set. NSOutlineView treats expansion uniformly, so a single
  /// merged set keeps persistence in lockstep with the AppKit
  /// state. Persisted across launches via `SessionState.collapsedIds`.
  /// Survives sidebar mode switches and sidebar state transitions
  /// because it lives on the VC, not the worklane view.
  private var collapsedIds: Set<ULID> = []

  /// Seed the initial collapsed-state from session restore. Must be
  /// called *before* the first `reloadWorklane`, otherwise the
  /// initial render shows every collapsible item expanded.
  func seedCollapsed(_ ids: Set<ULID>) {
    collapsedIds = ids
  }

  /// Snapshot for `captureSession()` to persist. Returns ULIDs of
  /// every workspace or column the user has collapsed.
  func collapsedItemIds() -> Set<ULID> {
    collapsedIds
  }

  /// True when the item (workspace or column) with `id` is currently
  /// collapsed in the worklane.
  func isCollapsed(_ id: ULID) -> Bool {
    collapsedIds.contains(id)
  }

  // MARK: - State machine

  /// Current sidebar state. Mutated only via `transition(to:animated:)`
  /// so that every state change goes through a single code path that
  /// drives the container layout and traffic-light sync.
  private(set) var currentState: SidebarState = .hidden

  /// Monotonic counter bumped on every scheduled timer. A deferred
  /// hover-in/out closure compares its captured counter against the
  /// live value and no-ops when it has been superseded. Three common
  /// races this defuses: (a) rapid re-entries/exits at the edge, (b)
  /// pin toggles that invalidate a pending hide, (c) workspace switch
  /// animations that demand sidebar changes wait.
  private var stateGeneration: Int = 0

  /// Cursor is currently inside the edge hit zone. ORed with
  /// `sidebarHovered` to form the composite `mouseInside` predicate.
  private var edgeHovered: Bool = false
  /// Cursor is currently inside the sidebar overlay's visible rect.
  /// Spurious `mouseExited` from nested subview tracking areas is
  /// filtered by `SidebarOverlayView.cursorIsStillInsideBounds` before this
  /// flag flips.
  private var sidebarHovered: Bool = false

  /// Flag mirroring `PaneContainerViewController.isAnimatingSidebar`.
  /// Kept in lockstep so that workspace switch animations know to
  /// defer, and hover timers see a consistent value under reentry.
  private(set) var isAnimating: Bool = false

  /// Local event monitor that watches for primary-button release.
  /// Installed on demand when `scheduleHoverOut` fires while a drag
  /// is in progress, so the cursor leaving the sidebar mid-drag
  /// doesn't leave the state machine stuck in `.hoverPeek` once the
  /// user finally releases the mouse. Monitor is removed as soon as
  /// it fires (one-shot) or in `deinit` if still active.
  nonisolated(unsafe) private var dragEndMonitor: Any?

  /// Block-based observer for `FaviconCache.didChangeNotification`.
  /// Kept in lockstep with the `scrollObserver` pattern used by the
  /// bookmarks/history sidebar views so all three favicon-aware
  /// surfaces share one subscription style and one cleanup path.
  nonisolated(unsafe) private var faviconObserver: NSObjectProtocol?

  /// Hover-in delay (seconds). Short enough to feel instant on
  /// intentional edge hover yet long enough to shrug off an accidental
  /// cursor fly-by crossing the edge strip.
  static let hoverInDelay: TimeInterval = 0.05
  /// Hover-out delay (seconds). Gives the user a grace window to
  /// re-enter the sidebar after straying over the boundary (e.g. when
  /// drag-scrolling a bookmark list with momentum).
  static let hoverOutDelay: TimeInterval = 0.3

  // MARK: - Lifecycle

  override func loadView() {
    view = overlay
    overlay.places.onSelect = { [weak self] mode in self?.setMode(mode) }
    overlay.onHoverEnter = { [weak self] in self?.setSidebarHovered(true) }
    overlay.onHoverExit = { [weak self] in self?.setSidebarHovered(false) }
    overlay.header.onTogglePin = { [weak self] in self?.togglePin() }
    overlay.header.onCreateWorkspace = { [weak self] in
      self?.container?.createWorkspace()
    }
    overlay.header.onCreatePrivateWorkspace = { [weak self] in
      self?.container?.createWorkspace(isPrivate: true)
    }
    overlay.header.onCreateTerminalPane = { [weak self] in
      guard let container = self?.container else { return }
      container.addColumn()
      container.showToast("New Terminal Pane")
    }
    overlay.header.onCreateBrowserPane = { [weak self] in
      guard let container = self?.container else { return }
      container.addColumn(address: .newPaneHome)
      container.showToast("New Browser Pane")
    }
    overlay.header.onCreateFinderPane = { [weak self] in
      guard let container = self?.container else { return }
      container.addColumn(address: PaneAddress.finder(path: ""))
      container.showToast("New Finder Pane")
    }
    applyMode(currentMode)
  }

  /// Wire up container-dependent state. Called exactly once by
  /// `installSidebar()` after `container` has been set. The Downloads
  /// listener registration is guarded against double-install for
  /// defensive hygiene, but the mode views are unconditionally
  /// replaced — earlier views' listeners would leak if this ever gets
  /// called more than once.
  func attachContainer() {
    guard let container else { return }
    if let previous = downloadsListenerToken {
      container.downloadsManager.removeListener(previous)
    }
    downloadsListenerToken = container.downloadsManager.addListener { [weak self] in
      self?.refreshDownloadsBadge()
    }

    let bookmarksView = BookmarksSidebarView(bookmarks: container.bookmarks)
    bookmarksView.onOpen = { [weak container] urlString in
      guard let container, let url = URL(string: urlString) else { return }
      // UX policy: always open in a new browser column in the
      // current workspace.
      container.addColumn(address: PaneAddress(url))
    }
    bookmarksView.onOpenInNewWorkspace = { [weak container] urlString in
      guard let container, let url = URL(string: urlString) else { return }
      // UX policy: always open in a newly created workspace.
      // `createWorkspace()` auto-adds a terminal column; the
      // bookmark's browser column lands alongside it. Replacing
      // the auto-terminal is deferred until we see the ergonomics
      // in practice.
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
      guard let container, let url = URL(string: urlString) else { return }
      // UX policy: open in a newly created workspace, mirroring bookmarks.
      container.createWorkspace()
      container.addColumn(address: PaneAddress(url))
    }
    overlay.setHistoryView(historyView)

    let downloadsView = DownloadsSidebarView(manager: container.downloadsManager)
    downloadsView.onCancel = { [weak container] id in
      container?.downloadsManager.cancel(id: id)
    }
    downloadsView.onPause = { [weak container] id in
      container?.downloadsManager.pause(id: id)
    }
    downloadsView.onResume = { [weak container] id in
      container?.downloadsManager.resume(id: id)
    }
    downloadsView.onRemove = { [weak container] id in
      container?.downloadsManager.remove(id: id)
    }
    downloadsView.onShowInFinder = { path in
      // Empty `destination` means the download never reached the
      // `decideDestinationUsing` step (e.g. failed mid-negotiation)
      // — bailing avoids handing Finder an invalid file URL.
      guard !path.isEmpty else { return }
      NSWorkspace.shared.activateFileViewerSelecting(
        [URL(fileURLWithPath: path)]
      )
    }
    downloadsView.onCopyURL = { [weak container] id in
      // Re-read through the manager rather than caching the URL
      // in the cell: if the row has been rewritten (retry with a
      // redirected URL, future edit API) between menu render and
      // click, we still copy the live value.
      guard let container,
        let entry = container.downloadsManager.all().first(where: { $0.id == id })
      else { return }
      let pb = NSPasteboard.general
      pb.clearContents()
      pb.setString(entry.url, forType: .string)
    }
    overlay.setDownloadsView(downloadsView)

    // Extensions mode reads from the process-lifetime
    // `ExtensionController` singleton directly, so it doesn't need a
    // container reference for state. The view subscribes to
    // `ExtensionController.didChangeNotification` internally, which
    // means async loads completing after the sidebar appears still
    // populate the list. The `Open Options Page` row action does
    // need the container — same UX policy as Bookmarks `onOpen`,
    // landing the page as a fresh browser column in the current
    // workspace.
    let extensionsView = ExtensionsSidebarView()
    extensionsView.onOpenURL = { [weak container] url in
      container?.addColumn(address: PaneAddress(url))
    }
    overlay.setExtensionsView(extensionsView)

    // Re-apply the current mode so the newly installed mode views'
    // visibility matches the state machine.
    applyMode(currentMode)

    // Refresh the downloads badge after the sidebar view has been
    // installed and the mode has been applied. The first refresh
    // must happen once `PlacesSectionView` is in its final layout
    // or `DownloadsBadgeView.widthAnchor >= height` clamps the pill
    // to a 16pt square, truncating the digit label.
    refreshDownloadsBadge()

    // Rebuild the worklane when any host's favicon becomes available
    // so the generic `globe` placeholder gets upgraded in place. Uses
    // the block-based form + a `nonisolated(unsafe)` token so the
    // subscription style matches `BookmarksSidebarView` /
    // `HistorySidebarView` (the other favicon-aware surfaces),
    // giving us one shared cleanup path in `deinit`.
    faviconObserver = NotificationCenter.default.addObserver(
      forName: FaviconCache.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reloadWorklane() }
    }
  }

  // NOTE: No deinit cleanup for the Downloads listener. The closure
  // captures `self` weakly, so post-dealloc invocations are no-ops.
  // Removing the registration from a nonisolated deinit would need
  // a MainActor hop through a weak container reference that's
  // already nil in practice (the container owns the sidebar VC and
  // tears down first).

  /// Rebuild the worklane tree from the container's current state.
  /// Safe to call repeatedly; the implementation wipes and rebuilds
  /// `arrangedSubviews` each time. No-op if the container reference
  /// has been lost.
  func reloadWorklane() {
    guard let container else { return }
    let focusedPaneId: ULID? = {
      guard container.workspaces.indices.contains(container.focusedWorkspaceIndex)
      else { return nil }
      let ws = container.workspaces[container.focusedWorkspaceIndex]
      return ws.columns[safe: ws.focusedColumnIndex]?.focusedPane?.id
    }()
    // Drop collapsed-state entries for items that no longer exist
    // (workspaces / columns closed since last reload) so the set
    // doesn't grow unbounded over the session's lifetime. Walks both
    // workspaces and their columns since either kind of id can sit
    // in the set.
    var liveIds = Set(container.workspaces.map(\.id))
    for ws in container.workspaces {
      for column in ws.columns {
        liveIds.insert(column.id)
      }
    }
    collapsedIds.formIntersection(liveIds)

    overlay.worklane.reload(
      .init(
        workspaces: container.workspaces,
        focusedWorkspaceIndex: container.focusedWorkspaceIndex,
        focusedPaneId: focusedPaneId,
        accentColor: { PaneContainerViewController.accentColor(forWorkspaceAt: $0) },
        paneTitle: Self.displayTitle(for:),
        paneIcon: Self.displayIcon(for:),
        paneAudioState: { pane in
          guard let bv = pane.browserView else { return (false, false, false) }
          return (bv.isMuted, bv.isPlayingAudio, bv.hasActiveMedia)
        },
        paneIsSuspended: { pane in
          pane.browserView?.isSuspended ?? false
        },
        isCollapsed: { [weak self] id in
          self?.collapsedIds.contains(id) ?? false
        },
        onWorkspaceClick: { [weak container] index in
          container?.switchWorkspace(to: index)
        },
        onPaneClick: { [weak container] id in
          container?.focusPane(id: id)
        },
        onWorkspaceClose: { [weak container] index in
          container?.closeWorkspace(at: index)
        },
        onPaneClose: { [weak container] id in
          container?.closePane(id: id)
        },
        onColumnClose: { [weak container] id in
          container?.closeColumn(id: id)
        },
        onPaneAudioToggle: { [weak container] id in
          container?.toggleMuteForPane(id: id)
        },
        onToggleCollapse: { [weak self] id in
          self?.toggleCollapsed(id)
        },
        onReorderWorkspaces: { [weak container] orderedIds in
          container?.reorderWorkspaces(orderedIds: orderedIds)
        },
        onMovePaneToWorkspace: { [weak container] paneId, wsId, position in
          container?.movePane(paneId, toWorkspaceId: wsId, position: position)
        },
        onMovePaneToColumn: { [weak container] paneId, columnId, position in
          container?.movePane(paneId, toColumnId: columnId, position: position)
        },
        onCrossPrivateBoundaryAttempt: { [weak container] in
          container?.showCrossPrivateBoundaryToast()
        },
        onAddPaneToWorkspace: { [weak container] wsId in
          container?.addColumn(.newPaneHome, toWorkspaceId: wsId)
          container?.showToast("New Browser Pane")
        }
      ))
  }

  /// Per-pane audio state update without rebuilding the whole
  /// worklane. Hosts call this from `onAudioStateChanged` so the
  /// 1 Hz audio probe (which can flip state for any pane on any
  /// tick) doesn't trigger a full row rebuild — only the targeted
  /// row's speaker glyph reflows.
  func updatePaneAudioState(
    paneId: ULID, isMuted: Bool, isPlayingAudio: Bool, hasActiveMedia: Bool
  ) {
    overlay.worklane.updatePaneAudioState(
      paneId: paneId, isMuted: isMuted, isPlayingAudio: isPlayingAudio,
      hasActiveMedia: hasActiveMedia)
  }

  /// Per-pane suspended-state flip without rebuilding the whole
  /// worklane. Hosts call this from `onSuspendedStateChanged` so the
  /// suspend sweep can flip dozens of rows per tick at most without
  /// driving a full worklane reload.
  func updatePaneSuspendedState(paneId: ULID, isSuspended: Bool) {
    overlay.worklane.updatePaneSuspendedState(
      paneId: paneId, isSuspended: isSuspended)
  }

  private func toggleCollapsed(_ id: ULID) {
    if collapsedIds.contains(id) {
      collapsedIds.remove(id)
    } else {
      collapsedIds.insert(id)
    }
    // Defer the reload past the current notification delivery.
    // `toggleCollapsed` is invoked from inside AppKit's
    // `outlineViewItemDidCollapse/Expand` dispatch; running
    // `reloadWorklane` synchronously re-enters the outline view
    // while its internal expand bookkeeping is still mid-update,
    // and the follow-up `applyPersistedCollapseState` reads stale
    // `isItemExpanded` values that stall the subsequent
    // `expandItem` call in a reentrant hang. Both expand and
    // collapse notifications funnel through here, so a single
    // defer covers both directions.
    DispatchQueue.main.async { [weak self] in
      self?.reloadWorklane()
    }
  }

  /// Switch the sidebar's mode area to show the given mode's content.
  /// No-op if the mode is already active.
  func setMode(_ mode: SidebarMode) {
    guard mode != currentMode else { return }
    currentMode = mode
    applyMode(mode)
  }

  /// Pin the sidebar open (if it isn't already) and switch to `mode`.
  /// Palette actions like "Open Bookmarks" route here so the sidebar
  /// surfaces deliberately and persists until the user hits ⌘B to
  /// unpin. `.hoverPeek` is promoted to `.pinnedOpen` because the
  /// hover-out delay would yank the content out from under a user who
  /// just asked to see it.
  func openMode(_ mode: SidebarMode) {
    switch currentState {
    case .hidden, .hoverPeek:
      transition(to: .pinnedOpen, animated: true)
    case .pinnedOpen:
      break
    }
    setMode(mode)
  }

  private func applyMode(_ mode: SidebarMode) {
    overlay.places.setCurrentMode(mode)
    overlay.worklane.isHidden = mode != .tabs
    overlay.bookmarksView?.isHidden = mode != .bookmarks
    overlay.historyView?.isHidden = mode != .history
    overlay.downloadsView?.isHidden = mode != .downloads
    overlay.extensionsView?.isHidden = mode != .extensions
    // Placeholder is a fallback for modes whose real content view
    // hasn't been installed yet (e.g. attachContainer hasn't run).
    // Once every mode carries a real view, this collapses to an
    // unconditional `true`.
    let hasRealView =
      (mode == .tabs)
      || (mode == .bookmarks && overlay.bookmarksView != nil)
      || (mode == .history && overlay.historyView != nil)
      || (mode == .downloads && overlay.downloadsView != nil)
      || (mode == .extensions && overlay.extensionsView != nil)
    overlay.placeholder.isHidden = hasRealView
    // Always assign — clearing on modes with a real view — so the
    // hidden placeholder never carries a stale string from the
    // previously active mode.
    overlay.placeholder.message = mode.placeholderMessage
  }

  private func refreshDownloadsBadge() {
    guard let container else { return }
    overlay.places.setDownloadsBadge(count: container.downloadsManager.activeCount)
  }

  // MARK: - State machine entry points

  /// Seed the initial state when the sidebar is first installed.
  /// Applies layout and traffic lights without animation (cold start
  /// should not slide the sidebar into view) and leaves state timers
  /// clean. Called from `PaneContainerViewController.installSidebar`.
  func applyInitialState(pinned: Bool) {
    currentState = pinned ? .pinnedOpen : .hidden
    overlay.header.isPinned = (currentState == .pinnedOpen)
    container?.applySidebarLayout(state: currentState, animated: false, completion: nil)
  }

  /// Toggle between `.pinnedOpen` and the state before pinning. From
  /// `.hidden` / `.hoverPeek`, a pin takes the sidebar to
  /// `.pinnedOpen`; from `.pinnedOpen` a toggle sends it to `.hidden`
  /// (the "default" off state). Wired to the ⌘B action and the pin
  /// button.
  func togglePin() {
    switch currentState {
    case .hidden, .hoverPeek:
      transition(to: .pinnedOpen, animated: true)
    case .pinnedOpen:
      transition(to: .hidden, animated: true)
    }
  }

  /// Edge hit zone mouse-enter entry point. Registers the hover and
  /// schedules a `.hidden → .hoverPeek` transition after
  /// `hoverInDelay` if the cursor is still inside and the reveal is
  /// permitted by `hoverTriggerAllowed`. Same-value calls are
  /// dropped: `scheduleHoverIn/Out` unconditionally bumps
  /// `stateGeneration`, so letting layout-driven probe callers
  /// reassert the current value would invalidate the opposite
  /// direction's in-flight asyncAfter and produce missed transitions.
  func setEdgeHovered(_ value: Bool) {
    guard edgeHovered != value else { return }
    logger.debug(
      "setEdgeHovered \(self.edgeHovered, privacy: .public) -> \(value, privacy: .public); state=\(String(describing: self.currentState), privacy: .public) gen=\(self.stateGeneration, privacy: .public)"
    )
    edgeHovered = value
    hoverInsideDidChange()
  }

  /// Sidebar overlay mouse-enter entry point (mirrors
  /// `setEdgeHovered`). Keeps `.hoverPeek` alive while the user
  /// interacts with sidebar contents. Same-value calls are dropped
  /// for the same reason as `setEdgeHovered`.
  func setSidebarHovered(_ value: Bool) {
    guard sidebarHovered != value else { return }
    logger.debug(
      "setSidebarHovered \(self.sidebarHovered, privacy: .public) -> \(value, privacy: .public); state=\(String(describing: self.currentState), privacy: .public) gen=\(self.stateGeneration, privacy: .public)"
    )
    sidebarHovered = value
    hoverInsideDidChange()
  }

  private var mouseInside: Bool { edgeHovered || sidebarHovered }

  private func hoverInsideDidChange() {
    if mouseInside {
      scheduleHoverIn()
    } else {
      scheduleHoverOut()
    }
  }

  private func scheduleHoverIn() {
    // Bump the generation so any pending hide from a prior exit is
    // invalidated before the delay we're about to register.
    stateGeneration &+= 1
    logger.debug(
      "scheduleHoverIn: gen=\(self.stateGeneration, privacy: .public) state=\(String(describing: self.currentState), privacy: .public) allowed=\(self.hoverTriggerAllowed, privacy: .public) [\(self.hoverAllowedBreakdown, privacy: .public)] edge=\(self.edgeHovered, privacy: .public) sidebar=\(self.sidebarHovered, privacy: .public)"
    )
    guard currentState == .hidden, hoverTriggerAllowed else {
      logger.debug(
        "scheduleHoverIn: early-return (state=\(String(describing: self.currentState), privacy: .public) allowed=\(self.hoverTriggerAllowed, privacy: .public))"
      )
      return
    }
    let gen = stateGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverInDelay) { [weak self] in
      guard let self else { return }
      guard gen == self.stateGeneration else {
        logger.debug("scheduleHoverIn fire: gen mismatch (captured=\(gen) live=\(self.stateGeneration))")
        return
      }
      guard self.mouseInside, self.hoverTriggerAllowed else {
        logger.debug(
          "scheduleHoverIn fire: conditions failed (inside=\(self.mouseInside) allowed=\(self.hoverTriggerAllowed))")
        return
      }
      guard self.currentState == .hidden else {
        logger.debug("scheduleHoverIn fire: state moved (\(String(describing: self.currentState)))")
        return
      }
      logger.debug("scheduleHoverIn fire: transitioning to .hoverPeek")
      self.transition(to: .hoverPeek, animated: true)
    }
  }

  private func scheduleHoverOut() {
    stateGeneration &+= 1
    logger.debug(
      "scheduleHoverOut: gen=\(self.stateGeneration, privacy: .public) state=\(String(describing: self.currentState), privacy: .public) edge=\(self.edgeHovered, privacy: .public) sidebar=\(self.sidebarHovered, privacy: .public)"
    )
    guard currentState == .hoverPeek else {
      logger.debug("scheduleHoverOut: early-return (state=\(String(describing: self.currentState), privacy: .public))")
      return
    }
    let gen = stateGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverOutDelay) { [weak self] in
      guard let self else { return }
      guard gen == self.stateGeneration else {
        logger.debug(
          "scheduleHoverOut fire: gen mismatch (captured=\(gen, privacy: .public) live=\(self.stateGeneration, privacy: .public))"
        )
        return
      }
      guard !self.mouseInside else {
        logger.debug("scheduleHoverOut fire: re-entered (inside=true)")
        return
      }
      // If the user is mid-drag (e.g. resizing a pane near the
      // sidebar edge), collapsing the sidebar out from under them
      // feels abrupt. Defer the hide until the primary button
      // comes back up via a one-shot `leftMouseUp` monitor.
      // Right/middle buttons are pane-internal and don't affect
      // sidebar state, so we intentionally only guard on bit 0.
      if NSEvent.pressedMouseButtons & 1 != 0 {
        logger.debug("scheduleHoverOut fire: deferring (drag in progress)")
        self.installDragEndMonitor()
        return
      }
      guard self.currentState == .hoverPeek else {
        logger.debug("scheduleHoverOut fire: state moved (\(String(describing: self.currentState), privacy: .public))")
        return
      }
      logger.debug("scheduleHoverOut fire: transitioning to .hidden")
      self.transition(to: .hidden, animated: true)
    }
  }

  /// Install a one-shot local monitor for primary-button release.
  /// When it fires, re-evaluate the hover state so the sidebar can
  /// close as soon as the drag ends (provided the cursor is still
  /// outside the sidebar/edge zone). Idempotent: a second call while
  /// one is already in flight is a no-op.
  private func installDragEndMonitor() {
    guard dragEndMonitor == nil else { return }
    dragEndMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
      guard let self else { return event }
      self.removeDragEndMonitor()
      self.hoverInsideDidChange()
      return event
    }
  }

  private func removeDragEndMonitor() {
    if let m = dragEndMonitor {
      NSEvent.removeMonitor(m)
      dragEndMonitor = nil
    }
  }

  deinit {
    // `addLocalMonitorForEvents` tokens leak the backing closure if
    // not removed. Swift 6 deinit is nonisolated; `removeMonitor`
    // is thread-safe, and the `nonisolated(unsafe)` property lets
    // us touch it without a MainActor hop.
    if let m = dragEndMonitor {
      NSEvent.removeMonitor(m)
    }
    if let token = faviconObserver {
      NotificationCenter.default.removeObserver(token)
    }
  }

  /// Whether hover triggers should currently fire. Disabled while the
  /// command palette is visible, the focused pane's URL bar holds
  /// first responder, a modal window is showing, or a workspace
  /// switch / sidebar animation is in flight.
  private var hoverTriggerAllowed: Bool {
    guard let container else { return false }
    if container.commandPalette.isVisible { return false }
    if container.isAnimatingWorkspaceSwitch { return false }
    if isAnimating { return false }
    if NSApp.modalWindow != nil { return false }
    // Text-field first responder — URL bar, command palette input,
    // any suggestion field. NSTextField delegates to an
    // NSTextView-based field editor; both inherit from NSText.
    if let responder = view.window?.firstResponder, responder is NSText {
      return false
    }
    return true
  }

  /// Debug-only breakdown of every guard inside `hoverTriggerAllowed`
  /// so the log reader can see *which* condition is blocking the
  /// hover trigger instead of just seeing `allowed=false`.
  private var hoverAllowedBreakdown: String {
    let hasContainer = container != nil
    let paletteVisible = container?.commandPalette.isVisible ?? false
    let animatingWS = container?.isAnimatingWorkspaceSwitch ?? false
    let animatingSB = isAnimating
    let modalActive = NSApp.modalWindow != nil
    let responder = view.window?.firstResponder
    let textResponder = responder is NSText
    let responderType = responder.map { String(describing: type(of: $0)) } ?? "nil"
    return
      "container=\(hasContainer) palette=\(paletteVisible) animWS=\(animatingWS) animSB=\(animatingSB) modal=\(modalActive) textFR=\(textResponder) responder=\(responderType)"
  }

  private func transition(to newState: SidebarState, animated: Bool) {
    guard newState != currentState else { return }
    guard let container else {
      currentState = newState
      overlay.header.isPinned = (newState == .pinnedOpen)
      return
    }
    // Bump invalidates deferred hover-in/out closures scheduled
    // before this transition — necessary when `togglePin` interrupts
    // an in-flight peek schedule. The completion below no longer
    // captures `stateGeneration`; state-based guarding handles
    // stacked transitions without coupling to the shared counter.
    stateGeneration &+= 1
    currentState = newState
    overlay.header.isPinned = (newState == .pinnedOpen)
    isAnimating = animated
    container.applySidebarLayout(state: newState, animated: animated) { [weak self] in
      // Guard on `currentState == newState` rather than the shared
      // `stateGeneration` counter: hover event paths
      // (setEdgeHovered / setSidebarHovered / scheduleHoverIn/Out)
      // also bump `stateGeneration`, so a routine hover event
      // occurring during the 200ms animation would leave this
      // completion with a stale captured generation and `isAnimating`
      // would never flip back to false — permanently blocking
      // `hoverTriggerAllowed`. State-based guarding still correctly
      // cancels superseded transitions: if pin toggles stack, the
      // first completion sees a state that no longer matches and
      // the second completion lands on the final state.
      guard let self else { return }
      guard self.currentState == newState else {
        logger.debug(
          "transition completion: superseded (target=\(String(describing: newState), privacy: .public) current=\(String(describing: self.currentState), privacy: .public))"
        )
        return
      }
      self.isAnimating = false
      logger.debug(
        "transition completion: isAnimating=false (state=\(String(describing: self.currentState), privacy: .public))")
    }
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
    case .finder:
      let last = pane.address.url.lastPathComponent
      return last.isEmpty || last == "/" ? "Finder" : last
    case .settings: return "Settings"
    case .unknown: return "(unknown)"
    }
  }

  /// Leading icon for a worklane row. Terminal panes get a stable
  /// `terminal` SF Symbol; browser panes try the `FaviconCache` for
  /// the host first and fall back to a generic `globe` symbol while
  /// the fetch is in flight (or on failure).
  private static func displayIcon(for pane: PaneModel) -> NSImage? {
    switch pane.address.kind {
    case .terminal:
      return NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
    case .browser:
      if let host = pane.address.url.host(percentEncoded: false),
        let img = FaviconCache.shared.image(for: host)
      {
        return img
      }
      return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    case .finder:
      return NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    case .settings:
      return NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
    case .unknown:
      return NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
    }
  }
}
