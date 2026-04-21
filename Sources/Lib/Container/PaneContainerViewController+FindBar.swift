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
    helper.performFind(target.findBar.searchText, forward: true)
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
    helper.performFind(target.findBar.searchText, forward: false)
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
    bar.onSearch = { [weak pane] needle in
      guard let helper: FindHelper = pane?.browserView else { return }
      helper.performFind(needle, forward: true)
    }
    bar.onNext = { [weak self] in self?.findNext() }
    bar.onPrev = { [weak self] in self?.findPrev() }
    bar.onClose = { [weak self] in self?.closeFindBar() }
  }

  private func currentFindHelper() -> FindHelper? {
    findBarTargetPane?.browserView
  }
}
