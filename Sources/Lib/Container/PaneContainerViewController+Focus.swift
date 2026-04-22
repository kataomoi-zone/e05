import AppKit
import GhosttyKit

extension PaneContainerViewController {
  // MARK: - Focus

  public func setFocus(columnIndex: Int, paneIndex: Int, scroll: Bool = true) {
    NSLog(
      "[e05/ws] setFocus entry col=%d pane=%d scroll=%@ currentWs=%d",
      columnIndex, paneIndex, scroll ? "yes" : "no", focusedWorkspaceIndex)
    guard columns.indices.contains(columnIndex) else {
      NSLog("[e05/ws] setFocus guard: bad columnIndex")
      return
    }
    guard let column = columns[safe: columnIndex],
      column.panes.indices.contains(paneIndex)
    else {
      NSLog("[e05/ws] setFocus guard: bad paneIndex")
      return
    }

    // Dismiss the find bar whenever focus is moving to a pane other
    // than the one the bar targets. `setFocus` is the funnel point
    // for every pane / column / workspace mutation (add, remove,
    // split, switchWorkspace, createWorkspace, closeCurrentWorkspace,
    // movePane, undo-close), so one hook here covers them all without
    // sprinkling close calls across every caller.
    let incomingPaneId = column.panes[paneIndex].id
    if let target = findBarTargetPane, target.id != incomingPaneId {
      closeFindBar()
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
      NSLog("[e05/ws] setFocus clearing previous pane=%@", String(describing: previousPane.id))
      clearFocusBorder(previousPane)
      hideHeaderForPane(previousPane)
    }

    focusedColumnIndex = columnIndex
    column.focusedPaneIndex = paneIndex

    let pane = column.panes[paneIndex]
    NSLog("[e05/ws] setFocus applying pane=%@ addr=%@", String(describing: pane.id), pane.address.description)
    applyFocusBorder(pane)
    if pane.isBlankBrowser {
      if !pane.isURLBarVisible {
        pane.setURLBarVisible(true)
      }
      pane.urlBar.focusURLField()
    } else {
      let result = view.window?.makeFirstResponder(pane.preferredFirstResponder) ?? false
      NSLog(
        "[e05/ws] setFocus makeFirstResponder result=%@ actualFirstResponder=%@",
        result ? "true" : "false",
        String(describing: view.window?.firstResponder))
    }
    updateHandleActiveStates()
    showHeaderForFocusedPane()
    if scroll {
      scrollToColumn(at: columnIndex)
    }
    // Funnel point for sidebar refresh: every pane/column/workspace
    // mutation (addColumn, removePane, splitVertical, switchWorkspace,
    // createWorkspace, closeCurrentWorkspace, movePane, moveColumn*,
    // movePane*, undoClosePane) eventually calls setFocus, so hooking
    // here covers them all without sprinkling notify calls.
    notifySidebarWorklaneDidChange()
  }

  public func focusLeft() {
    guard focusedColumnIndex > 0 else { return }
    let newColIndex = focusedColumnIndex - 1
    let paneIndex = columns[newColIndex].focusedPaneIndex
    setFocus(columnIndex: newColIndex, paneIndex: paneIndex)
  }

  public func focusRight() {
    guard focusedColumnIndex < columns.count - 1 else { return }
    let newColIndex = focusedColumnIndex + 1
    let paneIndex = columns[newColIndex].focusedPaneIndex
    setFocus(columnIndex: newColIndex, paneIndex: paneIndex)
  }

  public func focusUp() {
    guard let column = columns[safe: focusedColumnIndex],
      column.focusedPaneIndex > 0
    else { return }
    setFocus(columnIndex: focusedColumnIndex, paneIndex: column.focusedPaneIndex - 1)
  }

  public func focusDown() {
    guard let column = columns[safe: focusedColumnIndex],
      column.focusedPaneIndex < column.panes.count - 1
    else { return }
    setFocus(columnIndex: focusedColumnIndex, paneIndex: column.focusedPaneIndex + 1)
  }

  // MARK: - Width Preset Cycle

  /// Cycle the focused column's width through the given preset list.
  public func cycleWidthPreset(_ cycle: [PaneWidthPreset]) {
    guard !cycle.isEmpty, let column = columns[safe: focusedColumnIndex] else { return }

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
    view.layoutSubtreeIfNeeded()
    scrollToColumn(at: focusedColumnIndex)
  }

  private func applyPreset(_ preset: PaneWidthPreset, to column: ColumnModel) {
    guard let constraint = column.widthConstraint else { return }
    switch preset {
    case .columns(let n):
      guard let pane = column.focusedPane,
        let surface = pane.terminalView?.surface,
        let scale = pane.terminalView?.window?.backingScaleFactor
      else { return }
      let size = ghostty_surface_size(surface)
      guard size.cell_width_px > 0 else { return }
      constraint.constant = CGFloat(n) * CGFloat(size.cell_width_px) / scale
    case .fraction(let f):
      let visibleWidth = scrollView.contentView.bounds.width
      guard visibleWidth > 0 else { return }
      constraint.constant = visibleWidth * f
    }
  }

  // MARK: - Column Reorder

  public func moveColumnLeft() {
    guard focusedColumnIndex > 0 else { return }
    let moved = columns[focusedColumnIndex]
    let displaced = columns[focusedColumnIndex - 1]
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
  }

  public func moveColumnRight() {
    guard focusedColumnIndex < columns.count - 1 else { return }
    let moved = columns[focusedColumnIndex]
    let displaced = columns[focusedColumnIndex + 1]
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
    let cols = vc.workspace.columns
    for v in sv.arrangedSubviews.reversed() {
      sv.removeArrangedSubview(v)
      if v is PaneResizeHandle { v.removeFromSuperview() }
    }
    for (i, column) in cols.enumerated() {
      if i > 0 {
        let handle = makeColumnResizeHandle(leftColumn: cols[i - 1], rightColumn: column)
        sv.addArrangedSubview(handle)
        NSLayoutConstraint.activate(PaneResizeHandle.makeConstraints(for: handle))
      }
      sv.addArrangedSubview(column.containerView)
    }
    // Add a trailing resize handle on the last column so single-pane layouts can be resized
    if let lastColumn = cols.last {
      let handle = makeTrailingResizeHandle(column: lastColumn)
      sv.addArrangedSubview(handle)
      NSLayoutConstraint.activate(PaneResizeHandle.makeConstraints(for: handle))
    }
  }

  private func makeTrailingResizeHandle(column: ColumnModel) -> PaneResizeHandle {
    let handle = PaneResizeHandle(orientation: .horizontal)
    // Active state is managed by updateHandleActiveStates (left-side neighbor === focused column).
    // mouseDown blocks drag when !isActive, so onDrag doesn't need to re-check focus.
    handle.onDrag = { [weak self, weak column] deltaX in
      guard let self, let column, let constraint = column.widthConstraint else { return }
      let newWidth = max(self.minPaneWidth, constraint.constant + deltaX)
      constraint.constant = newWidth
      column.currentPreset = nil
    }
    return handle
  }

  private func makeColumnResizeHandle(leftColumn: ColumnModel, rightColumn: ColumnModel) -> PaneResizeHandle {
    let handle = PaneResizeHandle(orientation: .horizontal)
    handle.onDrag = { [weak self, weak leftColumn, weak rightColumn] deltaX in
      guard let self, let leftColumn, let rightColumn else { return }
      let isLeftFocused = leftColumn.id == self.columns[safe: self.focusedColumnIndex]?.id
      let isRightFocused = rightColumn.id == self.columns[safe: self.focusedColumnIndex]?.id
      guard isLeftFocused || isRightFocused else { return }
      let focusedColumn = isLeftFocused ? leftColumn : rightColumn
      guard let constraint = focusedColumn.widthConstraint else { return }
      let sign: CGFloat = isLeftFocused ? 1 : -1
      let newWidth = max(self.minPaneWidth, constraint.constant + deltaX * sign)
      let actualDelta = newWidth - constraint.constant
      constraint.constant = newWidth
      focusedColumn.currentPreset = nil
      if isRightFocused, actualDelta != 0 {
        var origin = self.scrollView.contentView.bounds.origin
        origin.x += actualDelta
        self.scrollView.contentView.setBoundsOrigin(origin)
      }
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
  }

  private func makeVerticalResizeHandle(column: ColumnModel, topIndex: Int, bottomIndex: Int) -> PaneResizeHandle {
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
      guard newTopHeight >= self.minPaneHeight, newBottomHeight >= self.minPaneHeight else { return }

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
          ? newTopHeight : (column.panes[0].id == bottomPane.id) ? newBottomHeight : firstCV.frame.height
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

  /// Update which resize handles are active based on focused column.
  func updateHandleActiveStates() {
    guard let focusedColumn = columns[safe: focusedColumnIndex] else { return }
    for v in stackView.arrangedSubviews {
      guard let handle = v as? PaneResizeHandle else { continue }
      guard let handleIndex = stackView.arrangedSubviews.firstIndex(of: handle) else { continue }
      let leftView = stackView.arrangedSubviews[safe: handleIndex - 1]
      let rightView = stackView.arrangedSubviews[safe: handleIndex + 1]
      handle.isActive =
        leftView === focusedColumn.containerView
        || rightView === focusedColumn.containerView
    }
  }

  // MARK: - Focus Indicator

  func applyFocusBorder(_ pane: PaneModel) {
    let cv = pane.containerView
    cv.wantsLayer = true
    cv.layer?.borderWidth = focusBorderWidth
    cv.layer?.borderColor = focusBorderColor.cgColor
    NSLog(
      "[e05/ws] applyFocusBorder paneId=%@ layerExists=%@ borderWidth=%f",
      String(describing: pane.id),
      cv.layer == nil ? "no" : "yes",
      cv.layer?.borderWidth ?? -1)

    if let column = columns.first(where: { $0.panes.contains(where: { $0.id == pane.id }) }),
      column.isFolded
    {
      column.foldedLabelView.wantsLayer = true
      column.foldedLabelView.layer?.borderWidth = focusBorderWidth
      column.foldedLabelView.layer?.borderColor = focusBorderColor.cgColor
    }
  }

  func clearFocusBorder(_ pane: PaneModel) {
    let cv = pane.containerView
    let hadBorder = (cv.layer?.borderWidth ?? 0) > 0
    cv.layer?.borderWidth = 0
    cv.layer?.borderColor = nil
    if hadBorder {
      NSLog("[e05/ws] clearFocusBorder paneId=%@ (had border)", String(describing: pane.id))
    }

    if let column = columns.first(where: { $0.panes.contains(where: { $0.id == pane.id }) }) {
      column.foldedLabelView.layer?.borderWidth = 0
      column.foldedLabelView.layer?.borderColor = nil
    }
  }

  // MARK: - Scrolling

  func scrollToColumn(at index: Int) {
    guard let column = columns[safe: index] else { return }
    let targetView = column.containerView

    view.layoutSubtreeIfNeeded()

    let columnFrame = targetView.frame
    let visibleWidth = scrollView.contentView.bounds.width
    let contentWidth = stackView.frame.width

    if contentWidth <= visibleWidth { return }

    let targetX: CGFloat
    if columnFrame.width >= visibleWidth {
      targetX = columnFrame.minX
    } else {
      targetX = columnFrame.midX - visibleWidth / 2
    }

    let maxScrollX = contentWidth - visibleWidth
    let clampedX = max(0, min(maxScrollX, targetX))

    // Defer the animator call so it lands on a fresh run-loop tick.
    // Mouse-event-driven paths (direct pane click, sidebar row click)
    // call scrollToColumn from inside `NSView.mouseDown(with:)`; an
    // NSAnimationContext opened there collapses to an instantaneous
    // transition because AppKit flushes layout within the same event
    // dispatch. Deferring to main-async lets the mouse event return
    // first, then the animator produces a visible ease-out.
    //
    // Command-palette path already runs outside mouseDown so the
    // ~0ms defer is a no-op for it; no regression there.
    //
    // Overlapping calls (rapid-fire clicks) are resolved by
    // CoreAnimation animator reuse — writing the same property from
    // a new animator cancels the previous one, producing a smooth
    // re-target instead of a frame jump. No explicit coalescing needed.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        self.scrollView.contentView.animator().bounds.origin.x = clampedX
      }
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
    NSLog(
      "[e05/ws] handleFocusChange paneId=%@ addr=%@",
      String(describing: pane.id), pane.address.description)
    // O(1) short-circuit: already the focused pane → nothing to do.
    // Any other case falls through to focusPane, which handles both
    // same-WS and cross-WS cases (and its own reentrancy guard).
    if focusedPane?.id == pane.id {
      NSLog("[e05/ws] handleFocusChange guard: already focused")
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
      NSLog("[e05/ws] focusPane skipped: workspace switch animation in flight")
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
