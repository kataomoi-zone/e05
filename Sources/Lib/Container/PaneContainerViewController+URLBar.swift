import AppKit

extension PaneContainerViewController {
  // MARK: - URL Bar

  /// Search history and bookmarks for URL bar suggestions.
  ///
  /// Collects all bookmarks plus the last 500 history entries
  /// (deduplicated by URL with the per-URL visit count and most
  /// recent visit time joined in), and runs the combined pool
  /// through `Suggestion.rank` which uses `URLMatcher` (substring
  /// + word-boundary) plus bookmark and frecency bonuses.
  ///
  /// Cost: O(B + H × |query| × avg(|url| + |title|)) where B =
  /// bookmarks, H ≤ `BrowsingHistory.defaultAggregatedLimit`. Runs
  /// synchronously on the main thread, acceptable under
  /// `PaneURLBar`'s ~150ms debounce. If the history cap ever grows
  /// meaningfully past that limit, hoist this onto a background
  /// Task to avoid main-thread blocking while typing.
  func searchSuggestions(query: String, preferSearchTop: Bool = false) -> [Suggestion] {
    let now = Date()
    // Folder rows in the bookmarks store have a `nil` url; suggestion
    // ranking only deals with destinations, so drop them up front.
    let bookmarkEntries = bookmarks.all().filter { !$0.isFolder }
    // Fold history across canonical-key-equivalent URLs (trailing
    // slash / utm / www variants) so a page reached through many of
    // them ranks as one popular entry rather than several diluted rows.
    let foldedHistory = Self.foldHistoryByCanonicalKey(browsingHistory.mostRecentAggregated())

    // Bookmarks first, deduped by canonical key; track the keys so a
    // page that's already starred is dropped from the history pass and
    // appears once, as a bookmark.
    var seenKeys: Set<String> = []
    var candidates: [Suggestion] = []
    for entry in bookmarkEntries {
      guard let url = entry.url, !Self.isErrorTitle(entry.title) else { continue }
      let key = URLCanonicalizer.canonicalKey(url) ?? url
      guard seenKeys.insert(key).inserted else { continue }
      candidates.append(Suggestion(url: url, title: entry.title, isBookmark: true))
    }

    var frecencyByURL: [String: Int] = [:]
    for entry in foldedHistory where !Self.isErrorTitle(entry.title) {
      let key = URLCanonicalizer.canonicalKey(entry.url) ?? entry.url
      guard seenKeys.insert(key).inserted else { continue }
      candidates.append(Suggestion(url: entry.url, title: entry.title, isBookmark: false))
      frecencyByURL[entry.url] = Frecency.score(
        visits: entry.visits, typedVisits: entry.typedVisits,
        lastVisit: entry.lastVisit, now: now)
    }

    let inputBoosts = InputHistoryStore.shared.boosts(forQueryPrefix: query)
    var results = Suggestion.rank(
      query: query,
      candidates: candidates,
      frecencyByURL: frecencyByURL,
      inputBoosts: inputBoosts
    )

    // Collapse search-engine results that point at the same query
    // through different peripheral parameters (`&ia=web`, ad
    // tracking tokens, …) to a single row. Without this, history
    // entries for `duckduckgo.com/?q=foo` and
    // `duckduckgo.com/?q=foo&ia=web` both surface and crowd out
    // genuinely distinct candidates.
    let activeSearchHosts = Self.currentSearchEngineHosts()
    var seenSearchKeys: Set<String> = []
    results = results.filter { suggestion in
      guard let key = Self.searchEngineQueryKey(
        for: suggestion.url, hosts: activeSearchHosts)
      else {
        return true
      }
      return seenSearchKeys.insert(key).inserted
    }

    // Brave-style: when the input itself is a direct-navigable URL
    // (explicit scheme https/http/e05/about, or a bare host/IP
    // that passes PaneAddress.looksLikeHostname), surface an
    // "Open URL" row at the very top. Auto-selecting index 0 then
    // makes Enter open the typed URL instead of deferring to the
    // DuckDuckGo search fallback below. Any existing row with the
    // same URL is removed first so the entry doesn't appear twice
    // when the typed URL is also present in history/bookmarks.
    let direct = directOpenSuggestion(query: query)
    // Origin autofill (Brave/Firefox): when the typed text is a prefix
    // of a host-root candidate's host, float that origin to the top so
    // the inline completion (which fills the top candidate's host) and
    // the auto-selected default match point at the same page. Without it
    // a deeper page ranked #1 by frecency stays selected while the field
    // shows only its origin, and Enter would open the deep page instead
    // of the completed host. Skipped when the input is itself a direct
    // URL — the Open URL row leads there.
    if direct == nil,
      let originIdx = results.firstIndex(where: { sugg in
        !sugg.isSearch && sugg.openPaneID == nil
          && URLBarInlineCompletion.hostSuffix(forQuery: query, candidateURL: sugg.url) != nil
      }), originIdx != 0
    {
      results.insert(results.remove(at: originIdx), at: 0)
    }
    if let direct {
      // Dedup on the canonical key, matching the candidate pool's own
      // folding — otherwise a history entry that differs only by
      // trailing slash / scheme from the typed URL surfaces twice (the
      // "Open URL" row plus its history twin).
      let directKey = URLCanonicalizer.canonicalKey(direct.url) ?? direct.url
      results.removeAll { (URLCanonicalizer.canonicalKey($0.url) ?? $0.url) == directKey }
      results.insert(direct, at: 0)
    }

    // Insert a search-engine entry so the user can always search even
    // when history/bookmarks match (Brave-style). Placed after the top
    // few strong matches but before weaker tail results.
    if let searchAddr = PaneAddress.searchURL(query: query) {
      // Engine-agnostic label so the row stays correct regardless of
      // which search template the preferences point at. Spelling out
      // the engine name would either hard-code DuckDuckGo or require
      // a per-preset display table at every URL bar interaction.
      let searchEntry = Suggestion(
        url: searchAddr.url.absoluteString,
        title: "\(query) \u{2014} Search",
        isBookmark: false,
        isSearch: true
      )
      // After the user rejects an inline completion, lead with search
      // (Brave-style) rather than re-floating the destination they just
      // dismissed; otherwise keep search below the top few strong hits.
      let insertAt = preferSearchTop ? 0 : min(Self.searchEntryInsertOffset, results.count)
      results.insert(searchEntry, at: insertAt)
    }

    // Cap total output to the dropdown's visible-row budget.
    // Suggestion.rank already applies its own cap, but the direct
    // and search insertions push the count past it so we re-trim
    // here to keep the list scroll-free.
    if results.count > Self.maxSuggestionRows {
      results = Array(results.prefix(Self.maxSuggestionRows))
    }

    // For any suggestion whose URL is also open in another pane,
    // append a sibling "Switch to Pane" row right after the
    // navigate row. The user can pick whichever they want with
    // arrow keys / mouse — the navigate row stays unchanged so a
    // duplicate-on-purpose tab open is still one Enter press away.
    // The currently focused pane is excluded so typing the active
    // page's URL doesn't add a confusing "switch to self" entry.
    let openByURL = openPanesByURL(excluding: focusedPane?.id)
    if !openByURL.isEmpty {
      var augmented: [Suggestion] = []
      augmented.reserveCapacity(results.count)
      for suggestion in results {
        augmented.append(suggestion)
        let key = URLCanonicalizer.canonicalKey(suggestion.url) ?? suggestion.url
        if let paneID = openByURL[key] {
          augmented.append(
            Suggestion(
              url: suggestion.url,
              title: suggestion.title,
              isBookmark: suggestion.isBookmark,
              openPaneID: paneID
            )
          )
        }
      }
      results = augmented
      // Inserting siblings can push the list past the dropdown's
      // visible cap; trim again so we never overflow.
      if results.count > Self.maxSuggestionRows {
        results = Array(results.prefix(Self.maxSuggestionRows))
      }
    }

    return results
  }

  /// One page's history rolled up across canonical-key-equivalent URLs
  /// (trailing-slash / utm / www variants). Visit counts sum so a page
  /// reached through many variants ranks as one popular entry;
  /// representative `url` / `title` come from the most recent visit.
  struct FoldedHistoryEntry: Equatable {
    let url: String
    let title: String
    let visits: Int
    let typedVisits: Int
    let lastVisit: Date
  }

  /// Fold URL-exact aggregated history into canonical-key groups,
  /// preserving the input's recency order — one entry per key, at the
  /// position of its first member (the most recent, since the input is
  /// last-visit descending).
  nonisolated static func foldHistoryByCanonicalKey(
    _ entries: [BrowsingHistory.AggregatedEntry]
  ) -> [FoldedHistoryEntry] {
    var byKey: [String: FoldedHistoryEntry] = [:]
    var order: [String] = []
    for entry in entries {
      let key = URLCanonicalizer.canonicalKey(entry.url) ?? entry.url
      if let existing = byKey[key] {
        let entryIsNewer = entry.lastVisit > existing.lastVisit
        byKey[key] = FoldedHistoryEntry(
          url: entryIsNewer ? entry.url : existing.url,
          title: entryIsNewer ? entry.title : existing.title,
          visits: existing.visits + entry.visits,
          typedVisits: existing.typedVisits + entry.typedVisits,
          lastVisit: max(existing.lastVisit, entry.lastVisit)
        )
      } else {
        byKey[key] = FoldedHistoryEntry(
          url: entry.url, title: entry.title, visits: entry.visits,
          typedVisits: entry.typedVisits, lastVisit: entry.lastVisit)
        order.append(key)
      }
    }
    return order.compactMap { byKey[$0] }
  }

  /// Map every pane's canonical URL key to its pane id. Cross-workspace
  /// because the URL bar suggestion list spans every browser pane in
  /// the window, not just the current workspace's. The key folds
  /// trailing-slash / fragment / tracking-param differences
  /// (`URLCanonicalizer`) so a suggestion still matches an open pane
  /// whose URL differs only in those incidentals; panes whose URL
  /// doesn't canonicalize (e05://, extension pages) fall back to their
  /// raw absolute string. The optional `excluding` filter drops a
  /// single pane (typically the focused one) so the URL bar doesn't
  /// offer to "switch" to itself when the user types their own address.
  private func openPanesByURL(excluding excludedID: ULID?) -> [String: ULID] {
    var byKey: [String: ULID] = [:]
    for workspace in workspaces {
      for column in workspace.columns {
        for pane in column.panes {
          if pane.id == excludedID { continue }
          let url = pane.address.url.absoluteString
          guard !url.isEmpty else { continue }
          let key = URLCanonicalizer.canonicalKey(url) ?? url
          // First write wins. Multiple panes on the same page is
          // rare but possible; arbitrary tie-breaking is fine here
          // since the user gets focused at one of them either way.
          if byKey[key] == nil {
            byKey[key] = pane.id
          }
        }
      }
    }
    return byKey
  }

  /// Focus the pane with `id`, switching workspaces if the pane
  /// lives outside the current one. No-op when the id doesn't
  /// resolve (the pane was closed between suggestion build and
  /// click). Cross-workspace focus is deferred until the slide
  /// animation completes so the focus indicator lands on a column
  /// whose layout has already settled into place.
  public func switchToPane(id: ULID) {
    for (wsIndex, workspace) in workspaces.enumerated() {
      for (colIndex, column) in workspace.columns.enumerated() {
        guard let paneIndex = column.panes.firstIndex(where: { $0.id == id }) else {
          continue
        }
        if wsIndex == focusedWorkspaceIndex {
          setFocus(columnIndex: colIndex, paneIndex: paneIndex)
        } else {
          switchWorkspace(to: wsIndex) { [weak self] in
            // Guard against a manual workspace switch racing the slide:
            // only land focus if we actually settled on the target WS.
            guard let self, self.focusedWorkspaceIndex == wsIndex else { return }
            self.setFocus(columnIndex: colIndex, paneIndex: paneIndex)
          }
        }
        return
      }
    }
  }

  /// Upper bound on the number of rows shown in the URL bar dropdown.
  /// Kept in sync with `SuggestionListView.maxVisibleRows` so the list
  /// never scrolls.
  static let maxSuggestionRows = 8

  /// Position at which to insert the explicit search-engine entry into
  /// the suggestion list, measured from the top. Placed after the top
  /// few strong matches (Brave-style) so direct hits remain reachable
  /// by ↓-Enter without skipping a search affordance underneath.
  static let searchEntryInsertOffset = 3

  /// Built-in search engines whose `?q=` parameter is the canonical
  /// identity of the page. Two visits to such a host with different
  /// peripheral query params (`&ia=web`, `&prevq=…`) are visits to
  /// the same search and should collapse to a single suggestion;
  /// non-search hosts return nil so their suggestions are never
  /// collapsed. Augmented at call time with the user's current
  /// custom template host via ``currentSearchEngineHosts()``.
  ///
  /// `nonisolated` so the `Set<String>` literal can be reached as a
  /// default-argument value from the nonisolated `searchEngineQueryKey`;
  /// the class's MainActor isolation would otherwise capture it.
  /// Stored as base domains; `searchEngineQueryKey` matches them by
  /// suffix so subdomains and locale hosts (`html.duckduckgo.com`,
  /// `www.google.com`) collapse onto the same engine without being
  /// enumerated here.
  nonisolated static let searchEngineHosts: Set<String> = [
    "duckduckgo.com",
    "google.com",
    "bing.com",
    "search.brave.com",
  ]

  /// Built-in set unioned with the host of the user's configured
  /// search template, so a Custom engine still benefits from
  /// suggestion-row collapsing. Live read each call to follow
  /// preferences changes without restart.
  @MainActor
  static func currentSearchEngineHosts() -> Set<String> {
    var hosts = searchEngineHosts
    let template = PreferencesStore.shared.preferences.searchTemplate
    if let url = URL(string: template),
      let host = url.host(percentEncoded: false)?.lowercased(),
      !host.isEmpty
    {
      hosts.insert(host)
    }
    return hosts
  }

  /// Canonical "this is the same search" key for `urlString`, or
  /// nil when the URL doesn't belong to a recognised search engine.
  /// Matched on host (lowercased) plus the `q` parameter only,
  /// which is the user-visible query string for every engine in
  /// the allowlist.
  ///
  /// `nonisolated` because the body is pure URL parsing — no main-
  /// actor state is touched. Without it, the `.first(where:)` closure
  /// inherits the implicit `@MainActor` isolation that NSViewController
  /// propagates to its subclass, and the Swift 6 runtime traps when a
  /// non-MainActor caller (the suggestion-filter unit tests) invokes
  /// the closure off the main queue.
  ///
  /// The `hosts:` parameter lets MainActor callers pass
  /// ``currentSearchEngineHosts()`` so a Custom template host gets
  /// collapsed too. Defaulting to the static set keeps the existing
  /// nonisolated test callers working unchanged.
  nonisolated static func searchEngineQueryKey(
    for urlString: String,
    hosts: Set<String> = searchEngineHosts
  ) -> String? {
    guard let url = URL(string: urlString),
      let host = url.host(percentEncoded: false)?.lowercased(),
      // Suffix match so subdomains / locale hosts collapse onto the
      // same base engine as the bare host; key off `base` (not the
      // raw host) so `www.google.com` and `google.com` share one key.
      let base = hosts.first(where: { host == $0 || host.hasSuffix("." + $0) })
    else {
      return nil
    }
    let q =
      URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?
      .first(where: { $0.name == "q" })?
      .value ?? ""
    return "\(base)|\(q)"
  }

  /// Whether `title` looks like an HTTP error page that the user
  /// should never see in URL-bar suggestions ("Error 400 (Bad
  /// Request)!", "404 Not Found", …). Both shapes require the
  /// status code to be in the 4xx / 5xx range — bare 3-digit
  /// prefixes outside that range (`100% guide`, `1234 ways`,
  /// `300 Multiple Choices`) belong to legitimate page titles and
  /// stay in the suggestion pool. The bare-prefix form also
  /// requires a trailing whitespace so a host-like literal
  /// (`404Found.com`) isn't filtered.
  static func isErrorTitle(_ title: String) -> Bool {
    let trimmed = title.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty else { return false }
    if trimmed.hasPrefix("error ") {
      let codePart = trimmed.dropFirst("error ".count).prefix(3)
      return Self.isHTTPErrorCodePrefix(codePart)
    }
    let leading = trimmed.prefix(3)
    guard Self.isHTTPErrorCodePrefix(leading) else { return false }
    let afterDigits = trimmed.dropFirst(3)
    return afterDigits.first?.isWhitespace == true
  }

  /// `s` is a 3-character HTTP status code in the error range
  /// (400–599). The first digit alone is enough to gate on, since
  /// the matcher only cares whether to filter the row.
  private static func isHTTPErrorCodePrefix(_ s: Substring) -> Bool {
    guard s.count == 3, s.allSatisfy(\.isNumber) else { return false }
    let first = s.first!
    return first == "4" || first == "5"
  }

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
      // Cross-type: build a fresh PaneModel for the new kind and
      // splice it into the column at the same index. The position,
      // surrounding panes, and column geometry stay put; only the
      // pane's content view changes.
      guard let colIdx = columns.firstIndex(where: { $0.panes.contains(where: { $0.id == pane.id }) }) else { return }
      let column = columns[colIdx]
      guard let paneIdx = column.panes.firstIndex(where: { $0.id == pane.id }) else { return }

      let newPane = makePane(address: newAddress)
      // The new pane joins the window's global toggle; any peek
      // reveal that was active on the outgoing pane belongs to the
      // dismissed bar's lifecycle and shouldn't carry over.
      newPane.setURLBarVisible(urlBarVisible)
      setupPaneCallbacks(pane: newPane, column: column)

      column.panes[paneIdx] = newPane
      rebuildColumnView(column: column)
      view.layoutSubtreeIfNeeded()
      setFocus(columnIndex: colIdx, paneIndex: paneIdx)
    } else {
      // Same type: navigate in place
      // Browser → browser: load new URL. Terminal → terminal: no-op
      // (address update only). Finder → finder: navigate the file
      // browser to the new path; the pane.address rebuild then comes
      // back through `FinderPaneView.onPathChange` so the URL bar
      // ends up displaying whatever path the finder actually resolved
      // to (handles symlinks and trailing-slash normalisation).
      pane.address = newAddress
      if let bv = pane.browserView {
        bv.navigate(to: newAddress.url.absoluteString, transition: .typed)
      } else if let fv = pane.finderView, newAddress.kind == .finder {
        let path = newAddress.currentPath
        if !path.isEmpty {
          fv.navigate(to: URL(fileURLWithPath: path, isDirectory: true))
        }
      }
      view.window?.makeFirstResponder(pane.preferredFirstResponder)
    }
  }

  /// Focus the URL bar of the focused pane (⌘+L). When the global
  /// toggle is off the bar peeks open just for this pane — Esc or a
  /// committed navigation collapses it again. With the toggle on
  /// the bar is already pinned everywhere, so this only steals
  /// first responder. The find bar floats at the pane bottom and
  /// no longer competes with the URL field for visual space, so it
  /// can stay open while a URL is being edited.
  public func focusURLBar(prefill: String? = nil) {
    guard let pane = focusedPane else { return }
    if !urlBarVisible {
      pane.setURLBarPeek(true)
    }
    pane.headerView.hideImmediately()
    if let prefill {
      pane.urlBar.setDisplayURL(prefill)
    }
    pane.urlBar.focusURLField()
  }

  /// Toggle the global URL bar visibility. The toggle action flips
  /// this for every pane in lockstep so the user gets the same
  /// chrome treatment across the whole window, regardless of which
  /// pane currently has focus.
  public func toggleURLBarVisibility() {
    urlBarVisible.toggle()
    // Stop the hover scheduler before applying the new state so a
    // collapse that was about to fire from a pre-toggle peek can't
    // race with the just-applied `.pinned` writes. Without this, a
    // 300ms hover-out queued just before the user pinned everything
    // would land afterwards as a stale `setURLBarPeek(false)` —
    // currently a no-op against `.pinned` but a fragile invariant
    // to lean on for future changes.
    cancelAllURLBarHoverScheduling()
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
      // live size into ghostty. The `syncMetrics` inside
      // `setFrameSize` may not re-fire if the pane's own bounds
      // happen to match its pre-fold value, and `syncMetrics` was
      // suppressed by the hidden-ancestor guard throughout the
      // fold, so an explicit resync is the safest way to redraw
      // the preserved scrollback at full width.
      view.layoutSubtreeIfNeeded()
      for pane in column.panes {
        pane.terminalView?.resyncSurfaceSize()
      }
      // Fold didn't fire resignFirstResponder on any hidden pane, so
      // every terminal surface in the column still carries whatever
      // ghostty_surface_set_focus value it had at fold time. Clear
      // them all first, then hand first responder back to the
      // focused pane so `becomeFirstResponder` re-arms focus on
      // exactly one surface. Without this step a split column
      // reappears with the focused pane's caret drawn as a hollow
      // box (no responder) while the non-focused pane blinks (stale
      // ghostty focus), and keyboard input goes nowhere.
      for pane in column.panes {
        pane.terminalView?.clearSurfaceFocus()
      }
      if let pane = column.focusedPane {
        pane.containerView.window?.makeFirstResponder(pane.preferredFirstResponder)
      }
      // Bring the newly expanded column into view. A folded column
      // occupies only `foldedColumnWidth` (30pt), so the rest of the
      // workspace is shifted to fill the horizontal space; unfolding
      // can push the column partially or entirely off-screen, which
      // defeats the purpose of expanding it. Mirror the
      // scroll-to-focus behaviour that `setFocus` applies on every
      // other focus hop (keybind / palette / sidebar click) so
      // unfold lands the column at the same visible position a
      // direct focus would.
      scrollToColumn(at: focusedColumnIndex)
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

  /// Manually suspend the focused browser pane. Mirrors what the 1
  /// Hz tick and the memory-pressure handler do, just kicked from a
  /// user-driven trigger (palette / IPC) instead of an idle /
  /// pressure event.
  /// Returns the underlying `suspend()` result so callers that
  /// reach the helper without going through `canSuspendFocusedBrowser`
  /// can react to a refused suspend instead of silently dropping it.
  @discardableResult
  public func suspendFocusedBrowser() -> Bool {
    focusedPane?.browserView?.suspend() ?? false
  }

  /// True when the focused pane is a browser whose `WKWebView` can
  /// currently accept a suspend. Single source of truth
  /// for both the palette action's `validate` (decides enabled-ness)
  /// and its `handler` (gates the actual call), so the two stay in
  /// lock-step when the underlying conditions evolve.
  public var canSuspendFocusedBrowser: Bool {
    isFocusedPaneBrowser
      && (focusedPane?.browserView?.canSuspend ?? false)
  }

  /// Reload the focused browser pane bypassing the HTTP cache.
  public func reloadFocusedBrowserFromOrigin() {
    focusedPane?.browserView?.webView.reloadFromOrigin()
  }

  /// Stop in-flight loading on the focused browser pane.
  public func stopFocusedBrowser() {
    focusedPane?.browserView?.webView.stopLoading()
  }

  /// Whether the focused browser pane has a load in flight.
  public var isFocusedBrowserLoading: Bool {
    focusedPane?.browserView?.webView.isLoading ?? false
  }

  /// Navigate back in the focused browser pane's session history.
  public func goBackFocusedBrowser() {
    focusedPane?.browserView?.goBack()
  }

  /// Navigate forward in the focused browser pane's session history.
  public func goForwardFocusedBrowser() {
    focusedPane?.browserView?.goForward()
  }

  /// Whether the focused browser pane has any back history.
  public var canFocusedBrowserGoBack: Bool {
    focusedPane?.browserView?.webView.canGoBack ?? false
  }

  /// Whether the focused browser pane has any forward history.
  public var canFocusedBrowserGoForward: Bool {
    focusedPane?.browserView?.webView.canGoForward ?? false
  }

  /// Forward a ⌘← / ⌘→ keypress notification to the focused browser
  /// pane so its url observer can fire a "Back" / "Forward" toast once
  /// WebKit lands the resulting navigation. Called from the app-level
  /// keyDown monitor; `focusedPane` is module-internal so a public
  /// hop through the container keeps `AppDelegate` from depending on
  /// pane-model internals.
  public func noteNativeBackForwardPressedOnFocusedBrowser(isBack: Bool) {
    focusedPane?.browserView?.noteNativeBackForwardPressed(isBack: isBack)
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

  /// Reset the focused browser pane's page zoom to 1.0. Clears both
  /// the `pageZoom` (driven by `⌘+` / `⌘-`, reflows the layout) and
  /// the rendering-layer `magnification` (driven by the pinch
  /// gesture, no reflow) so the user lands at the baseline regardless
  /// of which input accumulated the zoom — matching Safari's `⌘0`
  /// semantics. `⌘+` / `⌘-` still step `pageZoom` alone, so the
  /// per-gesture independence the two surfaces have is preserved.
  /// On extension-hosted panes `setMagnification` is a no-op because
  /// `allowsMagnification` is false there, so the call is safe to
  /// issue unconditionally.
  public func resetFocusedBrowserZoom() {
    guard let pane = focusedPane, let webView = pane.browserView?.webView else { return }
    webView.pageZoom = 1.0
    webView.setMagnification(1.0, centeredAt: .zero)
    pane.urlBar.setZoomPercent(1.0)
  }

  /// Read the focused pane's current page zoom and surface it as a
  /// toast like "Zoom 110%". Called from the zoom-in / zoom-out
  /// action handlers so the post-step value is shown rather than the
  /// generic action label.
  func showZoomToast() {
    guard let pane = focusedPane,
      let webView = pane.browserView?.webView
    else { return }
    let percent = Int((webView.pageZoom * 100).rounded())
    showToast("Zoom \(percent)%")
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
