import AppKit

extension PaneContainerViewController {
  // MARK: - Find in Page

  /// Open the find bar on the focused browser pane. When the URL bar
  /// is hidden it is revealed first so the pane's bar stack has a
  /// populated row above it (mirroring `focusURLBar`'s behaviour).
  /// Switching between panes rebinds the shared callback set to the
  /// new target so ⌘G / ⌘⇧G always refer to the pane whose bar is
  /// currently revealed.
  public func openFindBar() {
    guard isFocusedPaneBrowser, let pane = focusedPane else { return }
    if !urlBarVisible {
      toggleURLBarVisibility()
    }
    // If a previous session still has its bar revealed on another
    // pane, dismiss it end-to-end first — each pane has its own bar
    // and we want only the newly-targeted one visible, with the
    // underlying find session ended so no highlight state leaks
    // between panes.
    if let previous = findBarTargetPane, previous !== pane {
      dismissFindSession(on: previous)
    }
    wireFindBarCallbacks(on: pane)
    findBarTargetPane = pane
    pane.setFindBarVisible(true)
    pane.findBar.focusField()
    // Re-run find + position query against whatever needle the field
    // still carries from a previous session on this pane. Without
    // this the position label would show stale or empty values until
    // the user types another character.
    let needle = pane.findBar.searchText
    if needle.isEmpty {
      pane.findBar.setMatchPosition(current: nil, total: nil)
    } else {
      pane.browserView?.performFind(needle, forward: true)
      scheduleMatchPositionUpdate(needle: needle, pane: pane)
    }
  }

  /// Advance to the next match. When no bar is currently revealed — a
  /// cold ⌘G with no open session — fall back to opening the bar
  /// against the focused pane, matching Safari's resume behaviour.
  public func findNext() {
    guard let target = findBarTargetPane, target.isFindBarVisible else {
      openFindBar()
      return
    }
    guard let helper = currentFindHelper() else {
      closeFindBar()
      return
    }
    let needle = target.findBar.searchText
    helper.performFind(needle, forward: true)
    scheduleMatchPositionUpdate(needle: needle, pane: target)
  }

  /// Step to the previous match. Same fallbacks as `findNext`.
  public func findPrev() {
    guard let target = findBarTargetPane, target.isFindBarVisible else {
      openFindBar()
      return
    }
    guard let helper = currentFindHelper() else {
      closeFindBar()
      return
    }
    let needle = target.findBar.searchText
    helper.performFind(needle, forward: false)
    scheduleMatchPositionUpdate(needle: needle, pane: target)
  }

  /// Hide the target pane's find bar and end the current session.
  /// Safe to call when the bar has never been opened or the target
  /// pane has been released.
  public func closeFindBar() {
    guard let target = findBarTargetPane, target.isFindBarVisible else { return }
    dismissFindSession(on: target)
    findBarTargetPane = nil
  }

  // MARK: - Internals

  /// Collapse `pane`'s bar and end its underlying find session as a
  /// single atomic step. Shared by `openFindBar` (handing off between
  /// panes) and `closeFindBar` (user-driven dismiss) so the two paths
  /// can never drift out of step — once JS-channel highlight clearing
  /// lands in `BrowserPaneView.endFind`, both paths pick it up
  /// automatically.
  private func dismissFindSession(on pane: PaneModel) {
    findCountDebounceTimer?.invalidate()
    findCountDebounceTimer = nil
    pane.findBar.setMatchPosition(current: nil, total: nil)
    pane.setFindBarVisible(false)
    pane.browserView?.endFind()
  }

  /// Bind the shared container-side callback set onto the supplied
  /// pane's bar. The same set is re-bound on every `openFindBar` so
  /// the closures always capture the latest target pane directly,
  /// avoiding a round-trip through `findBarTargetPane` inside the
  /// incremental-search hot path.
  private func wireFindBarCallbacks(on pane: PaneModel) {
    let bar = pane.findBar
    bar.onSearch = { [weak self, weak pane] needle in
      guard let helper: FindHelper = pane?.browserView else { return }
      helper.performFind(needle, forward: true)
      self?.scheduleMatchPositionUpdate(needle: needle, pane: pane)
    }
    bar.onNext = { [weak self] in self?.findNext() }
    bar.onPrev = { [weak self] in self?.findPrev() }
    bar.onClose = { [weak self] in self?.closeFindBar() }
  }

  /// Coalesce match-position queries behind a 200ms debounce so fast
  /// typing and navigation spam don't spawn one
  /// `callAsyncJavaScript` per keystroke. The completion guards
  /// against a stale needle (the user may have typed further while
  /// the debounce ran) so the label only updates when still
  /// pointing at the query that scheduled the fetch.
  private func scheduleMatchPositionUpdate(needle: String, pane: PaneModel?) {
    findCountDebounceTimer?.invalidate()
    guard let pane else { return }
    guard !needle.isEmpty else {
      pane.findBar.setMatchPosition(current: nil, total: nil)
      return
    }
    findCountDebounceTimer = Timer.scheduledTimer(
      withTimeInterval: 0.2, repeats: false
    ) { [weak self, weak pane] _ in
      DispatchQueue.main.async {
        guard let self, let pane, let browserView = pane.browserView else { return }
        // Verify the session still targets this pane. A background
        // workspace switch or close could have rerouted things
        // during the debounce window.
        guard self.findBarTargetPane === pane else { return }
        browserView.queryMatchPosition(needle) { position in
          guard pane.findBar.searchText == needle else { return }
          pane.findBar.setMatchPosition(current: position.current, total: position.total)
        }
      }
    }
  }

  private func currentFindHelper() -> FindHelper? {
    findBarTargetPane?.browserView
  }
}
