import AppKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "URLBarHover")

extension PaneContainerViewController {
  /// Hover-in delay before a peek opens. Tight enough that a
  /// deliberate cursor flick to the pane's top edge feels snappy,
  /// long enough that grazing the edge while reaching for traffic
  /// lights or the sidebar doesn't false-trigger.
  static let urlBarHoverInDelay: TimeInterval = 0.05
  /// Hover-out delay before a peek collapses. Generous so the user
  /// has time to drift from the hit zone down onto the URL bar
  /// itself and start typing without the bar disappearing under
  /// them.
  static let urlBarHoverOutDelay: TimeInterval = 0.30

  /// Wire both the top-edge hit zone and the URL bar itself so
  /// cursor entry / exit on either drives the per-pane peek state
  /// through the debounced scheduler. The bar is laid out below the
  /// hit zone — without the bar's own hover tracking, sliding the
  /// cursor down from the edge zone onto the URL field would
  /// register as a hover-out and collapse the peek mid-aim. Called
  /// once per pane by `setupPaneCallbacks`; the closures capture
  /// the pane weakly so deallocation tears the scheduling down on
  /// its own.
  func wireURLBarHoverScheduler(pane: PaneModel) {
    pane.urlBarTopEdgeHitZone.onEnter = { [weak self, weak pane] in
      guard let self, let pane else { return }
      self.scheduleURLBarHoverIn(pane: pane)
    }
    pane.urlBarTopEdgeHitZone.onExit = { [weak self, weak pane] in
      guard let self, let pane else { return }
      self.scheduleURLBarHoverOut(pane: pane)
    }
    pane.urlBar.onHoverEnter = { [weak self] in
      self?.cancelURLBarHoverOut()
    }
    pane.urlBar.onHoverExit = { [weak self, weak pane] in
      guard let self, let pane else { return }
      self.scheduleURLBarHoverOut(pane: pane)
    }
  }

  /// Cancel a pending hover-out fire. Called when the cursor crosses
  /// from the top-edge hit zone onto the URL bar itself — the user
  /// is still inside the hover surface, just on a different sibling,
  /// so the pending collapse should be discarded. Touches only the
  /// out-side counter; any pending hover-in keeps its stamp and
  /// fires normally.
  func cancelURLBarHoverOut() {
    guard !urlBarVisible else { return }
    urlBarHoverOutGeneration &+= 1
    urlBarHoverOutTimer?.invalidate()
    urlBarHoverOutTimer = nil
  }

  /// Stop the entire scheduler. Called when the global toggle flips
  /// on (every pane is now pinned, hover paths have nothing to
  /// add) so a leftover collapse fire from before the toggle can't
  /// racewith the just-applied `.pinned` state. The next hover
  /// event after the toggle re-arms the appropriate timer from a
  /// clean slate.
  func cancelAllURLBarHoverScheduling() {
    urlBarHoverInGeneration &+= 1
    urlBarHoverInTimer?.invalidate()
    urlBarHoverInTimer = nil
    urlBarHoverOutGeneration &+= 1
    urlBarHoverOutTimer?.invalidate()
    urlBarHoverOutTimer = nil
  }

  /// Defer a peek-open by `urlBarHoverInDelay` and arm a generation
  /// stamp so a competing exit between scheduling and firing
  /// invalidates this fire. The global toggle short-circuits the
  /// scheduler entirely — when the bar is already pinned the hover
  /// path has nothing to add.
  func scheduleURLBarHoverIn(pane: PaneModel) {
    guard !urlBarVisible else { return }
    // Schedule-time focus guard: a hit zone whose pane has lost
    // focus has no business opening a peek. The fire-time guard
    // below catches the race where focus changes during the 50ms
    // wait, but bailing early avoids burning a generation on a
    // schedule that was dead on arrival — which keeps the in / out
    // counters from drifting apart for no good reason.
    guard focusedPane?.id == pane.id else { return }
    // A hit zone enter also abandons any pending close — a peek
    // that's about to open shouldn't be torn down by a stale
    // collapse from the previous session.
    urlBarHoverOutGeneration &+= 1
    urlBarHoverOutTimer?.invalidate()
    urlBarHoverOutTimer = nil
    urlBarHoverInGeneration &+= 1
    let gen = urlBarHoverInGeneration
    urlBarHoverInTimer?.invalidate()
    logger.debug("scheduleURLBarHoverIn pane=\(String(describing: pane.id), privacy: .public) gen=\(gen)")
    urlBarHoverInTimer = Timer.scheduledTimer(
      withTimeInterval: Self.urlBarHoverInDelay,
      repeats: false
    ) { [weak self, weak pane] _ in
      DispatchQueue.main.async {
        guard let self, let pane else { return }
        // Generation guard: a competing in-side schedule bumped the
        // counter while we were waiting, so this fire is stale.
        guard gen == self.urlBarHoverInGeneration else { return }
        // Focus guard: peek belongs to the focused pane only. A
        // fast focus change between scheduling and firing would
        // otherwise unfurl the bar on a no-longer-active pane.
        guard self.focusedPane?.id == pane.id else { return }
        pane.setURLBarPeek(true)
      }
    }
  }

  /// Defer a peek-collapse by `urlBarHoverOutDelay`. The out-side
  /// generation stamp lets a hover-in that arrives during the wait
  /// cancel the collapse via `cancelURLBarHoverOut`. Pinned bars
  /// are owned by the global flag and bypass the scheduler.
  ///
  /// The hover surface is the URL bar's entire 28pt rect — the
  /// 12pt hit zone above it is just a sliver of the same surface
  /// used to catch the cursor while the bar is still invisible. A
  /// hit-zone exit therefore doesn't always mean the cursor has
  /// left the hover surface: it may simply have crossed onto the
  /// bar's main body. Probe the cursor against the bar's bounds
  /// before scheduling a collapse so hand-offs within the hover
  /// surface stay invisible to the scheduler. The bar's own
  /// `mouseExited` (which fires only when the cursor actually
  /// leaves the bar) is the real signal that closes the peek.
  func scheduleURLBarHoverOut(pane: PaneModel) {
    guard !urlBarVisible else { return }
    if pane.urlBar.cursorIsStillInsideBounds() { return }
    // Cursor left the hover surface — any pending hover-in is moot.
    // Drop the in-side timer so a hit zone enter that hasn't fired
    // yet doesn't end up opening a peek behind a cursor that's
    // already gone.
    urlBarHoverInGeneration &+= 1
    urlBarHoverInTimer?.invalidate()
    urlBarHoverInTimer = nil
    urlBarHoverOutGeneration &+= 1
    let gen = urlBarHoverOutGeneration
    urlBarHoverOutTimer?.invalidate()
    logger.debug("scheduleURLBarHoverOut pane=\(String(describing: pane.id), privacy: .public) gen=\(gen)")
    urlBarHoverOutTimer = Timer.scheduledTimer(
      withTimeInterval: Self.urlBarHoverOutDelay,
      repeats: false
    ) { [weak self, weak pane] _ in
      DispatchQueue.main.async {
        guard let self, let pane else { return }
        guard gen == self.urlBarHoverOutGeneration else { return }
        pane.setURLBarPeek(false)
      }
    }
  }
}
