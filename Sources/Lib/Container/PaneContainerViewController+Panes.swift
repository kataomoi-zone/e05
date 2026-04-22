import AppKit
import GhosttyKit

extension PaneContainerViewController {
  // MARK: - Column Management

  @discardableResult
  public func addColumn(address: PaneAddress = .terminal) -> ColumnModel {
    insertColumn(with: makePane(address: address))
  }

  @discardableResult
  func insertColumn(with pane: PaneModel) -> ColumnModel {
    let column = ColumnModel(pane: pane)

    setupPaneCallbacks(pane: pane, column: column)

    let cv = pane.containerView

    // Add pane's containerView to column's containerView
    column.containerView.addArrangedSubview(cv)
    NSLayoutConstraint.activate([
      cv.leadingAnchor.constraint(equalTo: column.containerView.leadingAnchor),
      cv.trailingAnchor.constraint(equalTo: column.containerView.trailingAnchor),
    ])

    // Folded label overlay — shown only when column is folded
    attachFoldedLabel(to: column)

    // Session restore runs before the window is attached and would
    // flash every restored column through the animation; the guard
    // keeps that path immediate.
    let animated = view.window != nil
    // Start the column at its target width so the post-insert
    // layout pass below resolves the final frame. `animateScroll(toX:)`
    // reads that frame to compute the scroll target; launching the
    // scroll from a width-0 start would land on the wrong X.
    let wc = column.containerView.widthAnchor.constraint(
      equalToConstant: defaultPaneWidth
    )
    wc.isActive = true
    column.widthConstraint = wc

    if animated {
      // Hide the new column's contents while the slot expands so
      // its WKWebView / ghostty surface doesn't render at every
      // intermediate width — that in-between layout looked
      // garbled. The completion handler snaps it visible once
      // the slot is at full width.
      column.containerView.wantsLayer = true
      column.containerView.alphaValue = 0
    }

    let insertIndex = columns.isEmpty ? 0 : focusedColumnIndex + 1
    columns.insert(column, at: insertIndex)

    rebuildStackView()
    view.layoutSubtreeIfNeeded()

    // Capture the scroll target while the layout still reflects
    // the final column width. Snapping to width 0 below would
    // leave `column.containerView.frame.minX` pointing into the
    // wrong neighbourhood and the scroll would aim at a 1-pixel
    // sliver instead of the full column.
    let scrollTarget = animated ? computeScrollTargetX(for: column) : nil

    if animated {
      // Now that the target frame is known, snap the column back
      // to width 0 as the animation start state.
      wc.constant = 0
      view.layoutSubtreeIfNeeded()
    }

    animatePaneLayoutChange(
      completion: animated ? { [column] in column.containerView.alphaValue = 1 } : nil
    ) {
      wc.animator().constant = defaultPaneWidth
    }
    if let scrollTarget {
      animateScroll(toX: scrollTarget)
    }

    // The animation already owns the scroll — tell setFocus to
    // leave it alone so scrollToColumn doesn't fire a second
    // tween after the insert's completion handler.
    setFocus(columnIndex: insertIndex, paneIndex: 0, scroll: false)
    return column
  }

  /// Attach the folded label overlay to a column's containerView with full-bounds
  /// constraints and wire up click callbacks. Called on column creation (both via
  /// `insertColumn(with:)` and `undoClosePane` for restored single-pane columns).
  func attachFoldedLabel(to column: ColumnModel) {
    column.containerView.addSubview(column.foldedLabelView)
    NSLayoutConstraint.activate([
      column.foldedLabelView.topAnchor.constraint(equalTo: column.containerView.topAnchor),
      column.foldedLabelView.leadingAnchor.constraint(equalTo: column.containerView.leadingAnchor),
      column.foldedLabelView.trailingAnchor.constraint(equalTo: column.containerView.trailingAnchor),
      column.foldedLabelView.bottomAnchor.constraint(equalTo: column.containerView.bottomAnchor),
    ])

    // Clicking the folded strip focuses the column; expand button unfolds it.
    column.foldedLabelView.onClicked = { [weak self, weak column] in
      guard let self, let column, let pane = column.focusedPane else { return }
      self.handleFocusChange(from: pane)
    }
    column.foldedLabelView.onExpandClicked = { [weak self, weak column] in
      guard let self, let column else { return }
      // Focus the column first, then toggle fold
      if let pane = column.focusedPane {
        self.handleFocusChange(from: pane)
      }
      self.toggleFold()
    }
  }

  func setupPaneCallbacks(pane: PaneModel, column: ColumnModel) {
    if let tv = pane.terminalView {
      tv.onFocusChanged = { [weak self, weak pane] focused in
        guard let self, let pane, focused else { return }
        self.handleFocusChange(from: pane)
      }

      tv.onTitleChange = { [weak self, weak pane] title in
        guard let self, let pane else { return }
        self.handleTitleChange(pane: pane, title: title)
      }

      tv.onClose = { [weak self, weak pane] in
        guard let self, let pane else { return }
        // TODO(cross-workspace cleanup): scans the current
        // workspace only. `removePane` assumes current-WS state
        // (columns[safe:], stackView, closeCurrentWorkspace,
        // setFocus). A terminal exiting in a non-current workspace
        // leaves a dead pane until the user switches to that WS
        // and closes it manually. Full fix requires a
        // `removePane(in:workspace:)` variant — see commit c90565f.
        for (colIdx, col) in self.columns.enumerated() {
          if let paneIdx = col.panes.firstIndex(where: { $0.id == pane.id }) {
            self.removePane(columnIndex: colIdx, paneIndex: paneIdx)
            return
          }
        }
      }
    }

    if let bv = pane.browserView {
      bv.onTitleChange = { [weak self, weak pane] title in
        guard let self, let pane else { return }
        // Route through the shared handler so browser title changes
        // flow into the same sidebar-reload + header-overlay + window-
        // title pipeline the terminal path uses; without this the
        // sidebar worklane only refreshed on the next `setFocus`.
        self.handleTitleChange(pane: pane, title: title)
        // Update history title for the current URL.
        self.browsingHistory.updateTitle(url: pane.address.url.absoluteString, title: title)
      }
      bv.onURLChange = { [weak self, weak pane] url in
        guard let url else { return }
        let urlString = url.absoluteString
        pane?.address = PaneAddress(url)
        pane?.urlBar.setDisplayURL(urlString)
        // Record visit (skips internal pages and duplicates)
        if url.scheme == "https" || url.scheme == "http" {
          self?.browsingHistory.recordVisit(url: urlString, title: pane?.title ?? "")
        }
      }
      bv.onFocusChanged = { [weak self, weak pane] in
        guard let self, let pane else { return }
        self.handleFocusChange(from: pane)
      }
      bv.onNavigationStateChange = { [weak pane] canGoBack, canGoForward in
        pane?.urlBar.setNavigationEnabled(back: canGoBack, forward: canGoForward)
      }
      bv.onLoadingStateChange = { [weak pane] isLoading in
        pane?.urlBar.setReloadButtonLoading(isLoading)
      }
      bv.onDownloadStarted = { [weak self] wkDownload in
        self?.downloadsManager.adopt(wkDownload)
      }
    } else {
      // Terminal/other panes: navigation buttons always disabled
      pane.urlBar.setNavigationEnabled(back: false, forward: false)
      // Mirror the non-browser case for reload too so the button
      // visibly dims instead of advertising a click that routes
      // to a nil `browserView?.webView` and silently no-ops.
      pane.urlBar.setReloadEnabled(false)
    }

    // URL bar: navigate callback
    pane.urlBar.onNavigate = { [weak self, weak pane] input in
      guard let self, let pane else { return }
      self.handleURLBarNavigate(pane: pane, input: input)
    }

    // URL bar: ESC returns focus to pane content
    pane.urlBar.onCancel = { [weak pane] in
      guard let pane else { return }
      pane.containerView.window?.makeFirstResponder(pane.preferredFirstResponder)
    }

    // URL bar: back/forward/reload for browser panes
    pane.urlBar.onBack = { [weak pane] in
      pane?.browserView?.webView.goBack()
    }
    pane.urlBar.onForward = { [weak pane] in
      pane?.browserView?.webView.goForward()
    }
    pane.urlBar.onReload = { [weak pane] in
      pane?.browserView?.webView.reload()
    }
    pane.urlBar.onStop = { [weak pane] in
      pane?.browserView?.webView.stopLoading()
    }

    // URL bar: inline zoom indicator controls. Route through the
    // container helpers so the inline buttons, the command-palette
    // actions, and any future toolbar / pinch-gesture entry point
    // all flow through the same clamped path and share the same
    // urlBar refresh logic.
    pane.urlBar.onZoomIn = { [weak self] in self?.zoomInFocusedBrowser() }
    pane.urlBar.onZoomOut = { [weak self] in self?.zoomOutFocusedBrowser() }
    pane.urlBar.onZoomReset = { [weak self] in self?.resetFocusedBrowserZoom() }

    // URL bar: clicking moves focus to this pane
    pane.urlBar.onClicked = { [weak self, weak pane] in
      guard let self, let pane else { return }
      self.handleFocusChange(from: pane)
    }

    // URL bar: fold button triggers column fold
    // Focus the pane first so toggleFold always targets the clicked pane's
    // column, independent of urlBar callback ordering with onClicked.
    pane.urlBar.onFold = { [weak self, weak pane] in
      guard let self, let pane else { return }
      self.handleFocusChange(from: pane)
      self.toggleFold()
    }

    // URL bar: fuzzy find suggestions from history + bookmarks
    pane.urlBar.onTextChanged = { [weak self] query in
      guard let self, !query.isEmpty else { return [] }
      return self.searchSuggestions(query: query)
    }

    // Sync URL bar visibility with global state
    pane.setURLBarVisible(urlBarVisible)
  }

  // MARK: - Command Palette

  /// Wire up command palette callbacks. Called once from `viewDidLoad`
  /// (not per-toggle) because the palette is a long-lived `let` property.
  func setupCommandPalette() {
    commandPalette.onSearch = { [weak self] query in
      self?.searchActions(query: query) ?? []
    }
    commandPalette.onExecute = { [weak self] index in
      guard let self, self.cachedActionResults.indices.contains(index) else { return }
      self.cachedActionResults[index].handler()
    }
    commandPalette.onDismiss = { [weak self] in
      self?.focusCurrentPane()
    }
  }

  /// Toggle the global command palette overlay.
  public func toggleCommandPalette() {
    guard let window = view.window else { return }
    if !commandPalette.isVisible {
      // Snapshot the action list once per show — it won't change
      // while the palette is open.
      cachedAllActions = actions()
    }
    commandPalette.toggle(in: window)
  }

  /// Re-focus the currently active pane's content view.
  ///
  /// Routed through `setFocus` rather than a direct
  /// `makeFirstResponder` so palette dismissal flows through the same
  /// clear-then-arm cascade that split and arrow-key focus hops use.
  /// A bare `makeFirstResponder` on the already-focused pane is a
  /// no-op from AppKit's perspective, so the ghostty surface kept
  /// whatever focus flag the dismissal handoff had put it in — in
  /// particular, a cross-pane `Focus: <other>` palette action left
  /// the outgoing pane's surface with `ghostty_surface_set_focus(true)`
  /// because `becomeFirstResponder` never re-fired to re-arm the
  /// guard. Re-entering `setFocus` here clears every surface in the
  /// focused workspace and re-arms exactly one.
  func focusCurrentPane() {
    guard columns.indices.contains(focusedColumnIndex) else { return }
    let column = columns[focusedColumnIndex]
    guard column.panes.indices.contains(column.focusedPaneIndex) else { return }
    setFocus(columnIndex: focusedColumnIndex, paneIndex: column.focusedPaneIndex, scroll: false)
  }

  /// Search the action registry for the command palette.
  /// Returns `SuggestionCellModel` values for display; the matched
  /// `Action` objects are cached in `cachedActionResults` for execution.
  func searchActions(query: String) -> [SuggestionCellModel] {
    let matched: [Action]
    if query.isEmpty {
      matched = cachedAllActions
    } else {
      matched = FuzzyMatcher.rank(
        query: query,
        items: cachedAllActions,
        keys: { [$0.title, $0.id] }
      ).map(\.item)
    }
    cachedActionResults = matched
    return matched.map { action in
      SuggestionCellModel(
        primary: action.title,
        secondary: "",
        accessory: action.keyLabel
      )
    }
  }

  // MARK: - Vertical Split

  public func splitVertical() {
    guard let column = columns[safe: focusedColumnIndex] else { return }

    let newPane = makePane(address: .terminal)
    setupPaneCallbacks(pane: newPane, column: column)

    let insertPaneIndex = column.focusedPaneIndex + 1
    column.panes.insert(newPane, at: insertPaneIndex)

    let animated = view.window != nil
    if animated {
      newPane.containerView.wantsLayer = true
      newPane.containerView.alphaValue = 0
    }

    // Snap the layout into its new shape synchronously —
    // tweening the stack-view reshuffle under implicit animation
    // slid the existing pane's `frame.origin.y` mid-animation
    // (Cocoa stack views manage arranged subviews in a bottom-
    // anchored coordinate system), which pushed its URL bar off
    // the visible top before the final frame settled. Keeping
    // the snap and animating only the new pane's alpha avoids
    // that flicker at the cost of the sibling-shrink tween.
    rebuildColumnView(column: column)
    view.layoutSubtreeIfNeeded()

    if animated {
      animateAlphaIn(newPane.containerView)
    }

    setFocus(columnIndex: focusedColumnIndex, paneIndex: insertPaneIndex)
  }

  // MARK: - Pane Removal

  /// Duration used by pane close / insert animations. Matches the
  /// sidebar slide so the two affordances feel synchronised.
  static let paneAnimationDuration: TimeInterval = 0.2

  /// Run `mutation` inside a shared animation group tuned for pane
  /// layout transitions — `allowsImplicitAnimation = true` so the
  /// stack view's layout pass tweens frame changes from
  /// `mutation`'s constraint / view edits. Falls through to a
  /// direct call when the view isn't on screen yet so session
  /// restore (which mutates layout before the window is attached)
  /// doesn't spawn a flurry of start-up animations. `completion`
  /// fires on the main actor once the animation settles.
  func animatePaneLayoutChange(
    completion: (@MainActor @Sendable () -> Void)? = nil,
    _ mutation: () -> Void
  ) {
    guard view.window != nil else {
      mutation()
      completion?()
      return
    }
    NSAnimationContext.runAnimationGroup(
      { ctx in
        ctx.duration = Self.paneAnimationDuration
        ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ctx.allowsImplicitAnimation = true
        mutation()
        view.layoutSubtreeIfNeeded()
      },
      completionHandler: {
        MainActor.assumeIsolated {
          completion?()
        }
      }
    )
  }

  /// Compute where the scroll view should land so `column` is
  /// visible. Call with the layout already settled at the column's
  /// final width — reading the frame during the insert tween would
  /// capture an intermediate width and target the wrong X. Returns
  /// `nil` when the whole content already fits.
  func computeScrollTargetX(for column: ColumnModel) -> CGFloat? {
    let columnFrame = column.containerView.frame
    let visibleWidth = scrollView.contentView.bounds.width
    let contentWidth = stackView.frame.width
    guard contentWidth > visibleWidth else { return nil }

    let targetX: CGFloat
    if columnFrame.width >= visibleWidth {
      targetX = columnFrame.minX
    } else {
      targetX = columnFrame.midX - visibleWidth / 2
    }
    let maxScrollX = contentWidth - visibleWidth
    return max(0, min(maxScrollX, targetX))
  }

  /// Tween the scroll view to the given X in its own animation
  /// group, matching `paneAnimationDuration` so the scroll runs
  /// in visual lockstep with a concurrent insert / expand layout
  /// animation. Distinct from `scrollToColumn(at:)` on
  /// `PaneContainerViewController+Focus`, which serves focus-
  /// driven scrolls at a different duration (0.25s) and defers
  /// onto the next run-loop tick to survive mouse-event paths.
  /// Must stay isolated from the insert's layout animation —
  /// NSScrollView's `animator().bounds.origin` is silently
  /// dropped when it shares a context with other implicit
  /// animations.
  func animateScroll(toX targetX: CGFloat) {
    guard view.window != nil else { return }
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = Self.paneAnimationDuration
      ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      self.scrollView.contentView.animator().bounds.origin.x = targetX
    }
  }

  /// Fade `view.alphaValue` from its current value to 1 in its own
  /// animation group. Intended for inserts that pre-hide a new /
  /// restored view at alpha 0 while the surrounding layout snaps
  /// into its final shape — the fade is what sells the "new pane
  /// arrived" beat. Skips straight to alpha 1 when off-screen so
  /// session restore doesn't flash a tween.
  func animateAlphaIn(_ view: NSView) {
    guard self.view.window != nil else {
      view.alphaValue = 1
      return
    }
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = Self.paneAnimationDuration
      ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      view.animator().alphaValue = 1
    }
  }

  func removePane(columnIndex: Int, paneIndex: Int) {
    guard let column = columns[safe: columnIndex],
      column.panes.indices.contains(paneIndex)
    else { return }

    let pane = column.panes.remove(at: paneIndex)
    clearFocusBorder(pane)

    let wasOnlyPane = column.panes.isEmpty
    let columnWidth = column.widthConstraint?.constant

    // Preserve surface BEFORE removing from view hierarchy
    pane.terminalView?.keepSurfaceAlive = true

    if wasOnlyPane {
      animateRemoveColumn(column, at: columnIndex, pane: pane)
    } else {
      animateRemovePaneFromColumn(
        column, at: columnIndex, paneIndex: paneIndex, pane: pane)
    }

    // Queue the undo stash right away rather than waiting for the
    // close animation to finish — users can undo during the 0.2s
    // slide without the entry being missed.
    stashClosedPane(
      pane, columnIndex: columnIndex, paneIndex: paneIndex,
      columnWidth: columnWidth, wasOnlyPaneInColumn: wasOnlyPane)
  }

  /// Remove the column immediately but tween the remaining columns
  /// into the vacated slot. The closing view disappears in a single
  /// frame (so terminal / browser drawables never re-initialise);
  /// `allowsImplicitAnimation = true` wraps the stack view's layout
  /// pass so every surviving column's frame animates from its old
  /// position to the new one computed by `rebuildStackView`. Follows
  /// the same idiom as `animateSlide` in
  /// ``PaneContainerViewController+Workspaces``.
  private func animateRemoveColumn(_ column: ColumnModel, at columnIndex: Int, pane: PaneModel) {
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = Self.paneAnimationDuration
      ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      ctx.allowsImplicitAnimation = true

      columns.remove(at: columnIndex)
      column.containerView.removeFromSuperview()

      if columns.isEmpty {
        // Workspace is now empty — its surface is going with it,
        // so release it eagerly (undo across workspace close isn't
        // supported: closeCurrentWorkspace flushes the undo stack).
        pane.terminalView?.keepSurfaceAlive = false
        for v in stackView.arrangedSubviews { v.removeFromSuperview() }
        closeCurrentWorkspace()
        return
      }

      rebuildStackView()
      view.layoutSubtreeIfNeeded()
    }

    if !columns.isEmpty {
      // Focus move is deliberately outside the animation group:
      // `setFocus` invokes `scrollToColumn`, which runs its own
      // animation context, and letting the two overlap produces
      // a jittery scroll + slide mix.
      let newColIndex = min(columnIndex, columns.count - 1)
      setFocus(columnIndex: newColIndex, paneIndex: 0)
    }
  }

  /// Column-internal removal: detach the leaving pane and snap
  /// the siblings into their new equal-height share. The reshuffle
  /// runs outside any animation context — tweening the vertical
  /// stack view's layout under `allowsImplicitAnimation` made the
  /// surviving pane's `frame.origin.y` slide toward the closed
  /// slot before the height settled, which read as a jarring
  /// "pane shifts into the closing one" jolt. The counterpart
  /// `splitVertical` path uses the same snap discipline.
  private func animateRemovePaneFromColumn(
    _ column: ColumnModel, at columnIndex: Int, paneIndex: Int, pane: PaneModel
  ) {
    pane.containerView.removeFromSuperview()
    rebuildColumnView(column: column)
    view.layoutSubtreeIfNeeded()

    let newPaneIndex = min(paneIndex, column.panes.count - 1)
    setFocus(columnIndex: columnIndex, paneIndex: newPaneIndex)
  }

  private static let maxRecentlyClosed = 10

  private func stashClosedPane(
    _ pane: PaneModel, columnIndex: Int, paneIndex: Int,
    columnWidth: CGFloat?, wasOnlyPaneInColumn: Bool
  ) {
    // Evict oldest if at capacity — must explicitly release detached surfaces
    while recentlyClosed.count >= Self.maxRecentlyClosed {
      let evicted = recentlyClosed.removeFirst()
      evicted.timer.invalidate()
      evicted.pane.terminalView?.releaseDetachedSurface()
    }

    // keepSurfaceAlive is already set by removePane before removeFromSuperview.
    // Browser panes don't need keepSurfaceAlive — WKWebView survives detachment.

    let paneId = pane.id
    let timer = Timer.scheduledTimer(withTimeInterval: Self.undoTimeout, repeats: false) {
      [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if let idx = self.recentlyClosed.firstIndex(where: { $0.pane.id == paneId }) {
          let expired = self.recentlyClosed.remove(at: idx)
          expired.pane.terminalView?.releaseDetachedSurface()
        }
      }
    }
    let closed = ClosedPane(
      pane: pane, workspaceId: currentWorkspace.id,
      columnIndex: columnIndex, paneIndex: paneIndex,
      columnWidth: columnWidth, wasOnlyPaneInColumn: wasOnlyPaneInColumn, timer: timer
    )
    recentlyClosed.append(closed)
  }

  /// Whether the current workspace has any recently closed panes available
  /// for undo. Stash entries belonging to other workspaces are invisible
  /// here — undo is intentionally scoped per-workspace.
  public var canUndoClosePane: Bool {
    recentlyClosed.contains { $0.workspaceId == currentWorkspace.id }
  }

  /// Restore the most recently closed pane in the current workspace.
  /// Surface is still alive — full restore. No-op if all stash entries
  /// belong to other workspaces.
  public func undoClosePane() {
    guard let idx = recentlyClosed.lastIndex(where: { $0.workspaceId == currentWorkspace.id })
    else { return }
    let closed = recentlyClosed.remove(at: idx)
    closed.timer.invalidate()

    let pane = closed.pane
    // Re-enable normal surface lifecycle now that the view is re-entering the hierarchy
    pane.terminalView?.keepSurfaceAlive = false

    if closed.wasOnlyPaneInColumn {
      // Re-create a column for this pane
      let column = ColumnModel(pane: pane)
      setupPaneCallbacks(pane: pane, column: column)

      let cv = pane.containerView
      column.containerView.addArrangedSubview(cv)
      NSLayoutConstraint.activate([
        cv.leadingAnchor.constraint(equalTo: column.containerView.leadingAnchor),
        cv.trailingAnchor.constraint(equalTo: column.containerView.trailingAnchor),
      ])

      // Folded label overlay — same setup as insertColumn(with:)
      attachFoldedLabel(to: column)

      let targetWidth = closed.columnWidth ?? defaultPaneWidth
      let animated = view.window != nil
      // Start at the saved width so the layout pass below can
      // resolve the final frame for `animateScroll(toX:)`.
      let wc = column.containerView.widthAnchor.constraint(
        equalToConstant: targetWidth
      )
      wc.isActive = true
      column.widthConstraint = wc

      if animated {
        // Hide the restored column's contents through the width
        // tween, matching `insertColumn` — the in-between widths
        // would otherwise re-layout the web view / terminal at
        // every frame.
        column.containerView.wantsLayer = true
        column.containerView.alphaValue = 0
      }

      let insertIndex = min(closed.columnIndex, columns.count)
      // `Array.insert(at:)` shifts every element from `insertIndex`
      // onwards by one but leaves the stored `focusedColumnIndex`
      // untouched. Without this bump, `focusedColumnIndex` now
      // resolves to the freshly inserted column, so `setFocus`'s
      // clear-previous step clears the wrong pane's border and the
      // real previously focused column keeps its border lit.
      if insertIndex <= focusedColumnIndex {
        focusedColumnIndex += 1
      }
      columns.insert(column, at: insertIndex)
      rebuildStackView()
      view.layoutSubtreeIfNeeded()

      // Capture scroll target while the layout reflects the
      // column's saved width — see the matching comment in
      // `insertColumn` for the 1-pixel-sliver pitfall.
      let scrollTarget = animated ? computeScrollTargetX(for: column) : nil

      if animated {
        // Snap to width 0 for the animation start now that the
        // target frame has been captured into column.containerView.
        wc.constant = 0
        view.layoutSubtreeIfNeeded()
      }

      animatePaneLayoutChange(
        completion: animated ? { [column] in column.containerView.alphaValue = 1 } : nil
      ) {
        wc.animator().constant = targetWidth
      }
      if let scrollTarget {
        animateScroll(toX: scrollTarget)
      }

      setFocus(columnIndex: insertIndex, paneIndex: 0, scroll: false)
    } else {
      // Insert back into existing column
      guard !columns.isEmpty else { return }
      let colIndex = min(closed.columnIndex, columns.count - 1)
      guard let column = columns[safe: colIndex] else { return }

      let paneIndex = min(closed.paneIndex, column.panes.count)
      // Same index-identity preservation as the column branch —
      // otherwise `column.focusedPaneIndex` now points at the
      // newly inserted pane and the previously focused sibling
      // keeps a stale focus border (and a stuck ghostty focus
      // flag) after undo.
      if paneIndex <= column.focusedPaneIndex {
        column.focusedPaneIndex += 1
      }
      setupPaneCallbacks(pane: pane, column: column)
      column.panes.insert(pane, at: paneIndex)

      // Mirror `splitVertical`: snap the layout in place and
      // only tween the restored pane's alpha. Tweening the
      // stack-view reshuffle would otherwise slide the siblings'
      // `frame.origin.y` mid-animation.
      let animated = view.window != nil
      if animated {
        pane.containerView.wantsLayer = true
        pane.containerView.alphaValue = 0
      }

      rebuildColumnView(column: column)
      view.layoutSubtreeIfNeeded()

      if animated {
        animateAlphaIn(pane.containerView)
      }

      setFocus(columnIndex: colIndex, paneIndex: paneIndex)
    }
  }

  /// Close the focused pane. Shows a confirmation dialog if a process is running.
  public func removeCurrentPane() {
    guard let column = columns[safe: focusedColumnIndex],
      let pane = column.focusedPane
    else { return }
    if let surface = pane.terminalView?.surface,
      ghostty_surface_needs_confirm_quit(surface)
    {
      let alert = NSAlert()
      alert.messageText = "Close this pane?"
      alert.informativeText = "A process is still running."
      alert.alertStyle = .warning
      alert.addButton(withTitle: "Close")
      alert.addButton(withTitle: "Cancel")
      guard let window = view.window else { return }
      let targetPaneId = pane.id
      let targetColId = column.id
      alert.beginSheetModal(for: window) { [weak self] response in
        guard response == .alertFirstButtonReturn, let self else { return }
        // Alert is modal so user can't switch workspace while it's
        // showing, but use focusPane-style cross-WS lookup anyway —
        // defensive against programmatic WS switches (e.g. a future
        // sidebar action) that might fire between alert display and
        // confirmation. Falls back to current-WS `removePane` only
        // if the pane is on the focused workspace, since removePane
        // depends on current-WS state (see the cross-workspace
        // cleanup TODO on `onClose`).
        guard let colIdx = self.columns.firstIndex(where: { $0.id == targetColId }),
          let col = self.columns[safe: colIdx],
          let paneIdx = col.panes.firstIndex(where: { $0.id == targetPaneId })
        else {
          NSLog("[e05/ws] close alert: target pane not in current WS")
          return
        }
        self.removePane(columnIndex: colIdx, paneIndex: paneIdx)
      }
      return
    }
    removePane(columnIndex: focusedColumnIndex, paneIndex: column.focusedPaneIndex)
  }
}
