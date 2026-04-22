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

    // Width constraint on the containerView
    let wc = column.containerView.widthAnchor.constraint(equalToConstant: defaultPaneWidth)
    wc.isActive = true
    column.widthConstraint = wc

    let insertIndex = columns.isEmpty ? 0 : focusedColumnIndex + 1
    columns.insert(column, at: insertIndex)

    rebuildStackView()
    view.layoutSubtreeIfNeeded()
    setFocus(columnIndex: insertIndex, paneIndex: 0)
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

    rebuildColumnView(column: column)
    view.layoutSubtreeIfNeeded()
    setFocus(columnIndex: focusedColumnIndex, paneIndex: insertPaneIndex)
  }

  // MARK: - Pane Removal

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
      // Remove column
      columns.remove(at: columnIndex)
      column.containerView.removeFromSuperview()

      if columns.isEmpty {
        // Workspace is now empty — its surface is going with it, so
        // release it eagerly (undo across workspace close isn't
        // supported: closeCurrentWorkspace flushes the undo stack).
        pane.terminalView?.keepSurfaceAlive = false
        for v in stackView.arrangedSubviews { v.removeFromSuperview() }
        closeCurrentWorkspace()
        return
      }

      rebuildStackView()
      let newColIndex = min(columnIndex, columns.count - 1)
      setFocus(columnIndex: newColIndex, paneIndex: 0)
    } else {
      pane.containerView.removeFromSuperview()
      rebuildColumnView(column: column)
      let newPaneIndex = min(paneIndex, column.panes.count - 1)
      setFocus(columnIndex: columnIndex, paneIndex: newPaneIndex)
    }

    stashClosedPane(
      pane, columnIndex: columnIndex, paneIndex: paneIndex,
      columnWidth: columnWidth, wasOnlyPaneInColumn: wasOnlyPane)
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

      let wc = column.containerView.widthAnchor.constraint(
        equalToConstant: closed.columnWidth ?? defaultPaneWidth
      )
      wc.isActive = true
      column.widthConstraint = wc

      let insertIndex = min(closed.columnIndex, columns.count)
      columns.insert(column, at: insertIndex)
      rebuildStackView()
      view.layoutSubtreeIfNeeded()
      setFocus(columnIndex: insertIndex, paneIndex: 0)
    } else {
      // Insert back into existing column
      guard !columns.isEmpty else { return }
      let colIndex = min(closed.columnIndex, columns.count - 1)
      guard let column = columns[safe: colIndex] else { return }

      let paneIndex = min(closed.paneIndex, column.panes.count)
      setupPaneCallbacks(pane: pane, column: column)
      column.panes.insert(pane, at: paneIndex)
      rebuildColumnView(column: column)
      view.layoutSubtreeIfNeeded()
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
