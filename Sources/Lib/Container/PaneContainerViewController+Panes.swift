import AppKit
import GhosttyKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "Panes")

extension PaneContainerViewController {
  // MARK: - Column Management

  /// Build a pane via `makePane` and append a column for it. Pass
  /// `startSuspended: true` (with `initialTitle:`) to skip the
  /// first navigation on a browser pane — see `PaneModel.init` for
  /// the contract. `focusOnInsert: false` is opt-in for callers that
  /// commit their own focus target after the insert loop completes
  /// (e.g. `restoreSession` finishes with
  /// `restoreFocusInCurrentWorkspace`); without that follow-up the
  /// container is left with stale focus state.
  @discardableResult
  public func addColumn(
    address: PaneAddress = .terminal,
    startSuspended: Bool = false,
    initialTitle: String? = nil,
    focusOnInsert: Bool = true
  ) -> ColumnModel {
    insertColumn(
      with: makePane(
        address: address,
        startSuspended: startSuspended,
        initialTitle: initialTitle),
      focusOnInsert: focusOnInsert)
  }

  @discardableResult
  func insertColumn(with pane: PaneModel, focusOnInsert: Bool = true) -> ColumnModel {
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
    // Tell the extension controller about the new tab now that the
    // pane is reachable from the workspace bridge's `tabs(for:)`
    // walk. A no-op when no extensions are loaded yet (e.g. session
    // restore) — the controller's startup seed picks those panes up
    // through `openWindowsFor → tabs(for:)` instead.
    ExtensionController.shared.notifyTabOpened(pane)

    rebuildStackView()

    // Pin the column's height to the hosting workspace stack so the
    // vertical layout is never ambiguous. Without this, the default
    // `.centerY` alignment of `NSStackView(.horizontal)` leaves each
    // column's height up to AppKit's ambiguity-resolution fallback.
    // Columns created before the window finishes sizing (startup /
    // session restore) fell back to window height and looked fine;
    // columns inserted mid-session (`ctrl+opt+b`, a bookmark /
    // history activation, or any other `addColumn` callsite) landed
    // with an arbitrary height that often exceeded the window, so
    // the pane rendered past the window bottom. Activated after
    // `rebuildStackView()` so both views share a common ancestor —
    // activating against `stackView.heightAnchor` before that throws
    // `NSInternalInconsistencyException` and kills the startup path.
    column.containerView.heightAnchor
      .constraint(
        equalTo: currentWorkspaceVC.stackView.heightAnchor,
        constant: -(WorkspaceViewController.outerMargin * 2)
      )
      .isActive = true

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
    // tween after the insert's completion handler. Skipping
    // entirely (`focusOnInsert: false`) is the bulk-insert escape
    // hatch — `setFocus` would otherwise route through
    // `restoreIfSuspended()` for every column added, defeating any
    // `startSuspended: true` pane the caller just created.
    if focusOnInsert {
      setFocus(columnIndex: insertIndex, paneIndex: 0, scroll: false)
    }
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
        // `removePane(in:workspace:)` variant.
        for (colIdx, col) in self.columns.enumerated() {
          if let paneIdx = col.panes.firstIndex(where: { $0.id == pane.id }) {
            self.removePane(columnIndex: colIdx, paneIndex: paneIdx)
            return
          }
        }
      }

      // file:// URLs land in a finder pane; everything else routes
      // through `PaneAddress`, which keeps the browser / unknown-
      // fallback decision in one place.
      tv.onOpenURL = { [weak self] url in
        let address: PaneAddress
        if url.isFileURL {
          address = PaneAddress.finder(path: url.path(percentEncoded: false))
        } else {
          address = PaneAddress(url)
        }
        self?.addColumn(address: address)
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
        // Update history title for the current URL. Private
        // workspaces don't write to the history store at all, so the
        // matching `recordVisit` skip in `onURLChange` and this skip
        // are paired.
        if let workspace = self.workspaceContaining(pane: pane), !workspace.isPrivate {
          self.browsingHistory.updateTitle(
            url: pane.address.url.absoluteString, title: title
          )
        }
        ExtensionController.shared.notifyTabPropertiesChanged(pane, properties: .title)
      }
      bv.onURLChange = { [weak self, weak pane] url in
        guard let url else { return }
        let urlString = url.absoluteString
        pane?.address = PaneAddress(url)
        pane?.urlBar.setDisplayURL(urlString)
        // Record visit (skips internal pages and duplicates). Private
        // workspaces never feed the persistent history store — that's
        // the whole point of the mode, mirroring how Safari /
        // Firefox / Brave handle their private windows.
        if url.scheme == "https" || url.scheme == "http",
          let self, let pane,
          let workspace = self.workspaceContaining(pane: pane),
          !workspace.isPrivate
        {
          self.browsingHistory.recordVisit(url: urlString, title: pane.title)
        }
        if let pane {
          ExtensionController.shared.notifyTabPropertiesChanged(pane, properties: .URL)
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
        if let pane {
          ExtensionController.shared.notifyTabPropertiesChanged(pane, properties: .loading)
        }
      }
      bv.onAudioStateChanged = { [weak self, weak pane, weak bv] in
        guard let pane, let bv else { return }
        pane.urlBar.setMuteState(
          isMuted: bv.isMuted,
          isPlayingAudio: bv.isPlayingAudio,
          hasActiveMedia: bv.hasActiveMedia)
        // Targeted row update so the 1 Hz audio probe doesn't trigger
        // a full worklane rebuild. Structural changes (pane open /
        // close, focus shift) still go through
        // `notifySidebarWorklaneDidChange`; only the audio glyph
        // flips here.
        self?.sidebarVC?.updatePaneAudioState(
          paneId: pane.id,
          isMuted: bv.isMuted,
          isPlayingAudio: bv.isPlayingAudio,
          hasActiveMedia: bv.hasActiveMedia)
        // Surface mute / audible flips to web extensions so
        // `chrome.tabs.onUpdated` listeners observe state changes
        // alongside title / URL / loading.
        ExtensionController.shared.notifyTabPropertiesChanged(
          pane, properties: [.muted, .playingAudio])
      }
      pane.urlBar.onMuteToggle = { [weak bv] in
        bv?.toggleMute()
      }
      pane.urlBar.onMuteSiteToggle = { [weak self] host in
        let store = MutedSitesStore.shared
        let nextMuted = !store.isMuted(host: host)
        store.setMuted(nextMuted, host: host)
        // Apply the new state to every already-open pane on the
        // same host so the toggle reads as "set this site's mute
        // policy" rather than "remember it for next time"; future
        // pane loads pick the value up through
        // `applySiteMutePreference` after navigation.
        self?.applyMuteToPanes(matchingHost: host, muted: nextMuted)
      }
      bv.onDownloadStarted = { [weak self] wkDownload in
        self?.downloadsManager.adopt(wkDownload)
      }
      bv.onOpenInNewPane = { [weak self] url in
        // Mirrors the bookmark / history "open in new browser
        // column" UX policy: a browser link Cmd-click /
        // `target="_blank"` / `window.open()` / right-click "Open
        // in Pane" lands as a fresh column in the current workspace.
        self?.addColumn(address: PaneAddress(url))
      }
      bv.onOpenInNewWorkspace = { [weak self, weak pane] url in
        // Mirrors bookmark / history "open in new workspace": the
        // newly created workspace seeds a terminal column, and the
        // browser column requested by the link lands alongside it.
        // Replacing the auto-terminal is deferred until the
        // ergonomics demand it.
        //
        // Private inheritance: a Shift-click from inside a private
        // workspace lands the new workspace as private too, so a
        // user navigating outward never crosses back into the
        // persistent profile silently. Matches Safari / Firefox /
        // Brave: their Private Window's "Open Link in New Window"
        // also stays private.
        guard let self else { return }
        let inheritsPrivate =
          pane.flatMap { self.workspaceContaining(pane: $0) }?.isPrivate ?? false
        self.createWorkspace(isPrivate: inheritsPrivate)
        self.addColumn(address: PaneAddress(url))
      }
    } else if let fv = pane.finderView {
      // Finder pane: cwd, focus, navigation enabledness, and titles
      // all flow through the same handlers the browser pane uses, so
      // the URL bar / sidebar / window-title pipelines stay uniform.
      // The pane.address rebuild here is what keeps the URL bar
      // display, sidebar worklane label, and session.json in lock
      // step with the directory the user is currently browsing.
      fv.onPathChange = { [weak pane] url in
        guard let pane else { return }
        let newAddress = PaneAddress.finder(path: url.path(percentEncoded: false))
        pane.address = newAddress
        pane.urlBar.setDisplayURL(newAddress.displayString)
        // Finder navigation completes synchronously, so the path
        // change is the natural "navigation finished" signal —
        // collapse any active ⌘L peek now that the user has seen
        // the new path land in the bar.
        pane.setURLBarPeek(false)
      }
      fv.onTitleChange = { [weak self, weak pane] title in
        guard let self, let pane else { return }
        self.handleTitleChange(pane: pane, title: title)
      }
      fv.onFocusChanged = { [weak self, weak pane] in
        guard let self, let pane else { return }
        self.handleFocusChange(from: pane)
      }
      fv.onNavigationStateChange = { [weak pane] canBack, canForward in
        pane?.urlBar.setNavigationEnabled(back: canBack, forward: canForward)
      }
      // Initial enabledness — the navigation stack starts empty so
      // both arrows render disabled until the first navigate.
      pane.urlBar.setNavigationEnabled(back: false, forward: false)
      pane.urlBar.setReloadEnabled(true)
      // Title kicks the sidebar worklane row to the cwd's leaf name
      // before the first navigate; without this the row reads
      // "Finder" until the user clicks anything.
      let initialTitle = fv.currentURL.lastPathComponent
      handleTitleChange(pane: pane, title: initialTitle.isEmpty ? "Finder" : initialTitle)
    } else {
      // Terminal/other panes: navigation buttons always disabled
      pane.urlBar.setNavigationEnabled(back: false, forward: false)
      // Mirror the non-browser case for reload too so the button
      // visibly dims instead of advertising a click that routes
      // to a nil `browserView?.webView` and silently no-ops.
      pane.urlBar.setReloadEnabled(false)
    }

    // URL bar: navigate callback. Closes the peek on the commit
    // event itself. Routing the close through `WKWebView.isLoading`
    // false-edge KVO loses same-URL reloads, immediate redirects,
    // and other arcs where the load completes too fast for the
    // observer to sample — leaving the bar visibly stuck open.
    pane.urlBar.onNavigate = { [weak self, weak pane] input in
      guard let self, let pane else { return }
      self.handleURLBarNavigate(pane: pane, input: input)
      pane.setURLBarPeek(false)
    }

    // URL bar: ESC returns focus to pane content. Cancelling is
    // explicit user intent to abandon the peek session, so collapse
    // immediately (a globally-pinned bar stays put — `setURLBarPeek`
    // is a no-op when the state is `.pinned`). Restore the URL
    // field to the pane's actual address so a re-peek doesn't
    // surface whatever was typed mid-edit, matching Chrome / Safari /
    // Firefox semantics where Esc reverts the URL bar.
    pane.urlBar.onCancel = { [weak pane] in
      guard let pane else { return }
      let restoreURL = pane.isBlankBrowser ? "" : pane.address.displayString
      pane.urlBar.setDisplayURL(restoreURL)
      pane.containerView.window?.makeFirstResponder(pane.preferredFirstResponder)
      pane.setURLBarPeek(false)
    }

    // URL bar: editing ended with the cursor outside the bar (e.g.
    // user clicked a different pane while a peek was open). Collapse
    // the peek directly instead of going through the hover scheduler
    // — the 300ms debounce there is meant for cursor-only drift, not
    // for first-responder loss.
    pane.urlBar.onEditingEndedOutsideBar = { [weak pane] in
      pane?.setURLBarPeek(false)
    }

    // URL bar: back/forward/reload route to browser or finder depending
    // on which content the pane carries. Stop applies only to browser
    // (a directory listing has nothing to interrupt).
    pane.urlBar.onBack = { [weak pane] in
      if let bv = pane?.browserView {
        bv.webView.goBack()
      } else if let fv = pane?.finderView {
        fv.goBack()
      }
    }
    pane.urlBar.onForward = { [weak pane] in
      if let bv = pane?.browserView {
        bv.webView.goForward()
      } else if let fv = pane?.finderView {
        fv.goForward()
      }
    }
    pane.urlBar.onReload = { [weak pane] in
      if let bv = pane?.browserView {
        bv.webView.reload()
      } else if let fv = pane?.finderView {
        fv.reload()
      }
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

    // URL bar: per-extension `Open Options Page` lands as a fresh
    // browser column, mirroring the sidebar `Open Options Page`
    // policy. The host owns column creation, so the URL bar just
    // surfaces the URL without trying to walk the workspace.
    pane.urlBar.onOpenURLInNewColumn = { [weak self] url in
      self?.addColumn(address: PaneAddress(url))
    }

    // URL bar: a suggestion tagged with `openPaneID` switches focus
    // to that pane (across workspaces if needed) instead of
    // navigating in place. Host owns the cross-WS dispatch so the
    // URL bar stays unaware of workspace structure.
    pane.urlBar.onSwitchToPane = { [weak self] paneID in
      self?.switchToPane(id: paneID)
    }

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

    // Sync URL bar visibility with the window-global toggle so a
    // pane appended to a workspace that already has the bar pinned
    // doesn't open with a stale `.hidden` state.
    pane.setURLBarVisible(urlBarVisible)

    // Wire the top-edge hit zone to the debounced peek scheduler.
    // The hit zone is hidden until this pane gains focus, so the
    // schedulers are dormant for unfocused panes even though the
    // closures are attached.
    wireURLBarHoverScheduler(pane: pane)
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
    showToast("Split Vertical")
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

  /// Width of the user-visible portion of `scrollView`'s clip view,
  /// with `contentInsets.left` / `.right` (the sidebar pinned inset
  /// and any future trailing inset) excluded. NSClipView's
  /// `bounds.width` itself stays at the full clip span regardless
  /// of `contentInsets`, so any callsite that meant "how wide is
  /// the part of the scroll view the user can actually see" must
  /// subtract the insets — share this helper rather than open-
  /// coding the subtraction so widths derived from it (column
  /// `.fraction` presets, `viewDidLayout` width sync, scroll
  /// centring) all agree on the same notion of "visible".
  func effectiveVisibleWidth(in scrollView: NSScrollView) -> CGFloat {
    let insets = scrollView.contentInsets
    return scrollView.contentView.bounds.width - insets.left - insets.right
  }

  /// Compute where the scroll view should land so `column` is
  /// centred within the visible (post-inset) region. Call with the
  /// layout already settled at the column's final width — reading
  /// the frame during the insert tween would capture an intermediate
  /// width and target the wrong X. Returns `nil` when the whole
  /// content already fits in view.
  ///
  /// Honours `scrollView.contentInsets` so a column doesn't end up
  /// hidden behind the pinned sidebar: the visible region is
  /// `(insets.left, scrollView.bounds.width - insets.right)`, the
  /// scroll origin's lower bound is `-insets.left` (the natural
  /// "left edge" with the inset present), and centring is computed
  /// against the post-inset midpoint rather than the raw bounds.
  func computeScrollTargetX(for column: ColumnModel) -> CGFloat? {
    let columnFrame = column.containerView.frame
    let visibleWidth = scrollView.contentView.bounds.width
    let contentWidth = stackView.frame.width
    let insets = scrollView.contentInsets
    let effective = effectiveVisibleWidth(in: scrollView)
    guard contentWidth > effective else { return nil }

    // Reserve the same gap on either side of a left-pinned column as
    // the perimeter outer margin, so a focused column doesn't kiss
    // the sidebar / window edge after a focus scroll while every
    // other gap in the layout is `outerMargin` wide.
    let perimeter = WorkspaceViewController.outerMargin
    let targetX: CGFloat
    if columnFrame.width >= effective {
      // Column can't fit, pin its left edge to the visible region's
      // leading edge offset by `perimeter` so the gap before the
      // column matches the rhythm of the rest of the layout.
      targetX = columnFrame.minX - insets.left - perimeter
    } else {
      // Centre against the post-inset midpoint. Reuse `effective` so
      // both branches of this method derive their "visible width"
      // from the same helper instead of repeating the inset math.
      let visibleCenter = insets.left + effective / 2
      targetX = columnFrame.midX - visibleCenter
    }
    let minScrollX = -insets.left
    let maxScrollX = contentWidth - visibleWidth + insets.right
    return max(minScrollX, min(maxScrollX, targetX))
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

  /// Tween two views from their pre-swap frames into their new
  /// positions via a CALayer `transform` translation, so a reorder
  /// reads as a slide instead of a snap. Shared by both
  /// `moveColumnLeft/Right` (horizontal swap inside the workspace
  /// stack view) and `movePaneUp/Down` (vertical swap inside a
  /// column stack view). The caller is responsible for mutating
  /// the model, rebuilding the stack view, and forcing layout
  /// *before* calling — `viewA` / `viewB` should already sit at
  /// their final frames, and `oldFrameA` / `oldFrameB` are the
  /// frames they occupied before the swap.
  ///
  /// Uses layer transforms rather than `allowsImplicitAnimation`
  /// on the parent stack: the stack's reshuffle finishes
  /// synchronously, so no sibling view sees an intermediate layout
  /// (which was the source of the vertical-close tilt and the
  /// horizontal-insert Metal-surface reflow seen in earlier pane
  /// animations). Skips straight to the final layout when
  /// off-screen so session restore doesn't spawn a start-up tween.
  func animateLayerSwap(
    _ viewA: NSView, oldFrameA: CGRect,
    _ viewB: NSView, oldFrameB: CGRect
  ) {
    guard view.window != nil else { return }

    let newFrameA = viewA.frame
    let newFrameB = viewB.frame
    let deltaA = CGPoint(
      x: oldFrameA.minX - newFrameA.minX,
      y: oldFrameA.minY - newFrameA.minY)
    let deltaB = CGPoint(
      x: oldFrameB.minX - newFrameB.minX,
      y: oldFrameB.minY - newFrameB.minY)

    viewA.wantsLayer = true
    viewB.wantsLayer = true

    // Leave each view's model transform at identity (AppKit re-
    // sets it on every layout pass anyway) and let a CABasicAnimation
    // paint the translation on the presentation layer only. The
    // view appears at its old frame, slides to the new one, then
    // the animation auto-removes leaving the identity model.
    addSwapAnimation(to: viewA.layer, delta: deltaA)
    addSwapAnimation(to: viewB.layer, delta: deltaB)
  }

  private func addSwapAnimation(to layer: CALayer?, delta: CGPoint) {
    guard let layer, delta != .zero else { return }
    let animation = CABasicAnimation(keyPath: "transform")
    animation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(delta.x, delta.y, 0))
    animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    animation.duration = Self.paneAnimationDuration
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(animation, forKey: "paneLayerSwap")
  }

  func removePane(columnIndex: Int, paneIndex: Int) {
    guard let column = columns[safe: columnIndex],
      column.panes.indices.contains(paneIndex)
    else { return }

    let pane = column.panes.remove(at: paneIndex)
    // The pane is being torn out of the view tree; dismiss its
    // find bar so the orphaned panel doesn't linger as a child
    // window of the host. Per-pane persistence keeps bars alive on
    // focus changes, but pane removal is the one terminal event.
    if pane.isFindBarVisible {
      dismissFindSession(on: pane)
    }
    // Fire the close notification right after the model mutation so
    // a sync-call into `tabs(for:)` from inside `didCloseTab` no
    // longer reports the closed tab. Cached bridge is dropped here;
    // an undo / restore later will mint a fresh one.
    ExtensionController.shared.notifyTabClosed(pane)
    clearFocusBorder(pane)
    // The closed-pane stash keeps the WKWebView alive for the undo
    // window, and detaching the view alone does not stop the web
    // content process's media pipeline. Pause leaves the playhead in
    // place so an undo restore picks up where the user left off.
    pane.browserView?.webView.pauseAllMediaPlayback(completionHandler: nil)

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
    // slide without the entry being missed. Pass the owning
    // workspace explicitly: the pane has already been detached from
    // its column above, so a `workspaceContaining(pane:)` walk
    // inside the stash helper would come back nil and the private
    // gate would silently fall through.
    stashClosedPane(
      pane, in: currentWorkspace,
      columnIndex: columnIndex, paneIndex: paneIndex,
      columnWidth: columnWidth, wasOnlyPaneInColumn: wasOnlyPane)
    showToast("Close Pane")
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

  /// Look up the workspace owning `pane`. The walk is O(workspaces ×
  /// columns × panes) but in practice handful-per-handful, and pane
  /// callbacks fire often enough that an `id → workspace` index would
  /// add lifecycle bookkeeping for negligible savings. Used by
  /// browser callbacks so private workspaces can suppress history
  /// writes and closed-pane stashing.
  func workspaceContaining(pane: PaneModel) -> WorkspaceModel? {
    for workspace in workspaces {
      for column in workspace.columns
      where column.panes.contains(where: { $0.id == pane.id }) {
        return workspace
      }
    }
    return nil
  }

  private func stashClosedPane(
    _ pane: PaneModel, in workspace: WorkspaceModel,
    columnIndex: Int, paneIndex: Int,
    columnWidth: CGFloat?, wasOnlyPaneInColumn: Bool
  ) {
    // Private workspaces never feed the closed-pane undo stash —
    // restoring a closed private tab from another workspace would
    // leak the URL the user was deliberately browsing privately. The
    // pane's surface still gets released through the regular detach
    // path, just without the 10-second undo window. The workspace
    // arrives by parameter because the caller has already detached
    // the pane from its column, leaving `workspaceContaining(pane:)`
    // unable to recover the owner.
    if workspace.isPrivate {
      pane.terminalView?.releaseDetachedSurface()
      return
    }
    // Evict oldest if at capacity — must explicitly release detached surfaces
    while recentlyClosed.count >= Self.maxRecentlyClosed {
      let evicted = recentlyClosed.removeFirst()
      evicted.timer.invalidate()
      evicted.pane.terminalView?.releaseDetachedSurface()
      // Pause once more before the WKWebView heads for ARC release.
      // The first pause was at `removePane` time; an autoplay SPA's
      // own scripts can resume playback during the stash window, and
      // ARC release runs through the web content process at its own
      // pace.
      evicted.pane.browserView?.webView.pauseAllMediaPlayback(completionHandler: nil)
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
          expired.pane.browserView?.webView.pauseAllMediaPlayback(completionHandler: nil)
        }
      }
    }
    let closed = ClosedPane(
      pane: pane, workspaceId: workspace.id,
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
    else {
      // Private workspaces never feed the stash, so a request from a
      // private workspace always lands here. Surfacing the reason
      // separates "nothing to reopen" (stash empty) from "private
      // workspaces don't keep history" — both are user-visible no-ops
      // but the second one needs the explanation to feel intentional.
      if currentWorkspace.isPrivate {
        showToast("Can't reopen closed pane in a private workspace", style: .error)
      } else {
        showToast("Nothing to reopen", style: .error)
      }
      return
    }
    let closed = recentlyClosed.remove(at: idx)
    closed.timer.invalidate()
    showToast("Reopen Closed Pane")

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
      // Restored pane re-enters the extension's tab graph as a
      // fresh tab — `notifyTabClosed` dropped the previous bridge
      // identity, so the undo restore needs a matching open.
      ExtensionController.shared.notifyTabOpened(pane)

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

  /// Close any pane by id, regardless of which workspace owns it.
  /// Used by the sidebar worklane's hover-revealed × button.
  ///
  /// Current-workspace closes route to `removePane(columnIndex:paneIndex:)`
  /// so the user sees the same fade / column-collapse animation as a
  /// click on the in-pane × button. Non-current closes operate
  /// directly on the target workspace's model and stack view —
  /// switching just to play the close animation against an off-screen
  /// workspace would add a slide the user didn't ask for and never
  /// gets to see. Cross-workspace closes do not stash an undo entry:
  /// the existing recently-closed pipeline is rooted in current-WS
  /// state and per-workspace by design.
  public func closePane(id paneId: ULID) {
    guard let loc = locatePane(id: paneId) else { return }
    if loc.workspaceIndex == focusedWorkspaceIndex {
      removePane(columnIndex: loc.columnIndex, paneIndex: loc.paneIndex)
    } else {
      removePaneInBackgroundWorkspace(
        wsIndex: loc.workspaceIndex,
        columnIndex: loc.columnIndex,
        paneIndex: loc.paneIndex)
    }
  }

  /// Flip the mute flag on a pane found by id across every workspace.
  /// Sidebar audio indicators route here so the toggle works on rows
  /// outside the focused workspace too — focus is intentionally not
  /// shifted, since muting from the sidebar is a one-shot action.
  public func toggleMuteForPane(id paneId: ULID) {
    locatePane(id: paneId)?.pane.browserView?.toggleMute()
  }

  /// Apply `muted` to every already-open browser pane whose current
  /// URL host matches `host` (case-insensitive). The site-mute menu
  /// uses this so a "Mute this Site" toggle takes effect on every
  /// in-flight tab rather than only the one the menu opened from;
  /// panes that load the host *after* the toggle pick the value up
  /// through `BrowserPaneView.applySiteMutePreference` on
  /// navigation finish.
  public func applyMuteToPanes(matchingHost host: String, muted: Bool) {
    let target = host.lowercased()
    for ws in workspaces {
      for col in ws.columns {
        for pane in col.panes {
          guard let bv = pane.browserView,
            !bv.isExtensionHosted,
            let paneHost = bv.webView.url?.host(percentEncoded: false),
            paneHost.lowercased() == target
          else { continue }
          bv.setMuted(muted)
        }
      }
    }
  }

  /// Resolved coordinate of a pane found by id. Carries the
  /// surrounding indices alongside the model so call sites can
  /// either operate on the pane directly or feed the indices back
  /// into view-tree mutators (`removePane(columnIndex:paneIndex:)`,
  /// `removePaneInBackgroundWorkspace(wsIndex:...)`).
  public struct PaneLocation {
    public let workspaceIndex: Int
    public let columnIndex: Int
    public let paneIndex: Int
    public let pane: PaneModel
  }

  /// Locate a pane by id across every workspace. Replaces the
  /// triple-nested search that earlier sat in `closePane(id:)` and
  /// `toggleMuteForPane(id:)`; future cross-workspace pane
  /// operations should funnel through the same helper.
  public func locatePane(id paneId: ULID) -> PaneLocation? {
    for (wsIdx, ws) in workspaces.enumerated() {
      for (colIdx, col) in ws.columns.enumerated() {
        if let paneIdx = col.panes.firstIndex(where: { $0.id == paneId }) {
          return PaneLocation(
            workspaceIndex: wsIdx,
            columnIndex: colIdx,
            paneIndex: paneIdx,
            pane: col.panes[paneIdx])
        }
      }
    }
    return nil
  }

  /// Remove a pane from a non-current workspace without animating —
  /// the workspace's view is hidden so a tween would only delay the
  /// model update. Mirrors the bookkeeping of
  /// `removePane(columnIndex:paneIndex:)` minus the focus / scroll /
  /// undo machinery, which is current-WS only. The pane being
  /// removed itself isn't stashed for undo; if removing it empties
  /// the workspace, the cascade into `closeWorkspace(at:)` runs
  /// `flushRecentlyClosed(in:)` on the way out, releasing any *other*
  /// stash entries that were captured while this workspace was
  /// previously current.
  private func removePaneInBackgroundWorkspace(
    wsIndex: Int, columnIndex: Int, paneIndex: Int
  ) {
    guard workspaces.indices.contains(wsIndex) else { return }
    let ws = workspaces[wsIndex]
    let vc = workspaceVCs[wsIndex]
    guard ws.columns.indices.contains(columnIndex),
      ws.columns[columnIndex].panes.indices.contains(paneIndex)
    else { return }

    let column = ws.columns[columnIndex]
    let pane = column.panes.remove(at: paneIndex)
    ExtensionController.shared.notifyTabClosed(pane)
    clearFocusBorder(pane)
    // Cross-WS close skips the undo stash, so release the surface
    // eagerly rather than detaching it.
    pane.terminalView?.keepSurfaceAlive = false
    pane.browserView?.webView.pauseAllMediaPlayback(completionHandler: nil)
    pane.containerView.removeFromSuperview()

    if column.panes.isEmpty {
      ws.columns.remove(at: columnIndex)
      column.containerView.removeFromSuperview()
      if ws.columns.isEmpty {
        // Last pane in last column → workspace itself is empty;
        // tear it down through the same path the × on the workspace
        // header would take.
        closeWorkspace(at: wsIndex)
        return
      }
      ws.focusedColumnIndex = min(columnIndex, ws.columns.count - 1)
      rebuildStackView(in: vc)
    } else {
      column.focusedPaneIndex = min(paneIndex, column.panes.count - 1)
      rebuildColumnView(column: column)
    }
    notifySidebarWorklaneDidChange()
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
          logger.error("close alert: target pane not in current WS")
          return
        }
        self.removePane(columnIndex: colIdx, paneIndex: paneIdx)
      }
      return
    }
    removePane(columnIndex: focusedColumnIndex, paneIndex: column.focusedPaneIndex)
  }
}
