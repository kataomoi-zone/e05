import AppKit

extension PaneContainerViewController {
  // MARK: - Find in Page

  /// Open the find bar on the focused browser pane. The bar floats
  /// over the pane content as a bottom-anchored pill, so opening it
  /// is independent of the URL bar's visibility — both can be toggled
  /// freely without visual conflict. Switching between panes rebinds
  /// the shared callback set to the new target so ⌘G / ⌘⇧G always
  /// refer to the pane whose bar is currently revealed.
  public func openFindBar() {
    guard let pane = focusedPane, let helper = pane.findHelper else { return }
    // Per-pane persistence: each pane keeps its own find bar state
    // across focus changes, so opening on a new pane no longer
    // dismisses the previous pane's session. The bars coexist as
    // independent child panels.
    wireFindBarCallbacks(on: pane)
    // Configure the bar's stepping affordance per pane kind: browser
    // / terminal step through matches, finder filters the row list.
    // Re-applied on every open so a pane swap (browser → finder)
    // refreshes the buttons even though the same pane's bar instance
    // is reused.
    pane.findBar.setSteppingEnabled(helper.supportsStepping)
    pane.setFindBarVisible(true)
    pane.findBar.focusField()
    // ⌘F never auto-advances. The needle retained in the field
    // from a prior session stays put; the user steps explicitly
    // via Return / ⌘G or types to search anew. `performFind`
    // doesn't expose a stay-in-place mode, and `forward: true`
    // would walk past the previously highlighted match because the
    // DOM selection survives `endFind` — making ⌘F read like ⌘G.
    // The position label was cleared by `dismissFindSession` on the
    // prior close, so re-entry shows an empty count rather than a
    // stale "3 / 5".
  }

  /// Advance to the next match on the focused pane's bar. When the
  /// focused pane has no visible bar, fall back to opening one so
  /// ⌘G acts as a "start finding here" gesture (Safari/Chrome
  /// convention).
  public func findNext() {
    guard let pane = focusedPane else { return }
    guard pane.isFindBarVisible else {
      openFindBar()
      return
    }
    guard pane.findHelper != nil else {
      closeFindBar()
      return
    }
    applyFindResult(needle: pane.findBar.searchText, forward: true, pane: pane)
  }

  /// Step to the previous match on the focused pane's bar. Same
  /// fallbacks as `findNext`.
  public func findPrev() {
    guard let pane = focusedPane else { return }
    guard pane.isFindBarVisible else {
      openFindBar()
      return
    }
    guard pane.findHelper != nil else {
      closeFindBar()
      return
    }
    applyFindResult(needle: pane.findBar.searchText, forward: false, pane: pane)
  }

  /// Hide the focused pane's find bar and end its session. Safe to
  /// call when no bar is open. Used by Esc / × on the focused
  /// pane's bar and by workspace-slide pre-dismiss; non-focused
  /// panes' bars persist and are dismissed via their own onClose
  /// closure (see `wireFindBarCallbacks`).
  public func closeFindBar() {
    guard let pane = focusedPane, pane.isFindBarVisible else { return }
    dismissFindSession(on: pane)
    // Return first responder to the pane content so terminal input or
    // WKWebView keystrokes resume immediately; without this the
    // collapsed search field keeps responder status and eats the next
    // keypress.
    pane.containerView.window?.makeFirstResponder(pane.preferredFirstResponder)
  }

  // MARK: - Internals

  /// Collapse `pane`'s bar and end its underlying find session as a
  /// single atomic step.
  func dismissFindSession(on pane: PaneModel) {
    pane.findCountDebounceTimer?.invalidate()
    pane.findCountDebounceTimer = nil
    pane.findBar.setMatchPosition(current: nil, total: nil)
    pane.setFindBarVisible(false)
    pane.findHelper?.endFind()
  }

  /// Close every visible find bar across `workspace`'s panes. Used
  /// before workspace slides because per-pane persistence keeps
  /// non-focused bars open, but the find panels are children of the
  /// host window and don't follow `topConstraint` slide animation
  /// (no `boundsDidChange` / `didResize` fires for the panel during
  /// the slide), so without this they'd hover over the incoming
  /// workspace at their old screen positions.
  func dismissAllFindSessions(in workspace: WorkspaceModel) {
    for column in workspace.columns {
      for pane in column.panes where pane.isFindBarVisible {
        dismissFindSession(on: pane)
      }
    }
  }

  /// Bind the container-side callback set onto `pane`'s bar. Each
  /// callback captures the specific pane so a click on a non-focused
  /// pane's bar (e.g. the user mouses over to pane B's × while
  /// focus is still on pane A) routes to that pane's own session
  /// rather than to `focusedPane`. Re-bound on every `openFindBar`
  /// so the closure always carries the latest helper reference.
  private func wireFindBarCallbacks(on pane: PaneModel) {
    let bar = pane.findBar
    // `onSearch` fires per keystroke and walks the DOM, so route it
    // through the debounce. `onNext` / `onPrev` are explicit user
    // gestures and dispatch synchronously for snappy keyboard nav.
    bar.onSearch = { [weak self, weak pane] needle in
      guard let pane else { return }
      self?.scheduleFindUpdate(needle: needle, forward: true, pane: pane)
    }
    bar.onNext = { [weak self, weak pane] in
      guard let self, let pane, pane.isFindBarVisible else { return }
      let needle = pane.findBar.searchText
      guard !needle.isEmpty else { return }
      self.applyFindResult(needle: needle, forward: true, pane: pane)
    }
    bar.onPrev = { [weak self, weak pane] in
      guard let self, let pane, pane.isFindBarVisible else { return }
      let needle = pane.findBar.searchText
      guard !needle.isEmpty else { return }
      self.applyFindResult(needle: needle, forward: false, pane: pane)
    }
    bar.onClose = { [weak self, weak pane] in
      guard let self, let pane else { return }
      self.dismissFindSession(on: pane)
      pane.containerView.window?.makeFirstResponder(pane.preferredFirstResponder)
    }
    // Click on a non-focused pane's bar promotes that pane to focus
    // so subsequent ⌘G / ⌘⇧G / ⌘F target it. The panel's
    // `becomeKey` reaches us through this observer; routing through
    // `focusPane(id:)` rather than mutating `focusedPane*` directly
    // also drives sidebar refresh and the rest of the focus side
    // effects. `setFocus` doesn't reclaim the main window's key
    // status (only keyboard-driven focus paths do that), so the
    // panel keeps key state and the user's click intent on the
    // search field is honoured.
    bar.onPanelBecameKey = { [weak self, weak pane] in
      guard let self, let pane else { return }
      if self.focusedPane?.id != pane.id {
        self.focusPane(id: pane.id)
      }
    }
  }

  /// Coalesce keystroke-driven find invocations behind a 200ms
  /// debounce. The timer lives on `PaneModel` so concurrent typing
  /// in two panes' bars doesn't see one timer invalidating the
  /// other; the closure-captured pane reference also lets the stale
  /// guard fire on `pane.isFindBarVisible` rather than a single
  /// container-wide target.
  private func scheduleFindUpdate(needle: String, forward: Bool, pane: PaneModel) {
    pane.findCountDebounceTimer?.invalidate()
    guard !needle.isEmpty else {
      pane.findHelper?.endFind()
      pane.findBar.setMatchPosition(current: nil, total: nil)
      return
    }
    pane.findCountDebounceTimer = Timer.scheduledTimer(
      withTimeInterval: 0.2, repeats: false
    ) { [weak self, weak pane] _ in
      DispatchQueue.main.async {
        guard let self, let pane, pane.isFindBarVisible else { return }
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
}
