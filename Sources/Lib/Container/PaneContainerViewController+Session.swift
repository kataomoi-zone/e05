import AppKit
import GhosttyKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "Session")

extension PaneContainerViewController {
  // MARK: - Session Save/Restore

  /// Capture the current layout as a serializable session state.
  public func captureSession() -> SessionState {
    // Snapshot the live scroll offset onto the current workspace so
    // it's included in the save. Other workspaces already have their
    // scrollX recorded when they were last switched away from.
    // `scrollX` is logical (state-independent), so subtract the
    // active hover-peek compensation — otherwise a save while peek
    // is open would persist a 260pt shift that the next launch
    // (which never restores `.hoverPeek`) couldn't undo.
    currentWorkspace.scrollX = scrollView.contentView.bounds.origin.x - hoverPeekScrollCompensation

    // Drop private workspaces from the snapshot: they're explicitly
    // ephemeral and persisting their URLs would defeat the mode.
    // `focusedWorkspaceIndex` rebases onto the surviving workspaces
    // so the restore still lands on the right one — if the focused
    // workspace was itself private, focus migrates to the nearest
    // non-private predecessor (or `0` when none exists).
    let persistedWorkspaces = workspaces.enumerated().filter { !$0.element.isPrivate }
    let rebasedFocusedIndex: Int = {
      if let exact = persistedWorkspaces.firstIndex(where: { $0.offset == focusedWorkspaceIndex }) {
        return exact
      }
      let priorCount = persistedWorkspaces.filter { $0.offset < focusedWorkspaceIndex }.count
      return priorCount > 0 ? priorCount - 1 : 0
    }()

    // Build workspace states with extension-internal URLs pruned.
    // WKWebExtension rotates the `<uuid>` in `webkit-extension://`
    // every launch, so persisting one would point at a dead UUID on
    // the next run and surface as an ERR_EXTENSION_NOT_FOUND ghost
    // pane the user can't recover. Drop those panes at save time;
    // legacy session.json contents already on disk fall through to
    // the restore-side `loadExtensionUnavailableError` path and are
    // self-cleaning on the next save round-trip.
    var persistedIds = Set<ULID>()
    let workspaceStates = persistedWorkspaces.compactMap {
      _, ws -> SessionState.WorkspaceState? in
      var columnStates: [SessionState.ColumnState] = []
      var keptColumnOriginalIndexes: [Int] = []
      for (colIdx, column) in ws.columns.enumerated() {
        var paneStates: [SessionState.PaneState] = []
        var keptPaneOriginalIndexes: [Int] = []
        for (paneIdx, pane) in column.panes.enumerated() {
          if pane.address.url.scheme == PaneAddress.extensionScheme {
            continue
          }
          var state = SessionState.PaneState(address: pane.address.description)
          if let bv = pane.browserView {
            if !pane.title.isEmpty { state.title = pane.title }
            // interactionState restores the full native back/forward
            // list + scroll/form. Read it off the live web view, or
            // carry the snapshot blob forward for a pane that hasn't
            // been refocused since restore.
            state.interactionState =
              bv.isSuspended
              ? bv.suspendedInteractionState
              : bv.webView.interactionState as? Data
          }
          paneStates.append(state)
          keptPaneOriginalIndexes.append(paneIdx)
        }
        if paneStates.isEmpty { continue }

        let width = Double(column.widthConstraint?.constant ?? defaultPaneWidth)

        // Height ratios are computed against the first surviving pane
        // after the prune, not the original first pane, so the ratio
        // chain stays consistent with the column being restored.
        var heightRatios: [Double] = []
        let survivors = keptPaneOriginalIndexes.map { column.panes[$0] }
        if survivors.count > 1,
          let firstHeight = survivors.first?.containerView.frame.height,
          firstHeight > 0
        {
          heightRatios = survivors.dropFirst().map { pane in
            pane.containerView.frame.height / firstHeight
          }
        }

        // Clamp focusedPaneIndex onto the survivor array. If the
        // focused pane was itself pruned, fall back to 0 — there is
        // no meaningful "next-closest" survivor to favour.
        let clampedPaneFocus =
          keptPaneOriginalIndexes.firstIndex(of: column.focusedPaneIndex) ?? 0

        columnStates.append(
          SessionState.ColumnState(
            id: column.id.string,
            panes: paneStates,
            focusedPaneIndex: clampedPaneFocus,
            width: width,
            heightRatios: heightRatios,
            isFolded: column.isFolded,
            unfoldedWidth: Double(column.unfoldedWidth)
          ))
        keptColumnOriginalIndexes.append(colIdx)
        persistedIds.insert(column.id)
      }
      if columnStates.isEmpty { return nil }

      // Clamp focusedColumnIndex symmetrically with the pane-level
      // logic above.
      let clampedColFocus =
        keptColumnOriginalIndexes.firstIndex(of: ws.focusedColumnIndex) ?? 0

      persistedIds.insert(ws.id)
      return SessionState.WorkspaceState(
        id: ws.id.string,
        columns: columnStates,
        focusedColumnIndex: clampedColFocus,
        scrollX: Double(ws.scrollX)
      )
    }

    // Filter the in-memory collapsed set down to ids that survived
    // the persistence filters. Private-workspace ids and pruned
    // column ids are dropped because their containers aren't on
    // disk — restoring such an id would be a dead entry.
    let collapsedIds: [String] = (sidebarVC?.collapsedItemIds() ?? [])
      .filter(persistedIds.contains)
      .map(\.string)
      .sorted()

    return SessionState(
      workspaces: workspaceStates,
      focusedWorkspaceIndex: rebasedFocusedIndex,
      urlBarVisible: urlBarVisible,
      sidebarPinned: sidebarVC?.currentState == .pinnedOpen,
      collapsedIds: collapsedIds.isEmpty ? nil : collapsedIds
    )
  }

  /// Save current session to disk.
  public func saveSession() {
    captureSession().save()
  }

  /// Debounce window for autosave, matching Chromium's session-save
  /// batch delay (`kSaveDelay`, 2500ms). Layout and navigation bursts
  /// (redirect chains, SPA `pushState`, rapid pane edits) collapse
  /// into a single write once activity settles.
  private static let autosaveDebounce: TimeInterval = 2.5

  /// Schedule a debounced session save. Called from every layout /
  /// focus mutation (via `notifySidebarWorklaneDidChange`) and from
  /// browser navigation (`onURLChange`); each call supersedes the
  /// prior pending save so rapid changes coalesce into one write.
  /// This is the save path that guards against crash / force-quit
  /// data loss — `applicationWillTerminate` only fires on a clean quit.
  func scheduleSessionAutosave() {
    sessionAutosaveWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.sessionAutosaveWorkItem = nil
        self?.saveSession()
      }
    }
    sessionAutosaveWorkItem = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.autosaveDebounce, execute: work)
  }

  /// Restore session from a saved state.
  func restoreSession(_ session: SessionState) {
    // Set first so that `setupPaneCallbacks`, run per-pane inside the
    // restore loop below, can push the right visibility state onto
    // each newly created URL bar.
    urlBarVisible = session.urlBarVisible
    guard !session.workspaces.isEmpty else { return }

    // Tear down the seed VC installed by `viewDidLoad` — we'll replace
    // it with per-session VCs below.
    for vc in workspaceVCs {
      vc.view.removeFromSuperview()
      vc.removeFromParent()
    }
    workspaces.removeAll()
    workspaceVCs.removeAll()

    // Resolve the single pane that boots into a live `WKWebView`:
    // the focused pane of the focused workspace. Every other browser
    // pane is constructed with `startSuspended: true` and renders the
    // placeholder until first focus restores it — avoids loading
    // every restored browser pane simultaneously. When the saved
    // indices fail to resolve a target (corrupt session, every
    // workspace empty), every pane boots suspended and the first
    // user focus brings one back.
    let liveTarget: (wsIdx: Int, colIdx: Int, paneIdx: Int)? = {
      guard session.workspaces.indices.contains(session.focusedWorkspaceIndex) else {
        logger.warning(
          "[session/restore] liveTarget unresolved: focusedWorkspaceIndex out of range")
        return nil
      }
      let liveWs = session.workspaces[session.focusedWorkspaceIndex]
      guard !liveWs.columns.isEmpty else {
        logger.warning("[session/restore] liveTarget unresolved: focused workspace has no columns")
        return nil
      }
      let colIdx = min(max(liveWs.focusedColumnIndex, 0), liveWs.columns.count - 1)
      let liveCol = liveWs.columns[colIdx]
      guard !liveCol.panes.isEmpty else {
        logger.warning("[session/restore] liveTarget unresolved: focused column has no panes")
        return nil
      }
      let paneIdx = min(max(liveCol.focusedPaneIndex, 0), liveCol.panes.count - 1)
      return (session.focusedWorkspaceIndex, colIdx, paneIdx)
    }()
    for (wsIdx, wsState) in session.workspaces.enumerated() {
      // Carry the saved ULID through so the sidebar's `collapsedIds`
      // set keeps matching the restored workspace; missing ids
      // (older session.json) fall back to a fresh ULID, which
      // drops any persisted collapse entry that referenced the
      // gone identity.
      let wsId = wsState.id.map(ULID.init) ?? ULID()
      let ws = WorkspaceModel(id: wsId)
      ws.scrollX = CGFloat(wsState.scrollX)
      let vc = WorkspaceViewController(workspace: ws)
      addChild(vc)
      workspaces.append(ws)
      workspaceVCs.append(vc)

      // Route column creation through this WS's VC by making it current.
      // The VC's view stays off-hierarchy during restore; the final
      // focused VC is installed below.
      focusedWorkspaceIndex = workspaces.count - 1

      for (colIdx, colState) in wsState.columns.enumerated() {
        guard let firstPaneState = colState.panes.first else { continue }
        let firstAddress = PaneAddress(firstPaneState.address) ?? .terminal

        let firstIsLive =
          liveTarget?.wsIdx == wsIdx
          && liveTarget?.colIdx == colIdx
          && liveTarget?.paneIdx == 0
        let columnId = colState.id.map(ULID.init) ?? ULID()
        let column = addColumn(
          address: firstAddress,
          dependencies: PaneDependencies(
            startSuspended: !firstIsLive,
            initialTitle: firstPaneState.title,
            initialInteractionState: firstPaneState.interactionState
          ),
          focusOnInsert: false,
          id: columnId
        )
        column.widthConstraint?.constant = CGFloat(colState.width)
        // Direct assignment rather than `handleTitleChange`: restore
        // runs before the sidebar view is installed, and we don't
        // want the header overlay flash / window.title write /
        // debounce timer that the shared handler triggers.
        if let title = firstPaneState.title {
          column.panes.first?.title = title
        }

        for (offset, paneState) in colState.panes.dropFirst().enumerated() {
          let paneIdx = offset + 1
          let address = PaneAddress(paneState.address) ?? .terminal
          let isLive =
            liveTarget?.wsIdx == wsIdx
            && liveTarget?.colIdx == colIdx
            && liveTarget?.paneIdx == paneIdx
          let pane = makePane(
            address: address,
            dependencies: PaneDependencies(
              startSuspended: !isLive,
              initialTitle: paneState.title,
              initialInteractionState: paneState.interactionState
            )
          )
          if let title = paneState.title { pane.title = title }
          setupPaneCallbacks(pane: pane, column: column)
          column.panes.append(pane)
        }

        if column.panes.count > 1 {
          rebuildColumnView(column: column)

          let expectedRatios = column.panes.count - 1
          if colState.heightRatios.count == expectedRatios {
            NSLayoutConstraint.deactivate(column.equalHeightConstraints)
            column.equalHeightConstraints.removeAll()
            let firstCV = column.panes[0].containerView
            for (i, ratio) in colState.heightRatios.enumerated() {
              let c = column.panes[i + 1].containerView.heightAnchor.constraint(
                equalTo: firstCV.heightAnchor, multiplier: ratio
              )
              c.isActive = true
              column.equalHeightConstraints.append(c)
            }
          }
        }

        if (0..<column.panes.count).contains(colState.focusedPaneIndex) {
          column.focusedPaneIndex = colState.focusedPaneIndex
        }

        // Apply persisted fold state after every pane is in place so
        // the folded-label text can read the right pane count and
        // title. Focus border placement on the folded label is
        // handled by the normal restore-focus path that runs later
        // (already keyed off `column.isFolded`).
        if colState.isFolded {
          applyRestoredFoldState(
            unfoldedWidth: CGFloat(colState.unfoldedWidth),
            to: column
          )
        }
      }

      preserveSurfaces(in: ws)
      if !ws.columns.isEmpty {
        ws.focusedColumnIndex = min(max(wsState.focusedColumnIndex, 0), ws.columns.count - 1)
      }
      logger.debug(
        "restoreSession wsId=\(String(describing: ws.id), privacy: .public) saved focusedCol=\(wsState.focusedColumnIndex) → set to \(ws.focusedColumnIndex), columns=\(ws.columns.count)"
      )
    }

    // Drop workspaces that ended up empty (e.g. all addresses unparseable).
    // Invariant: no empty workspace, and at least one workspace must exist.
    // At this point the VC's view has not yet been installed into the
    // container hierarchy — the `installWorkspaceView` loop runs later.
    // The defensive `removeFromSuperview` guards against future reorders
    // that might install views before this cleanup.
    for (i, ws) in workspaces.enumerated().reversed() where ws.columns.isEmpty {
      let vc = workspaceVCs.remove(at: i)
      if vc.isViewLoaded, vc.view.superview != nil {
        vc.view.removeFromSuperview()
      }
      vc.removeFromParent()
      workspaces.remove(at: i)
    }
    if workspaces.isEmpty {
      let ws = WorkspaceModel()
      let vc = WorkspaceViewController(workspace: ws)
      addChild(vc)
      workspaces.append(ws)
      workspaceVCs.append(vc)
    }

    focusedWorkspaceIndex = min(max(session.focusedWorkspaceIndex, 0), workspaces.count - 1)
    // Install every workspace's view upfront but keep them all visible
    // for now. If we hid non-current VCs here, AppKit would notice the
    // current first responder (set by the per-column `setFocus` calls
    // above) is in a newly-hidden view and reshuffle to the leftmost
    // visible pane — whose `onFocusChanged` callback then overwrites
    // `ws.focusedColumnIndex` to 0. Deferring the hide until after
    // `restoreFocusInCurrentWorkspace` commits the target first
    // responder side-steps that cascade.
    for (i, vc) in workspaceVCs.enumerated() {
      installWorkspaceView(vc, makeCurrent: i == focusedWorkspaceIndex)
      vc.view.isHidden = false
    }
    view.layoutSubtreeIfNeeded()
    // `setFocus` during the addColumn loop above leaves stale focus
    // borders on whichever column was last-inserted in each workspace
    // — its own clear-previous logic only tracks the single most-recent
    // pane, not the cross-workspace / cross-column trail. Wipe every
    // pane now so the final `restoreFocus` puts a single clean border
    // on the saved current pane.
    for ws in workspaces {
      clearAllFocusBorders(in: ws)
    }
    // Snapshot the intended focus target BEFORE running restoreFocus.
    // The initial responder cascade (when the window later becomes key)
    // would otherwise overwrite `ws.focusedColumnIndex` to 0, and any
    // re-apply in viewDidAppear would read that clobbered value.
    let ws = currentWorkspace
    if !ws.columns.isEmpty {
      let colIdx = min(max(ws.focusedColumnIndex, 0), ws.columns.count - 1)
      let column = ws.columns[colIdx]
      let paneIdx = min(max(column.focusedPaneIndex, 0), column.panes.count - 1)
      pendingInitialFocus = (focusedWorkspaceIndex, colIdx, paneIdx)
      logger.debug(
        "restoreSession snapshot focus ws=\(self.focusedWorkspaceIndex) col=\(colIdx) pane=\(paneIdx)"
      )
    }
    restoreFocusInCurrentWorkspace()
    // First responder now firmly on current WS's target pane — safe to
    // hide the non-current VCs without triggering an AppKit reshuffle.
    for (i, vc) in workspaceVCs.enumerated() where i != focusedWorkspaceIndex {
      vc.view.isHidden = true
    }
    restoreScroll(in: currentWorkspace)
  }
}
