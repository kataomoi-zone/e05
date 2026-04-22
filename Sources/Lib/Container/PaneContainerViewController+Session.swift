import AppKit
import GhosttyKit

extension PaneContainerViewController {
  // MARK: - Session Save/Restore

  /// Capture the current layout as a serializable session state.
  public func captureSession() -> SessionState {
    // Snapshot the live scroll offset onto the current workspace so it's
    // included in the save. Other workspaces already have their scrollX
    // recorded when they were last switched away from.
    currentWorkspace.scrollX = scrollView.contentView.bounds.origin.x

    NSLog("[e05/ws] captureSession: focusedWsIdx=%d, wsCount=%d", focusedWorkspaceIndex, workspaces.count)
    for (i, ws) in workspaces.enumerated() {
      let colFocused = ws.focusedColumnIndex
      let paneFocused = ws.columns[safe: colFocused]?.focusedPaneIndex ?? -1
      NSLog(
        "[e05/ws] captureSession ws[%d] id=%@ focusedCol=%d focusedPane=%d columns=%d",
        i, String(describing: ws.id), colFocused, paneFocused, ws.columns.count)
    }

    let workspaceStates = workspaces.map { ws -> SessionState.WorkspaceState in
      let columnStates = ws.columns.map { column -> SessionState.ColumnState in
        let paneStates = column.panes.map { pane -> SessionState.PaneState in
          var state = SessionState.PaneState(address: pane.address.description)
          if let webView = pane.browserView?.webView {
            if !pane.title.isEmpty { state.title = pane.title }
            let backList = webView.backForwardList.backList.map(\.url.absoluteString)
            let forwardList = webView.backForwardList.forwardList.map(\.url.absoluteString)
            if !backList.isEmpty { state.backHistory = backList }
            if !forwardList.isEmpty { state.forwardHistory = forwardList }
          }
          return state
        }
        let width = Double(column.widthConstraint?.constant ?? defaultPaneWidth)

        var heightRatios: [Double] = []
        if column.panes.count > 1, let firstHeight = column.panes.first?.containerView.frame.height, firstHeight > 0 {
          heightRatios = column.panes.dropFirst().map { pane in
            pane.containerView.frame.height / firstHeight
          }
        }

        return SessionState.ColumnState(
          panes: paneStates,
          focusedPaneIndex: column.focusedPaneIndex,
          width: width,
          heightRatios: heightRatios
        )
      }
      return SessionState.WorkspaceState(
        columns: columnStates,
        focusedColumnIndex: ws.focusedColumnIndex,
        scrollX: Double(ws.scrollX)
      )
    }

    return SessionState(
      workspaces: workspaceStates,
      focusedWorkspaceIndex: focusedWorkspaceIndex,
      urlBarVisible: urlBarVisible,
      sidebarPinned: sidebarVC?.currentState == .pinnedOpen
    )
  }

  /// Save current session to disk.
  public func saveSession() {
    captureSession().save()
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

    for wsState in session.workspaces {
      let ws = WorkspaceModel()
      ws.scrollX = CGFloat(wsState.scrollX)
      let vc = WorkspaceViewController(workspace: ws)
      addChild(vc)
      workspaces.append(ws)
      workspaceVCs.append(vc)

      // Route column creation through this WS's VC by making it current.
      // The VC's view stays off-hierarchy during restore; the final
      // focused VC is installed below.
      focusedWorkspaceIndex = workspaces.count - 1

      for colState in wsState.columns {
        guard let firstPaneState = colState.panes.first else { continue }
        let firstAddress = PaneAddress(firstPaneState.address) ?? .terminal

        let column = addColumn(address: firstAddress)
        column.widthConstraint?.constant = CGFloat(colState.width)
        // Direct assignment rather than `handleTitleChange`: restore
        // runs before the sidebar view is installed, and we don't
        // want the header overlay flash / window.title write /
        // debounce timer that the shared handler triggers.
        if let title = firstPaneState.title {
          column.panes.first?.title = title
        }

        for paneState in colState.panes.dropFirst() {
          let address = PaneAddress(paneState.address) ?? .terminal
          let pane = makePane(address: address)
          if let title = paneState.title { pane.title = title }
          setupPaneCallbacks(pane: pane, column: column)
          column.panes.append(pane)
        }

        // TODO: browser back/forward history restoration requires a
        // custom navigation stack (WKWebView.backForwardList is
        // read-only).

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
      }

      preserveSurfaces(in: ws)
      if !ws.columns.isEmpty {
        ws.focusedColumnIndex = min(max(wsState.focusedColumnIndex, 0), ws.columns.count - 1)
      }
      NSLog(
        "[e05/ws] restoreSession wsId=%@ saved focusedCol=%d → set to %d, columns=%d",
        String(describing: ws.id), wsState.focusedColumnIndex, ws.focusedColumnIndex, ws.columns.count)
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
      NSLog(
        "[e05/ws] restoreSession snapshot focus ws=%d col=%d pane=%d",
        focusedWorkspaceIndex, colIdx, paneIdx)
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
