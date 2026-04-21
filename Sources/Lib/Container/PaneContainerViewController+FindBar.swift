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
    guard let pane = focusedPane, pane.findHelper != nil else { return }
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
    // Re-run find against whatever needle the field still carries
    // from a previous session on this pane. Without this the
    // position label would show stale or empty values until the
    // user types another character.
    let needle = pane.findBar.searchText
    if needle.isEmpty {
      pane.findBar.setMatchPosition(current: nil, total: nil)
    } else {
      applyFindResult(needle: needle, forward: true, pane: pane)
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
    guard currentFindHelper() != nil else {
      closeFindBar()
      return
    }
    applyFindResult(needle: target.findBar.searchText, forward: true, pane: target)
  }

  /// Step to the previous match. Same fallbacks as `findNext`.
  public func findPrev() {
    guard let target = findBarTargetPane, target.isFindBarVisible else {
      openFindBar()
      return
    }
    guard currentFindHelper() != nil else {
      closeFindBar()
      return
    }
    applyFindResult(needle: target.findBar.searchText, forward: false, pane: target)
  }

  /// Hide the target pane's find bar and end the current session.
  /// Safe to call when the bar has never been opened or the target
  /// pane has been released.
  public func closeFindBar() {
    guard let target = findBarTargetPane, target.isFindBarVisible else { return }
    dismissFindSession(on: target)
    // Return first responder to the pane content so terminal input or
    // WKWebView keystrokes resume immediately; without this the
    // collapsed search field keeps responder status and eats the next
    // keypress. Mirrors the URL bar's `onCancel` path in
    // `PaneContainerViewController+Panes.swift`. Focus-change callers
    // (`setFocus`) overwrite this responder a few lines later with the
    // new pane's target, so there's no flicker for that path.
    target.containerView.window?.makeFirstResponder(target.preferredFirstResponder)
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
    pane.findHelper?.endFind()
  }

  /// Bind the shared container-side callback set onto the supplied
  /// pane's bar. The same set is re-bound on every `openFindBar` so
  /// the closures always capture the latest target pane directly,
  /// avoiding a round-trip through `findBarTargetPane` inside the
  /// incremental-search hot path.
  private func wireFindBarCallbacks(on pane: PaneModel) {
    let bar = pane.findBar
    // `onSearch` fires per keystroke and walks the DOM, so route it
    // through the debounce. `onNext` / `onPrev` are explicit user
    // gestures and dispatch synchronously for snappy keyboard nav.
    bar.onSearch = { [weak self, weak pane] needle in
      guard let pane else { return }
      self?.scheduleFindUpdate(needle: needle, forward: true, pane: pane)
    }
    bar.onNext = { [weak self] in self?.findNext() }
    bar.onPrev = { [weak self] in self?.findPrev() }
    bar.onClose = { [weak self] in self?.closeFindBar() }
  }

  /// Coalesce keystroke-driven find invocations behind a 200ms
  /// debounce so fast typing doesn't spawn one
  /// `callAsyncJavaScript` per character. The completion guards on
  /// the current search text so stale returns can't overwrite a
  /// newer label.
  private func scheduleFindUpdate(needle: String, forward: Bool, pane: PaneModel) {
    findCountDebounceTimer?.invalidate()
    guard !needle.isEmpty else {
      pane.findHelper?.endFind()
      pane.findBar.setMatchPosition(current: nil, total: nil)
      return
    }
    findCountDebounceTimer = Timer.scheduledTimer(
      withTimeInterval: 0.2, repeats: false
    ) { [weak self, weak pane] _ in
      DispatchQueue.main.async {
        guard let self, let pane else { return }
        // Verify the session still targets this pane. A background
        // workspace switch or close could have rerouted things
        // during the debounce window.
        guard self.findBarTargetPane === pane else { return }
        self.applyFindResult(needle: needle, forward: forward, pane: pane)
      }
    }
  }

  /// Dispatch the find and thread the `(total, current)` result back
  /// into the bar. Guards on the current search text so a slow
  /// return from an older keystroke can't overwrite a newer label.
  private func applyFindResult(needle: String, forward: Bool, pane: PaneModel) {
    guard let helper = pane.findHelper else { return }
    helper.performFind(needle, forward: forward) { position in
      guard pane.findBar.searchText == needle else { return }
      pane.findBar.setMatchPosition(current: position.current, total: position.total)
    }
  }

  private func currentFindHelper() -> FindHelper? {
    findBarTargetPane?.findHelper
  }
}
