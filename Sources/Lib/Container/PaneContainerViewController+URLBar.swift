import AppKit

extension PaneContainerViewController {
  // MARK: - URL Bar

  /// Search history and bookmarks for URL bar suggestions.
  ///
  /// Collects all bookmarks plus the last 500 history entries, deduplicates
  /// by URL (bookmark wins), and runs the combined pool through
  /// `Suggestion.rank` which uses `FuzzyMatcher` + a bookmark score bonus.
  /// Fuzzy matching replaces the old SQLite `LIKE '%q%'` scan — now
  /// queries like `gite05` can find `github.com/kawarimidoll/e05`.
  ///
  /// Cost: O(B + H × |query| × avg(|url| + |title|)) where B = bookmarks,
  /// H ≤ 500. Runs synchronously on the main thread, acceptable under
  /// `PaneURLBar`'s ~150ms debounce. If the history cap ever grows
  /// meaningfully past 500, hoist this onto a background Task to avoid
  /// main-thread blocking while typing.
  func searchSuggestions(query: String) -> [Suggestion] {
    let bookmarkEntries = bookmarks.all()
    let historyEntries = browsingHistory.mostRecent(limit: 500)
    let bookmarkURLs = Set(bookmarkEntries.map(\.url))

    var candidates: [Suggestion] = bookmarkEntries.map {
      Suggestion(url: $0.url, title: $0.title, isBookmark: true)
    }
    candidates.append(
      contentsOf: historyEntries.compactMap { entry in
        bookmarkURLs.contains(entry.url)
          ? nil
          : Suggestion(url: entry.url, title: entry.title, isBookmark: false)
      })

    var results = Suggestion.rank(query: query, candidates: candidates)

    // Brave-style: when the input itself is a direct-navigable URL
    // (explicit scheme https/http/e05/about, or a bare host/IP
    // that passes PaneAddress.looksLikeHostname), surface an
    // "Open URL" row at the very top. Auto-selecting index 0 then
    // makes Enter open the typed URL instead of deferring to the
    // DuckDuckGo search fallback below. Any existing row with the
    // same URL is removed first so the entry doesn't appear twice
    // when the typed URL is also present in history/bookmarks.
    if let direct = directOpenSuggestion(query: query) {
      results.removeAll { $0.url == direct.url }
      results.insert(direct, at: 0)
    }

    // Insert a search-engine entry so the user can always search even
    // when history/bookmarks match (Brave-style). Placed after the top
    // few strong matches but before weaker tail results.
    if let searchAddr = PaneAddress.searchURL(query: query) {
      let searchEntry = Suggestion(
        url: searchAddr.url.absoluteString,
        title: "\(query) \u{2014} DuckDuckGo Search",
        isBookmark: false
      )
      let insertAt = min(3, results.count)  // after top 3 matches
      results.insert(searchEntry, at: insertAt)
    }

    // Cap total output to the dropdown's visible-row budget.
    // Suggestion.rank already applies its own cap, but the direct
    // and search insertions push the count past it so we re-trim
    // here to keep the list scroll-free.
    if results.count > Self.maxSuggestionRows {
      results = Array(results.prefix(Self.maxSuggestionRows))
    }

    return results
  }

  /// Upper bound on the number of rows shown in the URL bar dropdown.
  /// Kept in sync with `SuggestionListView.maxVisibleRows` so the list
  /// never scrolls.
  static let maxSuggestionRows = 8

  /// Build the optional "Open URL" suggestion shown at the top of the
  /// dropdown when the user typed a direct-navigable URL.
  ///
  /// Direct-navigable covers both explicit-scheme inputs
  /// (`https://…`, `http://…`, `e05://…`, `about:…`) that resolve to
  /// a known `PaneAddress.Kind`, and bare hostnames / IPv4 addresses
  /// that pass `PaneAddress.looksLikeHostname` (2+ alphabetic TLD or
  /// all-digit last label). See `PaneAddress.asDirectNavigation` for
  /// the full heuristic and its Chromium `README.md` quirk.
  ///
  /// Title is the plain role label "Open URL" so the cell matches
  /// the rest of the list (primary = what the row represents,
  /// secondary = URL) instead of embedding the URL twice.
  func directOpenSuggestion(query: String) -> Suggestion? {
    guard let addr = PaneAddress.asDirectNavigation(query) else { return nil }
    return Suggestion(
      url: addr.url.absoluteString,
      title: "Open URL",
      isBookmark: false
    )
  }

  /// Handle URL bar navigation: same-type navigates in place, cross-type switches content.
  func handleURLBarNavigate(pane: PaneModel, input: String) {
    let newAddress: PaneAddress
    if let parsed = PaneAddress.fromUserInput(input) {
      // Accept any parsed URL, including `.unknown`-kind e05 hosts.
      // `PaneModel.init(.unknown)` lands the pane on a blank-browser
      // fallback with a warning log — the same feedback a typed
      // URL would get in a mainstream browser when the destination
      // can't be rendered. Silently rewriting such URLs to a search
      // query would hide the user's stated intent to navigate.
      newAddress = parsed
    } else if let search = PaneAddress.searchURL(query: input) {
      // `fromUserInput` returned nil, so the input doesn't parse
      // as a URL at all (bare word, disallowed scheme, …) — fall
      // through to search like any other free-form query.
      newAddress = search
    } else {
      return
    }

    if pane.address.requiresContentSwitch(to: newAddress) {
      // Cross-type: replace pane content (Step 4-3)
      // For now, create a new column and remove the old pane
      // TODO: in-place content replacement in Step 4-3
      guard let colIdx = columns.firstIndex(where: { $0.panes.contains(where: { $0.id == pane.id }) }) else { return }
      let column = columns[colIdx]
      guard let paneIdx = column.panes.firstIndex(where: { $0.id == pane.id }) else { return }

      let newPane = makePane(address: newAddress)
      newPane.setURLBarVisible(urlBarVisible)
      setupPaneCallbacks(pane: newPane, column: column)

      // Replace in column
      column.panes[paneIdx] = newPane
      rebuildColumnView(column: column)
      view.layoutSubtreeIfNeeded()
      setFocus(columnIndex: colIdx, paneIndex: paneIdx)
    } else {
      // Same type: navigate in place
      // Browser → browser: load new URL. Terminal → terminal: no-op (address update only).
      pane.address = newAddress
      if let bv = pane.browserView {
        bv.navigate(to: newAddress.url.absoluteString)
      }
      view.window?.makeFirstResponder(pane.preferredFirstResponder)
    }
  }

  /// Focus the URL bar of the focused pane (⌘+L).
  public func focusURLBar(prefill: String? = nil) {
    guard let pane = focusedPane else { return }
    // Dismiss the find bar before the URL field takes focus. The two
    // compete for the row directly beneath the pane header; leaving
    // the find overlay up while typing a new URL would stack two
    // text fields on top of the same visual slot.
    closeFindBar()
    if !urlBarVisible {
      toggleURLBarVisibility()
    }
    if let prefill {
      pane.urlBar.setDisplayURL(prefill)
    }
    pane.urlBar.focusURLField()
  }

  /// Toggle URL bar visibility for all panes. When URL bar is shown, header overlay is suppressed.
  public func toggleURLBarVisibility() {
    urlBarVisible.toggle()
    // Apply to panes across ALL workspaces so the setting is consistent
    // after workspace switch. Previously this only touched the current
    // workspace, leaving the URL bar of other workspaces out of sync.
    // `lazy` avoids a materialized intermediate Array on each toggle.
    for pane in workspaces.lazy.flatMap({ $0.columns.lazy.flatMap { $0.panes } }) {
      pane.setURLBarVisible(urlBarVisible)
    }
    // When hiding URL bar, show header overlay for focused pane as fallback
    if !urlBarVisible {
      showHeaderForFocusedPane()
    } else if let pane = focusedPane {
      pane.headerView.hideImmediately()
    }
  }

  // MARK: - Fold

  static let foldedColumnWidth: CGFloat = 30

  /// Toggle fold state of the focused column. Folded columns collapse to a narrow strip
  /// with vertical title text (Watchtower-style).
  public func toggleFold() {
    guard let column = columns[safe: focusedColumnIndex],
      let constraint = column.widthConstraint
    else { return }

    if column.isFolded {
      // Unfold: restore previous width and show panes + handles
      constraint.constant = column.unfoldedWidth
      column.isFolded = false
      column.foldedLabelView.isHidden = true
      for sub in column.containerView.arrangedSubviews {
        sub.isHidden = false
      }
      // Force a layout pass before resyncing terminal surfaces so
      // bounds reflect the restored column width; then push the
      // live size into ghostty. The `updateSize` inside
      // `setFrameSize` may not re-fire if the pane's own bounds
      // happen to match its pre-fold value, and `updateSize` was
      // suppressed by the hidden-ancestor guard throughout the
      // fold, so an explicit resync is the safest way to redraw
      // the preserved scrollback at full width.
      view.layoutSubtreeIfNeeded()
      for pane in column.panes {
        pane.terminalView?.resyncSurfaceSize()
      }
    } else {
      // Fold: save current width, shrink column, hide panes + vertical handles
      column.unfoldedWidth = constraint.constant
      constraint.constant = Self.foldedColumnWidth
      column.isFolded = true
      // Prefer the focused pane's title; fall back to its address when
      // the page hasn't reported a title yet (e.g. blank browser pane).
      let base: String
      if let pane = column.focusedPane {
        base = pane.title.isEmpty ? pane.address.description : pane.title
      } else {
        base = ""
      }
      // Append pane count if the column has multiple panes
      column.foldedLabelView.text =
        column.panes.count > 1
        ? "\(base) (\(column.panes.count))"
        : base
      column.foldedLabelView.isHidden = false
      // Hide all arranged subviews (pane containers + vertical resize handles)
      for sub in column.containerView.arrangedSubviews {
        sub.isHidden = true
      }
    }
    view.layoutSubtreeIfNeeded()
    // Re-apply focus indicators so folded label gets the border (or removes it)
    if let pane = column.focusedPane {
      applyFocusBorder(pane)
    }
  }

  // MARK: - Browser Navigation

  /// Reload the focused browser pane's current page.
  public func reloadFocusedBrowser() {
    focusedPane?.browserView?.webView.reload()
  }

  /// Reload the focused browser pane bypassing the HTTP cache.
  public func reloadFocusedBrowserFromOrigin() {
    focusedPane?.browserView?.webView.reloadFromOrigin()
  }

  /// Navigate back in the focused browser pane's session history.
  public func goBackFocusedBrowser() {
    focusedPane?.browserView?.webView.goBack()
  }

  /// Navigate forward in the focused browser pane's session history.
  public func goForwardFocusedBrowser() {
    focusedPane?.browserView?.webView.goForward()
  }

  /// Whether the focused browser pane has any back history.
  public var canFocusedBrowserGoBack: Bool {
    focusedPane?.browserView?.webView.canGoBack ?? false
  }

  /// Whether the focused browser pane has any forward history.
  public var canFocusedBrowserGoForward: Bool {
    focusedPane?.browserView?.webView.canGoForward ?? false
  }

  // MARK: - Browser Zoom

  /// Multiplicative step applied to `WKWebView.pageZoom` per zoom
  /// keystroke. 1.1x matches the step Safari and Chrome use; reaching
  /// the next preset in one keystroke without visibly overshooting.
  private static let browserZoomStep: CGFloat = 1.1
  /// Lower clamp on `pageZoom`. Below ~0.25 the page becomes unusable
  /// and the underlying WebKit rendering starts to break glyph hinting.
  private static let browserZoomMin: CGFloat = 0.25
  /// Upper clamp on `pageZoom`. Matches Safari's "Make Text Larger"
  /// ceiling — past ~5x the viewport rarely fits meaningful content.
  private static let browserZoomMax: CGFloat = 5.0

  /// Scale up the focused browser pane's page zoom by one step.
  public func zoomInFocusedBrowser() {
    guard let pane = focusedPane, let webView = pane.browserView?.webView else { return }
    webView.pageZoom = min(webView.pageZoom * Self.browserZoomStep, Self.browserZoomMax)
    pane.urlBar.setZoomPercent(webView.pageZoom)
  }

  /// Scale down the focused browser pane's page zoom by one step.
  public func zoomOutFocusedBrowser() {
    guard let pane = focusedPane, let webView = pane.browserView?.webView else { return }
    webView.pageZoom = max(webView.pageZoom / Self.browserZoomStep, Self.browserZoomMin)
    pane.urlBar.setZoomPercent(webView.pageZoom)
  }

  /// Reset the focused browser pane's page zoom to 1.0.
  public func resetFocusedBrowserZoom() {
    guard let pane = focusedPane else { return }
    pane.browserView?.webView.pageZoom = 1.0
    pane.urlBar.setZoomPercent(1.0)
  }

  // MARK: - Web Inspector

  /// Toggle Web Inspector inline in the focused browser pane.
  public func toggleInspector() {
    focusedPane?.browserView?.toggleInspector()
  }

  /// Whether the focused browser pane's Web Inspector is currently open.
  public var isFocusedInspectorOpen: Bool {
    focusedPane?.browserView?.isInspectorOpen ?? false
  }

  // MARK: - Bookmarks

  /// Toggle bookmark for the focused browser pane's current URL.
  /// Returns true if bookmarked, false if removed, nil if not a browser pane.
  @discardableResult
  public func toggleBookmark() -> Bool? {
    guard isFocusedPaneBrowser, let pane = focusedPane else { return nil }
    let url = pane.address.url.absoluteString
    if bookmarks.isBookmarked(url: url) {
      bookmarks.remove(url: url)
      return false
    } else {
      bookmarks.add(url: url, title: pane.title)
      return true
    }
  }

  /// Whether the focused pane is a browser pane with http/https.
  public var isFocusedPaneBrowser: Bool {
    guard let pane = focusedPane else { return false }
    return pane.browserView != nil && pane.address.kind == .browser
  }

  /// Whether the focused pane's URL is bookmarked.
  public var isFocusedPaneBookmarked: Bool {
    guard let pane = focusedPane,
      pane.address.kind == .browser
    else { return false }
    return bookmarks.isBookmarked(url: pane.address.url.absoluteString)
  }

  // MARK: - Header

  func showHeaderForFocusedPane() {
    guard !urlBarVisible else { return }
    guard let pane = focusedPane, !pane.title.isEmpty else { return }
    lastShownTitle = pane.title
    pane.headerView.show(title: pane.title, autoHide: true)
  }

  func hideHeaderForPane(_ pane: PaneModel) {
    pane.headerView.hideImmediately()
  }

  /// Update a pane's title and show header if it's the focused pane.
  /// Debounced: header only shows when the title is stable for a short time,
  /// filtering out rapid changes from shell command execution.
  ///
  /// Callers pass the `PaneModel` directly so cross-workspace SET_TITLE
  /// events stay correctly routed: the surface → view → pane path is
  /// resolved once at pane creation in `setupPaneCallbacks` and captured
  /// weakly, so events for panes parked in non-current workspaces still
  /// update their titles instead of being dropped.
  public func handleTitleChange(pane: PaneModel, title: String) {
    let titleChanged = pane.title != title
    pane.title = title

    let isFocused = pane.id == focusedPane?.id

    // Window title: immediate (matches ghostty behavior)
    if isFocused {
      view.window?.title = title
    }

    guard titleChanged else { return }

    // Sidebar worklane + header overlay share one debounce so the
    // SET_TITLE storm from shell prompt redraws and progress bars is
    // rate-limited to one rebuild per `titleDebounceInterval` per
    // pane event. The worklane lists panes from every workspace, so
    // this fires regardless of whether the updated pane is focused;
    // the header overlay still gates on focus + URL bar hidden.
    titleDebounceTimer?.invalidate()
    titleDebounceTimer = Timer.scheduledTimer(
      withTimeInterval: Self.titleDebounceInterval, repeats: false
    ) { [weak self, weak pane] _ in
      DispatchQueue.main.async {
        guard let self, let pane else { return }
        self.notifySidebarWorklaneDidChange()
        guard pane.id == self.focusedPane?.id else { return }
        guard !self.urlBarVisible else { return }
        guard pane.title != self.lastShownTitle else { return }
        self.lastShownTitle = pane.title
        pane.headerView.show(title: pane.title, autoHide: true)
      }
    }
  }
}
