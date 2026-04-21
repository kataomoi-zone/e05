import AppKit

extension PaneContainerViewController {
  // MARK: - Find in Page

  /// Open the find bar against the focused browser pane, constructing
  /// it on first use. When the URL bar is currently hidden it is
  /// revealed first so the find bar has a stable anchor row to slot
  /// underneath (mirroring `focusURLBar`'s URL-bar-reveal behaviour).
  public func openFindBar() {
    guard isFocusedPaneBrowser, let pane = focusedPane else { return }
    if !urlBarVisible {
      toggleURLBarVisibility()
    }
    let bar = ensureFindBar()
    findBarTargetPane = pane
    positionFindBar(below: pane)
    bar.isHidden = false
    bar.focusField()
  }

  /// Advance to the next match. When the bar is not yet visible — a
  /// cold ⌘G invocation with no open session — fall back to opening
  /// the bar against the focused pane, matching Safari's behaviour of
  /// resuming a find session from the menu or keyboard without the
  /// user having to re-open the bar first.
  public func findNext() {
    guard let bar = findBar, !bar.isHidden else {
      openFindBar()
      return
    }
    guard let helper = currentFindHelper() else {
      // The retained target pane went away (closed or released via
      // weak deref) while the bar was open. Close the stranded bar
      // rather than silently no-op'ing; the target is gone, so a
      // subsequent user action should start a fresh session.
      closeFindBar()
      return
    }
    helper.performFind(bar.searchText, forward: true)
  }

  /// Step to the previous match. Same fallbacks as `findNext`.
  public func findPrev() {
    guard let bar = findBar, !bar.isHidden else {
      openFindBar()
      return
    }
    guard let helper = currentFindHelper() else {
      closeFindBar()
      return
    }
    helper.performFind(bar.searchText, forward: false)
  }

  /// Hide the find bar and end the current session. Safe to call when
  /// the bar has never been opened.
  public func closeFindBar() {
    guard let bar = findBar, !bar.isHidden else { return }
    bar.isHidden = true
    if let helper = currentFindHelper() {
      helper.endFind()
    }
    findBarTargetPane = nil
  }

  // MARK: - Internals

  private func ensureFindBar() -> FindBarView {
    if let existing = findBar { return existing }
    let bar = FindBarView(frame: .zero)
    // `onSearch` fires on every keystroke and doubles as the
    // incremental-forward driver so the initial match lands without
    // the user pressing Return. Subsequent Return / ⌘G / ⌘⇧G go
    // through findNext / findPrev and reuse the retained searchText.
    bar.onSearch = { [weak self] needle in
      guard let self, let helper = self.currentFindHelper() else { return }
      helper.performFind(needle, forward: true)
    }
    bar.onNext = { [weak self] in self?.findNext() }
    bar.onPrev = { [weak self] in self?.findPrev() }
    bar.onClose = { [weak self] in self?.closeFindBar() }
    findBar = bar
    return bar
  }

  /// Anchor the find bar flush with the bottom edge of the supplied
  /// pane's URL bar using manual frame placement. Width matches the
  /// URL bar so the two stack as a single visual column. Coordinates
  /// are resolved against the window content view, which uses the
  /// default AppKit bottom-left origin.
  private func positionFindBar(below pane: PaneModel) {
    guard let bar = findBar, let container = view.window?.contentView else { return }
    if bar.superview !== container {
      bar.removeFromSuperview()
      container.addSubview(bar)
    }
    let urlBar = pane.urlBar
    let urlFrame = urlBar.convert(urlBar.bounds, to: container)
    bar.frame = NSRect(
      x: urlFrame.minX,
      y: urlFrame.minY - FindBarView.barHeight,
      width: urlFrame.width,
      height: FindBarView.barHeight
    )
  }

  private func currentFindHelper() -> FindHelper? {
    findBarTargetPane?.browserView
  }
}
