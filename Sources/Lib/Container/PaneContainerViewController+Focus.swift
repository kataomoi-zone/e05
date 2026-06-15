import AppKit
import GhosttyKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "Focus")

extension PaneContainerViewController {
  // MARK: - Focus

  /// Move the focused pane to `(columnIndex, paneIndex)`.
  ///
  /// Focus alone never wakes a suspended browser pane — the user has
  /// to ask explicitly through a reload action (URL bar reload
  /// button, shortcut, palette `Reload` action, or the placeholder's
  /// Reload button). A suspended pane that takes focus stays on its
  /// placeholder; the responder chain routes through the placeholder
  /// view, which `acceptsFirstResponder` for exactly this reason.
  public func setFocus(
    columnIndex: Int, paneIndex: Int, scroll: Bool = true
  ) {
    logger.info(
      "setFocus entry col=\(columnIndex) pane=\(paneIndex) scroll=\(scroll ? "yes" : "no", privacy: .public) currentWs=\(self.focusedWorkspaceIndex)"
    )
    guard columns.indices.contains(columnIndex) else {
      logger.error("setFocus guard: bad columnIndex")
      return
    }
    guard let column = columns[safe: columnIndex],
      column.panes.indices.contains(paneIndex)
    else {
      logger.error("setFocus guard: bad paneIndex")
      return
    }
    let previouslyFocused = focusedPane

    // Per-pane find bar persistence: pane focus moves no longer
    // dismiss any pane's bar. Each pane keeps its own searchText,
    // visibility, and highlight state across ⌘⌃Tab cycles. Bars on
    // previously focused panes stay visible as passive overlays and
    // accept direct interaction via the per-bar callbacks bound in
    // `wireFindBarCallbacks`. Workspace slides dismiss every visible
    // bar in the outgoing workspace (see `+Workspaces.swift`)
    // because find panels are children of the host window and don't
    // follow `topConstraint` slide animation.
    let incomingPaneId = column.panes[paneIndex].id

    // Stamp the incoming pane active. `setFocus` is the single focus
    // funnel (the AppKit path routes through `handleFocusChange` →
    // `focusPane` → here), so this keeps `lastActiveAt` a true
    // last-focused timestamp rather than relying on the periodic
    // suspend-sweep bump — read by the idle-suspend clock and the
    // "inherit from latest finder" new-pane default.
    column.panes[paneIndex].lastActiveAt = .init()

    // Collapse any ⌘L peek on the outgoing pane — the URL bar
    // belongs to the user's current focus, so it shouldn't linger
    // on a pane the user has just navigated away from. Pinned panes
    // are owned by the global toggle and stay put (`setURLBarPeek`
    // is a no-op for `.pinned`). Hide the outgoing pane's top-edge
    // hit zone too so only the focused pane reacts to hover.
    if let outgoing = focusedPane, outgoing.id != incomingPaneId {
      outgoing.setURLBarPeek(false)
      outgoing.urlBarTopEdgeHitZone.isHidden = true
      // Reset the hover scheduler at the focus funnel. Hiding the
      // outgoing hit zone makes AppKit fire a synthetic
      // `mouseExited` on its way down, which would otherwise queue a
      // hover-out for the outgoing pane and burn a generation right
      // before the incoming pane wants to schedule its own hover-in.
      // Wiping both timers here keeps the new pane's scheduling on a
      // clean counter.
      cancelAllURLBarHoverScheduling()
    }

    // Clear ghostty focus on every terminal surface in the current
    // workspace except the incoming pane before we arm it via
    // makeFirstResponder below. AppKit's resignFirstResponder cascade
    // from makeFirstResponder only reaches the surface whose view is
    // the window's current first responder — menu, palette, and
    // sidebar dispatch paths leave the responder outside the pane
    // hierarchy, so outgoing surfaces keep reporting
    // ghostty_surface_set_focus(true) and caret blinks on two panes
    // at once. The incoming pane has to be skipped: makeFirstResponder
    // is a no-op when the target is already the first responder, so
    // if we cleared its flag here it would never be re-armed through
    // becomeFirstResponder and the caret would render as an
    // unfocused hollow box even though keyboard input is routed
    // correctly.
    for col in columns {
      for pane in col.panes where pane.id != incomingPaneId {
        pane.terminalView?.clearSurfaceFocus()
      }
    }

    if let previousPane = focusedPane {
      logger.debug(
        "setFocus clearing previous pane=\(String(describing: previousPane.id), privacy: .public)")
      clearFocusBorder(previousPane)
      hideHeaderForPane(previousPane)
    }

    focusedColumnIndex = columnIndex
    column.focusedPaneIndex = paneIndex

    let pane = column.panes[paneIndex]
    logger.info(
      "setFocus applying pane=\(String(describing: pane.id), privacy: .public) addr=\(pane.address.description, privacy: .public)"
    )
    // Inform the WKWebExtension bridge of the focus change up front
    // so the sticky "active browser pane" tracker stays current
    // regardless of what subsequent UI work (popup webView, find bar,
    // URL field editor) does to first responder. Apple's
    // `chrome.tabs.query({active})` is sourced from this sticky state.
    ExtensionController.shared.workspaceBridge.noteFocusChanged(pane)
    applyFocusBorder(pane)
    // Activate the incoming pane's top-edge hit zone so the hover
    // scheduler (wireURLBarHoverScheduler) observes the next hover near
    // the pane top and peeks the URL bar.
    pane.urlBarTopEdgeHitZone.isHidden = false
    if pane.isBlankBrowser || pane.startView != nil {
      // A blank or start pane focuses the URL bar so the user can type a
      // destination immediately (the start page's buttons stay
      // mouse-clickable). Use a peek (not a pin) so the regular
      // `onNavigate` / `onCancel` paths can collapse it —
      // `setURLBarVisible(true)` would lock the bar into `.pinned`,
      // which the peek-release call sites (PaneModel.setURLBarPeek(false)
      // and friends) skip by design, leaving it stuck open after the
      // navigate completes.
      if !pane.isURLBarVisible {
        pane.setURLBarPeek(true)
      }
      pane.urlBar.focusURLField()
    } else {
      let result = view.window?.makeFirstResponder(pane.preferredFirstResponder) ?? false
      logger.debug(
        "setFocus makeFirstResponder result=\(result ? "true" : "false", privacy: .public) actualFirstResponder=\(String(describing: self.view.window?.firstResponder), privacy: .public)"
      )
    }
    updateHandleActiveStates()
    showHeaderForFocusedPane()
    // Keep the OS-visible window title in step with the focused pane,
    // masking private-workspace panes. A plain focus change doesn't
    // re-fire a title event, so without this switching into a private
    // workspace would keep surfacing the previously focused public
    // pane's title (and switching back out would leave "Private
    // Browsing" stranded) until the next navigation.
    view.window?.title = maskedWindowTitle(for: pane)
    if scroll {
      scrollToColumn(at: columnIndex)
    }
    // Funnel point for sidebar refresh: every pane/column/workspace
    // mutation (addColumn, removePane, splitVertical, switchWorkspace,
    // createWorkspace, closeCurrentWorkspace, movePane, moveColumn*,
    // movePane*, undoClosePane) eventually calls setFocus, so hooking
    // here covers them all without sprinkling notify calls.
    notifySidebarWorklaneDidChange()
    // Same funnel point for the extension controller — every focus
    // move that promotes a browser pane fires `chrome.tabs.onActivated`,
    // which Bitwarden / autofill extensions key off to refresh their
    // popup contents. `notifyTabActivated` filters the previous-tab
    // when the outgoing pane wasn't a browser, so terminal-focus
    // round-trips don't synthesize phantom transitions.
    if previouslyFocused?.id != pane.id {
      ExtensionController.shared.notifyTabActivated(next: pane, previous: previouslyFocused)
    }
  }

  public func focusLeft() {
    guard focusedColumnIndex > 0 else { return }
    reclaimMainWindowKey()
    let newColIndex = focusedColumnIndex - 1
    let paneIndex = columns[newColIndex].focusedPaneIndex
    setFocus(columnIndex: newColIndex, paneIndex: paneIndex)
    showToast("Focus Left")
  }

  public func focusRight() {
    guard focusedColumnIndex < columns.count - 1 else { return }
    reclaimMainWindowKey()
    let newColIndex = focusedColumnIndex + 1
    let paneIndex = columns[newColIndex].focusedPaneIndex
    setFocus(columnIndex: newColIndex, paneIndex: paneIndex)
    showToast("Focus Right")
  }

  public func focusUp() {
    guard let column = columns[safe: focusedColumnIndex],
      column.focusedPaneIndex > 0
    else { return }
    reclaimMainWindowKey()
    setFocus(columnIndex: focusedColumnIndex, paneIndex: column.focusedPaneIndex - 1)
    showToast("Focus Up")
  }

  public func focusDown() {
    guard let column = columns[safe: focusedColumnIndex],
      column.focusedPaneIndex < column.panes.count - 1
    else { return }
    reclaimMainWindowKey()
    setFocus(columnIndex: focusedColumnIndex, paneIndex: column.focusedPaneIndex + 1)
    showToast("Focus Down")
  }

  /// Advance focus across every pane in the current workspace, treating
  /// the column / pane grid as one flat sequence: walk down the panes
  /// of a column first, then jump to the top of the next column, and
  /// wrap from the last column's last pane back to (0, 0). Maps to
  /// the conventional "next tab" gesture in keyboard-driven apps.
  public func focusNextPane() {
    guard let column = columns[safe: focusedColumnIndex] else { return }
    reclaimMainWindowKey()
    if column.focusedPaneIndex < column.panes.count - 1 {
      setFocus(columnIndex: focusedColumnIndex, paneIndex: column.focusedPaneIndex + 1)
      showToast("Next Pane")
    } else if let nextColumnIndex = nextNonEmptyColumnIndex(
      from: focusedColumnIndex, step: 1,
      wrap: PreferencesStore.shared.preferences.wrapPaneFocus ?? true
    ) {
      setFocus(columnIndex: nextColumnIndex, paneIndex: 0)
      showToast("Next Pane")
    }
  }

  /// Reverse of `focusNextPane`: walk up panes within a column, then
  /// jump to the bottom of the previous column, and wrap from (0, 0)
  /// back to the last column's last pane.
  public func focusPreviousPane() {
    guard let column = columns[safe: focusedColumnIndex] else { return }
    reclaimMainWindowKey()
    if column.focusedPaneIndex > 0 {
      setFocus(columnIndex: focusedColumnIndex, paneIndex: column.focusedPaneIndex - 1)
      showToast("Previous Pane")
    } else if let prevColumnIndex = nextNonEmptyColumnIndex(
      from: focusedColumnIndex, step: -1,
      wrap: PreferencesStore.shared.preferences.wrapPaneFocus ?? true
    ) {
      let lastPaneIndex = columns[prevColumnIndex].panes.count - 1
      setFocus(columnIndex: prevColumnIndex, paneIndex: lastPaneIndex)
      showToast("Previous Pane")
    }
  }

  /// Pull key-window status back to the host window before a
  /// keyboard-driven pane focus change. A find bar panel left key
  /// from a prior `focusField` would otherwise keep eating Enter /
  /// Esc / typed characters even after `setFocus` redirects the
  /// main window's first responder. Mouse-driven focus paths (bar
  /// click, sidebar pane row click) intentionally skip this so the
  /// click's own key transfer wins.
  private func reclaimMainWindowKey() {
    guard let mainWindow = view.window, !mainWindow.isKeyWindow else { return }
    mainWindow.makeKey()
  }

  /// Walk the columns array in `step` direction (+1 / -1) starting
  /// from `start` and return the first index whose column has at least
  /// one pane. With `wrap` the walk runs modulo `columns.count` and
  /// returns `nil` only when **every** column is empty; without it the
  /// walk stops at the array edge and returns `nil` once the edge is
  /// crossed (the "stop at the first / last pane" preference). The
  /// empty-column skip is defensive either way: that state shouldn't
  /// survive `removePane`'s column-collapse path, but `setFocus`
  /// precondition-traps on an empty column.
  private func nextNonEmptyColumnIndex(from start: Int, step: Int, wrap: Bool) -> Int? {
    guard !columns.isEmpty else { return nil }
    let count = columns.count
    if wrap {
      var idx = ((start + step) % count + count) % count
      while columns[idx].panes.isEmpty {
        if idx == start { return nil }
        idx = ((idx + step) % count + count) % count
      }
      return idx
    }
    var idx = start + step
    while idx >= 0, idx < count {
      if !columns[idx].panes.isEmpty { return idx }
      idx += step
    }
    return nil
  }

  // MARK: - Width Preset Cycle

  /// Cycle the focused column's width through the given preset list.
  /// No-op when the column is folded — fold owns the column's
  /// width, and a cycle write would either be ignored by Auto
  /// Layout or survive past unfold as a stale `currentPreset`.
  public func cycleWidthPreset(_ cycle: [PaneWidthPreset]) {
    guard !cycle.isEmpty, let column = columns[safe: focusedColumnIndex] else { return }
    guard !column.isFolded else { return }

    let nextIndex: Int
    if let current = column.currentPreset,
      let idx = cycle.firstIndex(of: current)
    {
      nextIndex = (idx + 1) % cycle.count
    } else {
      nextIndex = 0
    }

    let preset = cycle[nextIndex]
    column.currentPreset = preset
    applyPreset(preset, to: column)
    // A pinned column's width drives its leading reserve; recompute it
    // so the scrolling columns track the new width.
    if column.isPinned {
      applyLeadingInset(in: currentWorkspaceVC)
    }
    view.layoutSubtreeIfNeeded()
    scrollToColumn(at: focusedColumnIndex)
    showToast("Cycle Width (\(preset.displayLabel))")
  }

  func applyPreset(_ preset: PaneWidthPreset, to column: ColumnModel) {
    guard let constraint = column.widthConstraint else { return }
    switch preset {
    case .points(let p):
      constraint.constant = p
    case .fraction(let f):
      // `.fraction` is the column's share of the workspace's content
      // area: the visible region (`effectiveVisibleWidth` strips the
      // pinned-sidebar inset) minus the workspace stack's
      // `outerMargin` perimeter on each side. The naive formula
      // `usableWidth * f` looks right for a single column but
      // overflows by handle width for every extra column at the same
      // fraction — two `.fraction(0.5)` panes at `usableWidth/2`
      // each plus a resize handle between them and a perimeter on
      // each side end up `handle` wider than the visible region, and
      // the right pane gets clipped past the workspace edge.
      //
      // Correct tiling for N adjacent columns at fraction `f = 1/N`:
      //     col*N + handle*(N-1) + 2*perimeter = window
      //   → col   = usableWidth*f - (1 - f)*handle
      // so each column "donates" `(1 - f) * handle` of its share to
      // the (N-1) inter-column gaps. At `f = 1.0` the correction is
      // 0 and a single 100% column still fills the full content
      // area; at smaller `f` the donation grows toward `handle`.
      //
      // Concrete numbers for a 1000pt window, 6pt perimeter / handle:
      //   100% → 988pt   (one column, flush inside the perimeter)
      //   50%  → 491pt   (two columns: 6 + 491 + 6 + 491 + 6 = 1000)
      //   33%  → 322pt   (three columns: 6 + 322*3 + 6*2 + 6 = 990,
      //                   ~10pt slack — the Settings UI renders the
      //                   fraction as an integer percentage, so the
      //                   default cycle stores `.fraction(0.33)`
      //                   rather than the exact 1/3 a pixel-perfect
      //                   tile would need. The visible slack at the
      //                   right perimeter is the deliberate cost of
      //                   keeping "33%" addressable from the editor.)
      //
      // Once committed, the constant stays put. `viewDidLayout`
      // intentionally does NOT re-evaluate `.fraction` — a pane
      // carries live HTML / terminal output, and reflowing those
      // surfaces every sidebar peek / window resize is worse than
      // letting the column extend past the visible region (scroll
      // reaches the rest). The next Cycle Width press picks up the
      // current visible region.
      let visibleWidth = effectiveVisibleWidth(in: scrollView)
      let perimeter = WorkspaceViewController.outerMargin
      let usableWidth = visibleWidth - 2 * perimeter
      guard usableWidth > 0 else { return }
      constraint.constant = usableWidth * f - (1 - f) * perimeter
    }
  }

  // MARK: - Column Reorder

  public func moveColumnLeft() {
    guard focusedColumnIndex > 0 else { return }
    let moved = columns[focusedColumnIndex]
    let displaced = columns[focusedColumnIndex - 1]
    // Pinned columns live in the leading overlay, outside the stack's
    // coordinate space — swapping one (or swapping past one) would feed
    // `animateLayerSwap` an overlay-relative frame and desync the pin.
    guard !moved.isPinned, !displaced.isPinned else { return }
    let oldMovedFrame = moved.containerView.frame
    let oldDisplacedFrame = displaced.containerView.frame

    columns.swapAt(focusedColumnIndex, focusedColumnIndex - 1)
    focusedColumnIndex -= 1
    rebuildStackView()
    view.layoutSubtreeIfNeeded()
    // Keep the scroll position where it was: both columns were
    // already on-screen before the swap, and re-centring on the
    // focused column would shove the other one off the edge.
    setFocus(
      columnIndex: focusedColumnIndex,
      paneIndex: columns[focusedColumnIndex].focusedPaneIndex,
      scroll: false)

    animateLayerSwap(
      moved.containerView, oldFrameA: oldMovedFrame,
      displaced.containerView, oldFrameB: oldDisplacedFrame)
    showToast("Move Column Left")
  }

  public func moveColumnRight() {
    guard focusedColumnIndex < columns.count - 1 else { return }
    let moved = columns[focusedColumnIndex]
    let displaced = columns[focusedColumnIndex + 1]
    // See `moveColumnLeft` — pinned columns are excluded from reordering.
    guard !moved.isPinned, !displaced.isPinned else { return }
    let oldMovedFrame = moved.containerView.frame
    let oldDisplacedFrame = displaced.containerView.frame

    columns.swapAt(focusedColumnIndex, focusedColumnIndex + 1)
    focusedColumnIndex += 1
    rebuildStackView()
    view.layoutSubtreeIfNeeded()
    setFocus(
      columnIndex: focusedColumnIndex,
      paneIndex: columns[focusedColumnIndex].focusedPaneIndex,
      scroll: false)

    animateLayerSwap(
      moved.containerView, oldFrameA: oldMovedFrame,
      displaced.containerView, oldFrameB: oldDisplacedFrame)
    showToast("Move Column Right")
  }

  // MARK: - Pane Reorder within Column

  public func movePaneUp() {
    guard let column = columns[safe: focusedColumnIndex],
      column.focusedPaneIndex > 0
    else { return }
    let idx = column.focusedPaneIndex
    let moved = column.panes[idx]
    let displaced = column.panes[idx - 1]
    let oldMovedFrame = moved.containerView.frame
    let oldDisplacedFrame = displaced.containerView.frame

    column.panes.swapAt(idx, idx - 1)
    column.focusedPaneIndex = idx - 1
    rebuildColumnView(column: column)
    view.layoutSubtreeIfNeeded()
    setFocus(
      columnIndex: focusedColumnIndex,
      paneIndex: column.focusedPaneIndex,
      scroll: false)

    animateLayerSwap(
      moved.containerView, oldFrameA: oldMovedFrame,
      displaced.containerView, oldFrameB: oldDisplacedFrame)
    showToast("Move Pane Up")
  }

  public func movePaneDown() {
    guard let column = columns[safe: focusedColumnIndex],
      column.focusedPaneIndex < column.panes.count - 1
    else { return }
    let idx = column.focusedPaneIndex
    let moved = column.panes[idx]
    let displaced = column.panes[idx + 1]
    let oldMovedFrame = moved.containerView.frame
    let oldDisplacedFrame = displaced.containerView.frame

    column.panes.swapAt(idx, idx + 1)
    column.focusedPaneIndex = idx + 1
    rebuildColumnView(column: column)
    view.layoutSubtreeIfNeeded()
    setFocus(
      columnIndex: focusedColumnIndex,
      paneIndex: column.focusedPaneIndex,
      scroll: false)

    animateLayerSwap(
      moved.containerView, oldFrameA: oldMovedFrame,
      displaced.containerView, oldFrameB: oldDisplacedFrame)
    showToast("Move Pane Down")
  }

  // MARK: - Stack View Rebuild

  /// Rebuild arrangedSubviews from the current workspace's columns.
  func rebuildStackView() {
    rebuildStackView(in: currentWorkspaceVC)
  }

  /// Rebuild a specific workspace's stackView. Used by `movePane` so that
  /// the source workspace (which may no longer be current after the move)
  /// gets its handles refreshed.
  func rebuildStackView(in vc: WorkspaceViewController) {
    let sv = vc.stackView
    // Pinned columns live in the leading overlay (see `+Pin.swift`),
    // not in the scrolling stack, so they get neither an arranged slot
    // nor a neighbouring resize handle here.
    let cols = vc.workspace.columns.filter { !$0.isPinned }
    for v in sv.arrangedSubviews.reversed() {
      sv.removeArrangedSubview(v)
      if v is PaneResizeHandle { v.removeFromSuperview() }
    }
    for (i, column) in cols.enumerated() {
      if i > 0 {
        let handle = makeColumnResizeHandle(for: cols[i - 1])
        sv.addArrangedSubview(handle)
        NSLayoutConstraint.activate(PaneResizeHandle.makeConstraints(for: handle))
      }
      sv.addArrangedSubview(column.containerView)
    }
    // Add a trailing resize handle on the last column so single-pane layouts can be resized
    if let lastColumn = cols.last {
      let handle = makeColumnResizeHandle(for: lastColumn)
      sv.addArrangedSubview(handle)
      NSLayoutConstraint.activate(PaneResizeHandle.makeConstraints(for: handle))
    }
  }

  /// A horizontal handle is the right-edge grip of the column to its left.
  /// The strip is left-anchored, so the divider position is the cumulative
  /// width to its left — dragging it can only resize that left column (the
  /// columns to the right simply follow). Every column is reachable this way:
  /// the between-columns handles grab their left neighbour, the trailing
  /// handle grabs the last column. Active state (folded columns excepted) is
  /// handled by `updateHandleActiveStates`; `mouseDown` blocks drag when
  /// `!isActive`, so `onDrag` only re-checks the fold.
  private func makeColumnResizeHandle(for column: ColumnModel) -> PaneResizeHandle {
    let handle = PaneResizeHandle(orientation: .horizontal)
    handle.onDrag = { [weak self, weak column] deltaX in
      // `self` is captured weakly to break the retain cycle with the
      // handle's stored closure; the body site only reaches for the
      // type via `Self.minPaneWidth`, so a `!= nil` liveness check
      // is sufficient.
      guard self != nil, let column, let constraint = column.widthConstraint else { return }
      // Folded columns are pinned by an upgraded-to-required
      // `widthConstraint`; mutating the constant from drag would
      // either no-op or write a value that survives past unfold.
      // Fold owns the column's width.
      guard !column.isFolded else { return }
      let newWidth = max(Self.minPaneWidth, constraint.constant + deltaX)
      constraint.constant = newWidth
      column.currentPreset = nil
    }
    return handle
  }

  /// Rebuild the containerView of a column from its panes array.
  /// Inserts vertical resize handles between panes and sets equal height constraints.
  func rebuildColumnView(column: ColumnModel) {
    let sv = column.containerView

    // Drop previous equal-height constraints — reinstalled below.
    NSLayoutConstraint.deactivate(column.equalHeightConstraints)
    column.equalHeightConstraints.removeAll()

    // Resize handles are rebuilt from scratch every time so the
    // per-pair top/bottom index bindings stay consistent; the
    // pane containerViews, on the other hand, are preserved in
    // place to avoid triggering a layout + animation glitch.
    //
    // Under `allowsImplicitAnimation`, pulling a pane
    // containerView out of `arrangedSubviews` and putting it
    // back synchronously made the existing pane's frame tween
    // through an intermediate stack-view-empty layout — the
    // user saw it slide upwards (URL bar clipped off the top)
    // before settling at half height. Leaving in-place panes
    // untouched means the tween only sees the size change from
    // the new equal-height constraints.
    for v in sv.arrangedSubviews where v is PaneResizeHandle {
      sv.removeArrangedSubview(v)
      v.removeFromSuperview()
    }

    // Drop pane containerViews that no longer map to a live
    // pane. Those represent panes removed by `removePane`'s
    // animation path and should be fully detached here.
    let liveContainerIds = Set(column.panes.map { ObjectIdentifier($0.containerView) })
    for v in sv.arrangedSubviews.reversed() where !liveContainerIds.contains(ObjectIdentifier(v)) {
      sv.removeArrangedSubview(v)
      v.removeFromSuperview()
    }

    // Insert / reorder panes + handles so the sequence is
    // pane, handle, pane, handle, pane, …, matching
    // `column.panes`. Live panes already in `arrangedSubviews`
    // at the right index stay put.
    var firstCV: NSView?
    for (i, pane) in column.panes.enumerated() {
      let handleIndex = i == 0 ? nil : (i * 2 - 1)
      if let handleIndex {
        let handle = makeVerticalResizeHandle(column: column, topIndex: i - 1, bottomIndex: i)
        sv.insertArrangedSubview(handle, at: handleIndex)
        NSLayoutConstraint.activate(PaneResizeHandle.makeConstraints(for: handle))
      }

      let cv = pane.containerView
      let paneTargetIndex = i * 2
      if let currentIndex = sv.arrangedSubviews.firstIndex(of: cv) {
        if currentIndex != paneTargetIndex {
          // `removeArrangedSubview` + `insertArrangedSubview`
          // is the NSStackView-supported way to reorder; the
          // view's subview membership and its leading/trailing
          // constraints survive the round-trip.
          sv.removeArrangedSubview(cv)
          sv.insertArrangedSubview(cv, at: paneTargetIndex)
        }
      } else {
        sv.insertArrangedSubview(cv, at: paneTargetIndex)
        NSLayoutConstraint.activate([
          cv.leadingAnchor.constraint(equalTo: sv.leadingAnchor),
          cv.trailingAnchor.constraint(equalTo: sv.trailingAnchor),
        ])
      }

      // Equal height constraints between all panes
      // (deactivated on drag-resize)
      if let first = firstCV {
        let c = cv.heightAnchor.constraint(equalTo: first.heightAnchor)
        c.isActive = true
        column.equalHeightConstraints.append(c)
      } else {
        firstCV = cv
      }
    }

    // `insertArrangedSubview` appends into `subviews` near the
    // end, which would sink the folded-label overlay behind the
    // pane views. Re-hoist it so the overlay sits on top when
    // the column is folded.
    if column.foldedLabelView.superview === sv {
      sv.addSubview(column.foldedLabelView, positioned: .above, relativeTo: nil)
    }

    // Detach progress bars whose owning pane is no longer in this
    // column — a drag-move leaves the bar attached to the source
    // column even though its constraints now reference a pane that
    // belongs to a different column, which Auto Layout flags between
    // the source rebuild and the target rebuild.
    for sub in sv.subviews where sub is LoadingProgressBarView {
      let owned = column.panes.contains { $0.browserView?.progressBar === sub }
      if !owned {
        sub.removeFromSuperview()
      }
    }

    // Re-anchor each browser pane's progress bar to the rebuilt
    // column. Drag-moves between columns and `splitVertical` both
    // route through here, so this is the single chokepoint that
    // keeps the bar following its pane across structural changes.
    for pane in column.panes {
      ensureProgressBarAttached(pane: pane, in: column)
    }
  }

  private func makeVerticalResizeHandle(column: ColumnModel, topIndex: Int, bottomIndex: Int)
    -> PaneResizeHandle
  {
    let handle = PaneResizeHandle(orientation: .vertical)
    // Vertical handles are always active within a column (unlike horizontal
    // handles which are only active adjacent to the focused column).
    handle.isActive = true
    let topPaneId = column.panes[topIndex].id
    let bottomPaneId = column.panes[bottomIndex].id
    handle.onDrag = { [weak self, weak column] deltaY in
      guard let self, let column, column.panes.count > 1,
        let topIdx = column.panes.firstIndex(where: { $0.id == topPaneId }),
        let bottomIdx = column.panes.firstIndex(where: { $0.id == bottomPaneId })
      else { return }
      let topPane = column.panes[topIdx]
      let bottomPane = column.panes[bottomIdx]

      // AppKit Y is up, so dragging down (negative deltaY) should grow the top pane
      let newTopHeight = topPane.containerView.frame.height - deltaY
      let newBottomHeight = bottomPane.containerView.frame.height + deltaY
      guard newTopHeight >= self.minPaneHeight, newBottomHeight >= self.minPaneHeight else {
        return
      }

      // Replace all height constraints with ratio constraints relative to first pane.
      // Ratio constraints fill the container naturally — no absolute heights needed.
      NSLayoutConstraint.deactivate(column.equalHeightConstraints)
      column.equalHeightConstraints.removeAll()

      let firstCV = column.panes[0].containerView
      // Use current frame heights (with the drag delta applied to the two panes)
      for (i, pane) in column.panes.enumerated() where i > 0 {
        let currentHeight: CGFloat
        if pane.id == topPane.id {
          currentHeight = newTopHeight
        } else if pane.id == bottomPane.id {
          currentHeight = newBottomHeight
        } else {
          currentHeight = pane.containerView.frame.height
        }
        let firstHeight =
          (column.panes[0].id == topPane.id)
          ? newTopHeight
          : (column.panes[0].id == bottomPane.id) ? newBottomHeight : firstCV.frame.height
        guard firstHeight > 0 else { continue }
        let ratio = currentHeight / firstHeight
        let c = pane.containerView.heightAnchor.constraint(
          equalTo: firstCV.heightAnchor, multiplier: ratio
        )
        c.isActive = true
        column.equalHeightConstraints.append(c)
      }
    }
    return handle
  }

  /// Update which horizontal resize handles are active. Each handle grips the
  /// right edge of the column to its left (see `makeColumnResizeHandle(for:)`),
  /// so every column is resizable regardless of focus. A folded column
  /// suppresses its own handle — the strip's width is owned by the fold path,
  /// so the resize affordance has nothing to grab.
  func updateHandleActiveStates() {
    let arranged = stackView.arrangedSubviews
    for (i, v) in arranged.enumerated() {
      guard let handle = v as? PaneResizeHandle else { continue }
      let leftView = arranged[safe: i - 1]
      let leftColumn = columns.first { $0.containerView === leftView }
      handle.isActive = leftColumn.map { !$0.isFolded } ?? false
    }
  }

  // MARK: - Focus Indicator

  func applyFocusBorder(_ pane: PaneModel, in workspace: WorkspaceModel? = nil) {
    let cv = pane.containerView
    cv.wantsLayer = true
    // Resolve the pane's workspace explicitly so callers walking
    // every workspace (Appearance preset fan-outs) get the right
    // accent slot and the right columns to scan for the folded
    // label. Falling back to a lookup lets the simple
    // current-workspace callers stay terse.
    let resolvedWorkspace = workspace ?? workspaceContaining(pane: pane)
    let isPrivate = resolvedWorkspace?.isPrivate ?? false
    let borderColor: NSColor
    if let resolvedWorkspace,
      let index = workspaces.firstIndex(where: { $0.id == resolvedWorkspace.id })
    {
      borderColor = Self.accentColor(forWorkspaceAt: index)
    } else {
      borderColor = focusBorderColor
    }
    if isPrivate {
      cv.layer?.borderWidth = 0
      cv.layer?.borderColor = nil
      installDottedBorderOverlay(in: cv, color: borderColor)
    } else {
      removeDottedBorderOverlay(in: cv)
      cv.layer?.borderWidth = focusBorderWidth
      cv.layer?.borderColor = borderColor.cgColor
    }
    logger.debug(
      "applyFocusBorder paneId=\(String(describing: pane.id), privacy: .public) layerExists=\(cv.layer == nil ? "no" : "yes", privacy: .public) borderWidth=\(cv.layer?.borderWidth ?? -1) private=\(isPrivate ? "yes" : "no", privacy: .public)"
    )

    let searchColumns = resolvedWorkspace?.columns ?? self.columns
    if let column = searchColumns.first(where: {
      $0.panes.contains(where: { $0.id == pane.id })
    }), column.isFolded {
      column.foldedLabelView.wantsLayer = true
      if isPrivate {
        column.foldedLabelView.layer?.borderWidth = 0
        column.foldedLabelView.layer?.borderColor = nil
        installDottedBorderOverlay(in: column.foldedLabelView, color: borderColor)
      } else {
        removeDottedBorderOverlay(in: column.foldedLabelView)
        column.foldedLabelView.layer?.borderWidth = focusBorderWidth
        column.foldedLabelView.layer?.borderColor = borderColor.cgColor
      }
    }
  }

  func clearFocusBorder(_ pane: PaneModel) {
    let cv = pane.containerView
    let hadBorder =
      (cv.layer?.borderWidth ?? 0) > 0 || cv.subviews.contains(where: { $0 is DottedBorderOverlay })
    cv.layer?.borderWidth = 0
    cv.layer?.borderColor = nil
    removeDottedBorderOverlay(in: cv)
    if hadBorder {
      logger.debug(
        "clearFocusBorder paneId=\(String(describing: pane.id), privacy: .public) (had border)")
    }

    if let column = columns.first(where: { $0.panes.contains(where: { $0.id == pane.id }) }) {
      column.foldedLabelView.layer?.borderWidth = 0
      column.foldedLabelView.layer?.borderColor = nil
      removeDottedBorderOverlay(in: column.foldedLabelView)
    }
  }

  /// Install a dashed border overlay on `host`, replacing any existing
  /// instance. The overlay uses autoresizing so it tracks the host's
  /// bounds without explicit constraints; corner radius mirrors the
  /// host layer's so the dashed line traces the same rounded
  /// rectangle as the existing solid border.
  private func installDottedBorderOverlay(in host: NSView, color: NSColor) {
    let overlay =
      host.subviews.first(where: { $0 is DottedBorderOverlay }) as? DottedBorderOverlay
      ?? {
        let new = DottedBorderOverlay(frame: host.bounds)
        host.addSubview(new)
        return new
      }()
    overlay.borderColor = color
    overlay.borderWidth = focusBorderWidth
    overlay.cornerRadius = host.layer?.cornerRadius ?? 0
    overlay.frame = host.bounds
    overlay.needsDisplay = true
  }

  private func removeDottedBorderOverlay(in host: NSView) {
    for subview in host.subviews where subview is DottedBorderOverlay {
      subview.removeFromSuperview()
    }
  }

  // MARK: - Scrolling

  /// Returns whether a scroll was actually scheduled — `false` when the
  /// column is missing or already seated (nothing to move). Callers that
  /// surface feedback (the align actions' toast) gate on it.
  @discardableResult
  func scrollToColumn(at index: Int, mode: ColumnScrollMode = .frameIn) -> Bool {
    guard let column = columns[safe: index] else { return false }
    // A pinned column sits in the fixed leading overlay, always on
    // screen, so there is nothing to scroll it into view for.
    guard !column.isPinned else { return false }

    view.layoutSubtreeIfNeeded()
    // `.frameIn` (the default) scrolls the minimum to reveal the column
    // and leaves the position untouched when it is already visible, so a
    // focus hop keeps neighbouring columns on screen; the explicit align
    // / centre actions pass a fixed mode. `computeScrollTargetX` returns
    // a *logical* origin — the live compensation is added at apply time.
    guard let logicalX = computeScrollTargetX(for: column, mode: mode) else { return false }

    // Defer the apply to a fresh run-loop tick. Mouse-event-driven paths
    // (direct pane click, sidebar row click) call scrollToColumn from
    // inside `NSView.mouseDown(with:)`; an NSAnimationContext opened there
    // collapses to an instantaneous transition because AppKit flushes
    // layout within the same event dispatch. Deferring lets the mouse
    // event return first, then the animator produces a visible ease-out.
    // The command-palette path already runs outside mouseDown so the
    // ~0ms defer is a no-op for it.
    //
    // Overlapping animated calls (rapid-fire clicks) are resolved by
    // CoreAnimation animator reuse — writing the same property from a new
    // animator cancels the previous one, producing a smooth re-target.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // The live origin is `logical + hoverPeekScrollCompensation`, read
      // here at apply time. When `comp != 0` (a genuine hover-peek), snap
      // instead of animating: the peek retracts by offsetting the origin
      // by the compensation the instant the cursor leaves, and an
      // in-flight tween would win that race and leave the column a
      // sidebar-width off the edge. Snapping keeps `live == logical + comp`
      // true through the retract, and the peeked column sits under the
      // overlay so no visible tween is lost. A peek→pinned promotion
      // zeroes `comp` synchronously before this tick, so that path
      // animates (the column is no longer under an overlay there).
      let comp = self.hoverPeekScrollCompensation
      let liveTarget = logicalX + comp
      if comp != 0 {
        self.scrollView.contentView.setBoundsOrigin(NSPoint(x: liveTarget, y: 0))
        return
      }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        self.scrollView.contentView.animator().bounds.origin.x = liveTarget
      }
    }
    return true
  }

  /// Scroll the focused column to an explicit alignment within the
  /// viewport — the deliberate counterpart of the frame-in scroll a
  /// focus hop performs. Backs the align-left / align-right /
  /// centre-column actions; focus is untouched, only the scroll moves.
  func scrollFocusedColumn(_ mode: ColumnScrollMode) {
    guard columns.indices.contains(focusedColumnIndex) else { return }
    // Only confirm with a toast when something actually scrolled — when
    // every column already fits on screen `scrollToColumn` is a no-op,
    // and a toast would then claim an alignment that never happened.
    guard scrollToColumn(at: focusedColumnIndex, mode: mode) else { return }
    switch mode {
    case .alignLeft: showToast("Align Column Left")
    case .alignRight: showToast("Align Column Right")
    case .center: showToast("Center Column")
    case .frameIn: break
    }
  }

  // MARK: - Event Handlers

  /// Called when a pane's content view (terminal/browser/list/downloads)
  /// gains focus — typically via click, but can also fire from programmatic
  /// `makeFirstResponder` (e.g. sidebar-driven focus). Delegates to
  /// `focusPane(id:)` so cross-workspace focus changes (clicking a pane
  /// after AppKit restores first responder on a non-current workspace)
  /// resolve correctly. The previous current-WS-only scan would silently
  /// drop focus updates for panes parked in non-current workspaces.
  func handleFocusChange(from pane: PaneModel) {
    logger.debug(
      "handleFocusChange paneId=\(String(describing: pane.id), privacy: .public) addr=\(pane.address.description, privacy: .public)"
    )
    // Cold-restore guard: while `pendingInitialFocus` is non-nil the
    // session restore is still in flight and `viewDidAppear` hasn't
    // re-applied the saved focus yet. AppKit's `_setUpFirstResponder`
    // cascade lands first responder on the leftmost keyboard-focusable
    // view during the window's initial responder selection, which
    // would otherwise route through here and trigger
    // `setFocus(scroll: true)` → a deferred `scrollToColumn(at: 0)`
    // animator that races `viewDidAppear`'s snap. The animator wins
    // because it dispatches onto a later run-loop tick, leaving the
    // viewport at column 0 — the "focus restored briefly, then forced
    // to leftmost" startup symptom. Dropping the AppKit-driven change
    // here keeps the saved scrollX intact; viewDidAppear's
    // `pendingInitialFocus` re-apply restores focus cleanly.
    if pendingInitialFocus != nil {
      logger.debug("handleFocusChange skipped: pending initial focus")
      return
    }
    // O(1) short-circuit: already the focused pane → nothing to do.
    // Any other case falls through to focusPane, which handles both
    // same-WS and cross-WS cases (and its own reentrancy guard).
    if focusedPane?.id == pane.id {
      logger.debug("handleFocusChange guard: already focused")
      return
    }
    focusPane(id: pane.id)
  }

  /// Focus a pane by id across all workspaces.
  ///
  /// - Same workspace: synchronous `setFocus`.
  /// - Different workspace: pre-seeds the target workspace's focused
  ///   indices and triggers `switchWorkspace(to:)`. The real focus
  ///   application happens ~0.25s later inside animateSlide's completion
  ///   handler (via `restoreFocusInCurrentWorkspace`). Pre-seeding is
  ///   essential — without it, switchWorkspace would restore the target
  ///   workspace's *previous* focused pane instead of the requested one.
  ///
  /// Avoids a double setFocus (visible border flicker + scroll animation
  /// thrash) that would happen if this method also applied setFocus
  /// synchronously in the cross-WS branch.
  ///
  /// Callers that need post-focus state (e.g. the sidebar) should observe
  /// via `onFocusChanged`, not read `focusedPane` immediately after.
  ///
  /// No-op while a workspace switch animation is in flight — protects
  /// against reentrancy (e.g. sidebar click-spam during a slide).
  /// Silently returns if no pane matches.
  public func focusPane(id: ULID) {
    guard !isAnimatingWorkspaceSwitch else {
      logger.debug("focusPane skipped: workspace switch animation in flight")
      return
    }
    for (wsIdx, ws) in workspaces.enumerated() {
      for (colIdx, col) in ws.columns.enumerated() {
        if let paneIdx = col.panes.firstIndex(where: { $0.id == id }) {
          if wsIdx != focusedWorkspaceIndex {
            // Pre-seed indices so animateSlide's completion
            // (restoreFocusInCurrentWorkspace → setFocus) lands
            // on the right pane. switchWorkspace itself drives
            // the single setFocus at animation end.
            //
            // restoreFocusInCurrentWorkspace calls setFocus
            // with scroll=false so the workspace's saved
            // scrollX is preserved on normal Ctrl+Tab. For
            // cross-WS pane focus we *do* want to scroll to
            // the target column once the slide finishes, so
            // kick scrollToColumn from the completion handler.
            ws.focusedColumnIndex = colIdx
            col.focusedPaneIndex = paneIdx
            switchWorkspace(to: wsIdx) { [weak self] in
              // Safe to reuse the captured colIdx across the
              // ~250ms slide: scrollToColumn guards with
              // `columns[safe: colIdx]`, so if the layout
              // changed mid-animation (blocked by
              // `isAnimatingWorkspaceSwitch` for most
              // mutations anyway) the call degrades to a
              // no-op instead of a crash.
              self?.scrollToColumn(at: colIdx)
            }
          } else {
            setFocus(columnIndex: colIdx, paneIndex: paneIdx)
          }
          return
        }
      }
    }
  }
}
