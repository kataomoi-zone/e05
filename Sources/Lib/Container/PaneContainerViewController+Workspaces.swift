import AppKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "Workspaces")

extension PaneContainerViewController {
  // MARK: - Accent color palette

  /// Palette mapped positionally: `palette[i % palette.count]` is the
  /// color for the workspace displayed as "Workspace \(i + 1)". Because
  /// it tracks array position — not an id baked into the workspace
  /// itself — number and color stay aligned when workspaces are added
  /// or removed. Resolved from
  /// ``E05Preferences/accentPalette`` on every read so a Settings tab
  /// change takes effect on the next paint without a restart; unknown
  /// identifiers fall back to ``AccentPalettePreset/subway``.
  @MainActor
  public static var accentColorPalette: [NSColor] {
    AccentPalettePreset.resolve(
      PreferencesStore.shared.preferences.accentPalette
    ).colors
  }

  /// Accent color for the workspace at `position`. Wraps via modulo so any
  /// non-negative index resolves to a palette entry, keeping this function
  /// total even when the workspace count exceeds the palette length.
  /// Falls back to `.systemBlue` if the palette itself is empty (a
  /// theoretically impossible state, guarded for safety).
  @MainActor
  public static func accentColor(forWorkspaceAt position: Int) -> NSColor {
    let palette = accentColorPalette
    guard !palette.isEmpty else { return .systemBlue }
    let safePosition = max(position, 0)
    return palette[safePosition % palette.count]
  }

  // MARK: - Switching

  /// Switch to the workspace at `index` with a vertical slide animation
  /// (`.slideUp` when moving to a higher index, `.slideDown` when lower —
  /// matches the ribari mental model of a vertical workspace list).
  /// Terminal surfaces in the outgoing workspace stay alive because each
  /// workspace's columns live in their own stackView and are never
  /// detached; only the child VC's view toggles visibility.
  /// Switch to the workspace at `index`.
  ///
  /// - Parameter slidingUp:
  ///   - `nil` (default): direction is derived from index comparison
  ///     (higher index = slide up). This is what command-palette-driven
  ///     "Switch to Workspace N" uses — the visual direction matches the
  ///     spatial relationship between the current and target workspaces.
  ///   - `true` / `false`: caller pins the direction. Next/Previous cycles
  ///     (`switchWorkspaceNext` / `switchWorkspacePrevious`) use this so
  ///     a wrap (e.g. 3 → 1) still slides in the "forward" direction
  ///     rather than reversing.
  ///
  /// The two conventions intentionally differ: palette-driven switches
  /// read like spatial navigation, cycle-driven switches read like
  /// sequential navigation. Both are correct for their use case.
  public func switchWorkspace(
    to index: Int,
    slidingUp: Bool? = nil,
    completion: (@MainActor @Sendable () -> Void)? = nil
  ) {
    let targetCol = workspaces[safe: index]?.focusedColumnIndex ?? -1
    let targetPane = workspaces[safe: index]?.columns[safe: workspaces[safe: index]?.focusedColumnIndex ?? 0]?.focusedPaneIndex ?? -1
    logger.info("switchWorkspace(to:\(index)) entry: focused=\(self.focusedWorkspaceIndex), wsCount=\(self.workspaces.count), targetCol=\(targetCol) targetPane=\(targetPane)")
    guard index != focusedWorkspaceIndex,
      workspaces.indices.contains(index)
    else {
      logger.debug("switchWorkspace guard failed")
      return
    }

    // Dismiss every visible find bar in the outgoing workspace and
    // the focused pane's URL bar suggestion dropdown before the
    // slide animation begins. Per-pane persistence keeps non-focused
    // panes' find bars alive across focus changes, but the find
    // panels are child windows of the host and don't follow the
    // workspace VC's slide; without an explicit pre-slide dismiss
    // they'd hover over the incoming workspace at their old screen
    // positions. The URL bar dropdown is single-pane so the
    // focusedPane variant suffices there.
    dismissAllFindSessions(in: currentWorkspace)
    focusedPane?.urlBar.dismissSuggestionDropdown()

    let outgoing = currentWorkspace
    outgoing.scrollX = scrollView.contentView.bounds.origin.x - hoverPeekScrollCompensation
    preserveSurfaces(in: outgoing)

    clearAllFocusBorders(in: outgoing)
    clearAllFocusBorders(in: workspaces[index])

    let fromVC = workspaceVCs[focusedWorkspaceIndex]
    let toVC = workspaceVCs[index]
    let resolvedSlidingUp = slidingUp ?? (index > focusedWorkspaceIndex)
    focusedWorkspaceIndex = index
    restoreScroll(in: currentWorkspace)
    showToast("Workspace \(index + 1)")
    animateSlide(fromVC: fromVC, toVC: toVC, slidingUp: resolvedSlidingUp) { [weak self] in
      self?.restoreFocusInCurrentWorkspace()
      completion?()
    }
  }

  /// Animate a vertical slide from `fromVC` to `toVC` by tweening each
  /// VC's top constraint. All workspace views stay installed; only the
  /// constraint constant changes. Using constraints (instead of manual
  /// `view.frame` animation with autoresizing) lets AppKit's layout pass
  /// interpolate each intermediate frame coherently — the flaky behavior
  /// where some slides appeared instantaneous was `animator().frame` on
  /// autoresize-managed views losing its animation to geometry sync.
  func animateSlide(
    fromVC: WorkspaceViewController,
    toVC: WorkspaceViewController,
    slidingUp: Bool,
    duration: TimeInterval = 0.25,
    completion: (@MainActor @Sendable () -> Void)? = nil
  ) {
    // Sidebar reveal/hide and workspace slide operate on disjoint
    // constraints (`leading` vs `top`), so the two animations can
    // run concurrently without stomping. Bailing here used to leave
    // `toVC.view.isHidden = true` even after `focusedWorkspaceIndex`
    // advanced, producing a blank window until the next switch.
    guard let fromTop = fromVC.topConstraint,
      let toTop = toVC.topConstraint
    else {
      logger.error("animateSlide missing constraints — from=\(fromVC.topConstraint == nil ? "nil" : "ok", privacy: .public) to=\(toVC.topConstraint == nil ? "nil" : "ok", privacy: .public)")
      completion?()
      return
    }

    let h = view.bounds.height

    // Flip the guard first — the layout pass triggered by
    // `layoutSubtreeIfNeeded` below would otherwise run `viewDidLayout`,
    // which resets every non-current VC's constant to ±h. Without this
    // guard, our just-set start position gets clobbered and the
    // animation runs from 0→0 (the "instantaneous switch" symptom).
    isAnimatingWorkspaceSwitch = true

    // Snap target to its start position and unhide it so the animation
    // below has a visible view to interpolate. `layoutSubtreeIfNeeded`
    // commits the start-frame layout before the animator kicks in.
    toTop.constant = slidingUp ? h : -h
    toVC.view.isHidden = false
    // Resync every terminal surface on the incoming workspace.
    // `updateSize` skips forwarding to ghostty while the view's
    // ancestor chain is hidden (scrollback-preservation guard), so
    // any window resize that happened while this workspace was
    // parked stays unsent. Without this reseed,
    // `ghostty_surface_set_size` is never called after the VC flips
    // back to visible — the surface keeps rendering at its last
    // pre-hide size and the pane shows a short strip of live output
    // with the remaining rows blacked out.
    for column in toVC.workspace.columns {
      for pane in column.panes {
        pane.terminalView?.resyncSurfaceSize()
      }
    }
    view.layoutSubtreeIfNeeded()

    logger.debug("animateSlide start: slidingUp=\(slidingUp ? "yes" : "no", privacy: .public) fromConst=\(fromTop.constant) toStart=\(toTop.constant) h=\(h)")

    NSAnimationContext.runAnimationGroup(
      { ctx in
        ctx.duration = duration
        ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ctx.allowsImplicitAnimation = true
        fromTop.animator().constant = slidingUp ? -h : h
        toTop.animator().constant = 0
        view.layoutSubtreeIfNeeded()
      },
      completionHandler: { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.isAnimatingWorkspaceSwitch = false
          logger.debug("animateSlide end: subviews=\(self.view.subviews.count)")
          // Order matters: move first responder to the target pane
          // BEFORE hiding the from-view. Otherwise AppKit sees the
          // current first responder land inside a hidden view, picks
          // the next-candidate (leftmost pane), and that pane's
          // `onFocusChanged` callback overwrites `ws.focusedColumnIndex`
          // to 0 before `restoreFocusInCurrentWorkspace` can run.
          completion?()
          fromVC.view.isHidden = true
        }
      })
  }

  public func switchWorkspace(toId id: ULID) {
    guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
    switchWorkspace(to: idx)
  }

  /// Advance to the next workspace with a consistent "slide up from below"
  /// direction, wrapping past the last one. Fixed direction matters when
  /// cycling — 3→1 should still feel like moving forward, not back.
  public func switchWorkspaceNext() {
    guard workspaces.count > 1 else { return }
    let next = (focusedWorkspaceIndex + 1) % workspaces.count
    switchWorkspace(to: next, slidingUp: true)
  }

  /// Backwards counterpart. Always slides down (incoming from above).
  public func switchWorkspacePrevious() {
    guard workspaces.count > 1 else { return }
    let prev = (focusedWorkspaceIndex - 1 + workspaces.count) % workspaces.count
    switchWorkspace(to: prev, slidingUp: false)
  }

  // MARK: - Creation

  /// Create a new workspace with an auto-assigned accent color and an
  /// initial terminal column, then slide it up into view. `isPrivate`
  /// propagates to the new workspace's panes: browser panes use an
  /// ephemeral `WKWebsiteDataStore`, history recording is skipped,
  /// closed-pane undo is disabled, and the focus border renders as
  /// a dotted line so the workspace reads as set apart at a glance.
  public func createWorkspace(isPrivate: Bool = false) {
    logger.info("createWorkspace entry: focused=\(self.focusedWorkspaceIndex), wsCount=\(self.workspaces.count), private=\(isPrivate ? "yes" : "no", privacy: .public)")

    dismissAllFindSessions(in: currentWorkspace)
    focusedPane?.urlBar.dismissSuggestionDropdown()

    let outgoing = currentWorkspace
    outgoing.scrollX = scrollView.contentView.bounds.origin.x - hoverPeekScrollCompensation
    preserveSurfaces(in: outgoing)
    clearAllFocusBorders(in: outgoing)

    let newWorkspace = WorkspaceModel(isPrivate: isPrivate)
    let newVC = WorkspaceViewController(workspace: newWorkspace)
    addChild(newVC)
    installWorkspaceView(newVC, makeCurrent: false)

    let fromVC = currentWorkspaceVC
    workspaces.append(newWorkspace)
    workspaceVCs.append(newVC)
    let newIndex = workspaces.count - 1

    // Advance focus so `addColumn` / `rebuildStackView` target the new
    // workspace's stackView via the computed accessors.
    focusedWorkspaceIndex = newIndex
    addColumn(address: .terminal)
    showToast(isPrivate ? "New Private Workspace" : "New Workspace")

    animateSlide(fromVC: fromVC, toVC: newVC, slidingUp: true) { [weak self] in
      self?.restoreFocusInCurrentWorkspace()
    }
  }

  // MARK: - Closing

  /// Close the current workspace. Flushes the recently-closed stack (its
  /// stashed surfaces belong to the workspace we're discarding) and
  /// terminates the app when the last workspace is gone.
  public func closeCurrentWorkspace() {
    logger.info("closeCurrentWorkspace entry: focused=\(self.focusedWorkspaceIndex), wsCount=\(self.workspaces.count)")
    dismissAllFindSessions(in: currentWorkspace)
    focusedPane?.urlBar.dismissSuggestionDropdown()
    let closing = currentWorkspace
    let closingVC = currentWorkspaceVC
    let closingIndex = focusedWorkspaceIndex

    for column in closing.columns {
      for pane in column.panes {
        pane.terminalView?.keepSurfaceAlive = false
        clearFocusBorder(pane)
        // Pair with the per-pane close path so a workspace-level
        // teardown is also silent. WKWebView keeps active media
        // playing past view detachment until its content process
        // releases.
        pane.browserView?.webView.pauseAllMediaPlayback(completionHandler: nil)
        // Mirror `removePane` so extensions see `chrome.tabs.onRemoved`
        // for every browser pane that goes down with the workspace —
        // bridges left in `tabBridgesByPaneID` would otherwise leak
        // identity until the next launch.
        ExtensionController.shared.notifyTabClosed(pane)
      }
    }

    flushRecentlyClosed(in: closing)

    if workspaces.count == 1 {
      // Last workspace: close the window without mutating the
      // arrays first. Going through `workspaces.remove(at:)` here
      // empties the model, and any callback that lands between
      // the remove and the application's actual termination —
      // responder chain queries, menu validation, layout passes
      // — reads through `currentWorkspace`, which trips its
      // `precondition(!workspaces.isEmpty, …)` and crashes the
      // dev build. Letting the arrays carry the (now-orphan)
      // workspace until process exit keeps every getter valid.
      view.window?.close()
      return
    }

    workspaces.remove(at: closingIndex)
    workspaceVCs.remove(at: closingIndex)

    let newIndex = min(closingIndex, workspaces.count - 1)
    focusedWorkspaceIndex = newIndex
    let toVC = workspaceVCs[newIndex]

    // Direction: closing index 0 contracts toward top (slide up). Any
    // higher index slides down, revealing what was above it.
    let slidingUp = closingIndex == 0
    restoreScroll(in: currentWorkspace)
    // The last-workspace branch above already returned, so this
    // toast only fires when there's a remaining workspace to land on.
    showToast("Close Workspace")

    animateSlide(fromVC: closingVC, toVC: toVC, slidingUp: slidingUp) { [weak self] in
      closingVC.view.removeFromSuperview()
      closingVC.removeFromParent()
      self?.restoreFocusInCurrentWorkspace()
    }
  }

  /// Close a workspace by index. Current-workspace closes route to
  /// `closeCurrentWorkspace` for the existing slide animation;
  /// non-current closes tear the workspace's view down without
  /// animating since the user can't see it on screen anyway —
  /// switching to a workspace just to dismiss it would burn a
  /// no-information slide.
  public func closeWorkspace(at index: Int) {
    guard workspaces.indices.contains(index) else { return }
    if index == focusedWorkspaceIndex {
      closeCurrentWorkspace()
      return
    }
    let closing = workspaces[index]
    let closingVC = workspaceVCs[index]
    logger.info("closeWorkspace(at:\(index)) non-current: focused=\(self.focusedWorkspaceIndex) wsCount=\(self.workspaces.count)")

    for column in closing.columns {
      for pane in column.panes {
        pane.terminalView?.keepSurfaceAlive = false
        clearFocusBorder(pane)
        pane.browserView?.webView.pauseAllMediaPlayback(completionHandler: nil)
        ExtensionController.shared.notifyTabClosed(pane)
      }
    }
    flushRecentlyClosed(in: closing)

    workspaces.remove(at: index)
    workspaceVCs.remove(at: index)
    closingVC.view.removeFromSuperview()
    closingVC.removeFromParent()

    // Closing a workspace at a smaller index shifts the focused
    // workspace one slot to the left in the array even though its
    // identity hasn't changed.
    if index < focusedWorkspaceIndex {
      focusedWorkspaceIndex -= 1
    }
    showToast("Close Workspace")
    notifySidebarWorklaneDidChange()
  }

  // MARK: - Reorder workspaces

  /// Rewrite `workspaces` / `workspaceVCs` so they appear in the
  /// order given by `orderedIds`. The focused workspace tracks its
  /// own identity through the shuffle (the index moves to wherever
  /// its id lands in the new order). Ids that don't currently
  /// resolve to a workspace are silently skipped — a stale id from
  /// a concurrent reload shouldn't error out the whole reorder.
  ///
  /// Used by the worklane sidebar's drag-reorder path. Accent
  /// colors are derived from position, so callers see them swap to
  /// match the new ordering on the next reload.
  public func reorderWorkspaces(orderedIds: [ULID]) {
    // Reject duplicate ids up front. The downstream compactMap would
    // resolve a duplicate to the same workspace twice and silently
    // drop a different one to keep `count` matching — `workspaces`
    // and `workspaceVCs` stay in sync with each other but lose a
    // workspace from the live tree.
    guard Set(orderedIds).count == orderedIds.count else {
      logger.warning(
        "[workspaces/reorder] duplicate ids in input count=\(orderedIds.count, privacy: .public)")
      return
    }
    let live = Dictionary(uniqueKeysWithValues: zip(workspaces.map(\.id), workspaces))
    let liveVCs = Dictionary(uniqueKeysWithValues: zip(workspaces.map(\.id), workspaceVCs))
    let resolved = orderedIds.compactMap { live[$0] }
    // Defence-in-depth: if every id was unknown nothing happens.
    // Bail before the parallel rewrite so the two arrays can't
    // get out of sync with each other.
    guard !resolved.isEmpty, resolved.count == workspaces.count else {
      logger.warning(
        """
        [workspaces/reorder] count mismatch: \
        ordered=\(orderedIds.count, privacy: .public) \
        live=\(self.workspaces.count, privacy: .public) \
        resolved=\(resolved.count, privacy: .public)
        """)
      return
    }
    // No-op when the order isn't actually changing — saves a
    // pointless reload and lets the worklane diff fall through to
    // its normal paths.
    if resolved.map(\.id) == workspaces.map(\.id) { return }

    let focusedId = workspaces[safe: focusedWorkspaceIndex]?.id
    workspaces = resolved
    workspaceVCs = orderedIds.compactMap { liveVCs[$0] }
    if let focusedId,
      let newIndex = workspaces.firstIndex(where: { $0.id == focusedId })
    {
      focusedWorkspaceIndex = newIndex
    }
    notifySidebarWorklaneDidChange()
  }

  // MARK: - Move pane across workspaces

  /// Cross-workspace drag entry point. Resolves the pane by id —
  /// importantly, does NOT call `focusPane(id:)` first. Going via
  /// focusPane would start a `switchWorkspace` animation and then
  /// our own slide animation immediately afterwards, and the two
  /// races blank out the pane area when the source ws happens to
  /// be off-screen at drop time. Used by the worklane sidebar's
  /// pane drop handler; palette / IPC callers still go through
  /// the focused-pane variant below.
  public func movePane(
    _ paneId: ULID, toWorkspaceId targetId: ULID, position: Int? = nil
  ) {
    logger.info("movePane(paneId:toWorkspaceId) entry")
    guard let loc = locatePane(id: paneId),
      let target = workspaces.firstIndex(where: { $0.id == targetId })
    else {
      logger.debug("movePane(paneId:) guard failed")
      return
    }
    performCrossWorkspaceMove(
      sourceIndex: loc.workspaceIndex,
      sourceColumnIndex: loc.columnIndex,
      sourcePaneIndex: loc.paneIndex,
      target: target,
      position: position)
  }

  /// Move the focused pane into the target workspace as a new
  /// single-pane column. `position` chooses the insertion index in
  /// the target's `columns` (`nil` = append at the trailing edge,
  /// the historical behaviour palette / IPC callers rely on); the
  /// worklane drag-drop path passes an explicit index resolved
  /// from the drop target. The pane's surface is preserved across
  /// the move; if the source column / workspace is left empty, it
  /// collapses per the standard invariants.
  public func movePane(toWorkspaceId id: ULID, position: Int? = nil) {
    logger.info("movePane(toWorkspaceId) entry: focused=\(self.focusedWorkspaceIndex)")
    guard let target = workspaces.firstIndex(where: { $0.id == id }),
      let column = columns[safe: focusedColumnIndex],
      let pane = column.focusedPane,
      let paneIndex = column.panes.firstIndex(where: { $0.id == pane.id })
    else {
      logger.debug("movePane guard failed")
      return
    }
    performCrossWorkspaceMove(
      sourceIndex: focusedWorkspaceIndex,
      sourceColumnIndex: focusedColumnIndex,
      sourcePaneIndex: paneIndex,
      target: target,
      position: position)
  }

  /// Shared implementation for both focused-pane and id-based
  /// cross-workspace moves. `sourceIndex` / `sourceColumnIndex` /
  /// `sourcePaneIndex` identify the pane to relocate; `target`
  /// identifies the destination workspace's array position and
  /// `position` chooses the column-insert index inside it.
  private func performCrossWorkspaceMove(
    sourceIndex: Int,
    sourceColumnIndex: Int,
    sourcePaneIndex: Int,
    target: Int,
    position: Int?
  ) {
    let sourceWs = workspaces[sourceIndex]
    let sourceVC = workspaceVCs[sourceIndex]
    let column = sourceWs.columns[sourceColumnIndex]
    let pane = column.panes[sourcePaneIndex]
    // Dismissals only matter for the currently-visible workspace.
    // For a sidebar drag where the dragged pane sits in a background
    // workspace, there's no find bar / URL bar suggestion to chase.
    if sourceIndex == focusedWorkspaceIndex {
      dismissAllFindSessions(in: sourceWs)
      focusedPane?.urlBar.dismissSuggestionDropdown()
    }
    // Block cross-private-boundary moves: a `WKWebView`'s
    // `WKWebsiteDataStore` is bound at construction time, so
    // moving a pane across the boundary would either leak the
    // public profile's cookies into a private workspace's UI
    // (public → private) or strand a still-ephemeral webView
    // inside a public workspace (private → public). Both shapes
    // mean the dotted/solid focus border stops mirroring the
    // actual storage scope. Surfacing as a no-op + log is safer
    // than reconstructing the webView mid-move (which loses back/
    // forward and any in-flight state). Reopen the URL with
    // ⌘N / ⌘⇧N in the desired workspace instead.
    let sourceIsPrivate = sourceWs.isPrivate
    if sourceIsPrivate != workspaces[target].isPrivate {
      logger.error("movePane blocked: cross-private-boundary move (source=\(sourceIsPrivate ? "private" : "public", privacy: .public), target=\(self.workspaces[target].isPrivate ? "private" : "public", privacy: .public))")
      showCrossPrivateBoundaryToast()
      return
    }

    // Snapshot the live scroll offset only when source is currently
    // visible — for a background source the persisted `scrollX` is
    // already accurate (last switch away captured it).
    if sourceIndex == focusedWorkspaceIndex {
      sourceWs.scrollX = sourceVC.scrollView.contentView.bounds.origin.x - hoverPeekScrollCompensation
    }
    preserveSurfaces(in: sourceWs)

    // Blanket-clear focus borders on both sides so neither workspace's
    // stray pane keeps a border visible while the slide is animating,
    // matching the convention used by `switchWorkspace`.
    clearAllFocusBorders(in: sourceWs)
    clearAllFocusBorders(in: workspaces[target])

    // 1. Detach pane from source column.
    clearFocusBorder(pane)
    pane.containerView.removeFromSuperview()
    column.panes.remove(at: sourcePaneIndex)

    var adjustedTarget = target
    var sourceDestroyed = false
    let isSameWs = sourceIndex == target
    let sourceColumnWasRemoved = column.panes.isEmpty

    if column.panes.isEmpty {
      // Source column empty → remove it (propagate to workspace removal)
      column.containerView.removeFromSuperview()
      sourceWs.columns.removeAll { $0 === column }

      if sourceWs.columns.isEmpty {
        if isSameWs {
          // Same-workspace move drained the workspace's only
          // column. The new column we're about to insert keeps the
          // workspace alive — tearing it down here and recreating
          // would lose the array slot, so leave the workspace in
          // place with `columns == []` until the insert reseeds it.
        } else {
          workspaces.remove(at: sourceIndex)
          workspaceVCs.remove(at: sourceIndex)
          sourceDestroyed = true
          if adjustedTarget > sourceIndex { adjustedTarget -= 1 }
        }
      } else {
        sourceWs.focusedColumnIndex = min(sourceWs.focusedColumnIndex, sourceWs.columns.count - 1)
        // Rebuild source VC's stackView to drop the removed column's handle.
        rebuildStackView(in: sourceVC)
      }
    } else {
      column.focusedPaneIndex = min(sourcePaneIndex, column.panes.count - 1)
      rebuildColumnView(column: column)
    }

    // 2. Build a new single-pane column in the target workspace.
    let newColumn = ColumnModel(pane: pane)
    setupPaneCallbacks(pane: pane, column: newColumn)
    let cv = pane.containerView
    newColumn.containerView.addArrangedSubview(cv)
    NSLayoutConstraint.activate([
      cv.leadingAnchor.constraint(equalTo: newColumn.containerView.leadingAnchor),
      cv.trailingAnchor.constraint(equalTo: newColumn.containerView.trailingAnchor),
    ])
    attachFoldedLabel(to: newColumn)
    let wc = newColumn.containerView.widthAnchor.constraint(equalToConstant: defaultPaneWidth)
    wc.isActive = true
    newColumn.widthConstraint = wc

    let targetWs = workspaces[adjustedTarget]
    let targetVC = workspaceVCs[adjustedTarget]
    // Match `addColumn`: pin the new column's height to the target
    // workspace stack so the layout is never ambiguous, and store the
    // constraint on the column model so the gap preset can rewrite it
    // live. Skipping this leaves the height up to AppKit's
    // ambiguity-resolution fallback and produces an arbitrary value
    // on mid-session moves.
    let heightPin = newColumn.containerView.heightAnchor.constraint(
      equalTo: targetVC.stackView.heightAnchor,
      constant: -(WorkspaceViewController.outerMargin * 2)
    )
    heightPin.isActive = true
    newColumn.heightPin = heightPin
    // Same-workspace splits where source column collapsed shrink
    // the target columns array on the same axis the drop position
    // refers to: AppKit gave us a child index computed against the
    // pre-remove array, so a drop landing to the right of the
    // departing column slot has to shift left by one to keep
    // pointing at the same visual gap.
    let adjustedPosition: Int?
    if isSameWs, sourceColumnWasRemoved, let rawPos = position,
      sourceColumnIndex < rawPos
    {
      adjustedPosition = rawPos - 1
    } else {
      adjustedPosition = position
    }
    let insertIndex = min(
      max(adjustedPosition ?? targetWs.columns.count, 0),
      targetWs.columns.count)
    targetWs.columns.insert(newColumn, at: insertIndex)
    targetWs.focusedColumnIndex = insertIndex

    rebuildStackView(in: targetVC)

    let toastLabel =
      isSameWs
      ? "Move Pane"
      : "Move Pane to Workspace \(adjustedTarget + 1)"
    if sourceIndex == focusedWorkspaceIndex, !isSameWs {
      // Cross-workspace move from the currently visible workspace —
      // run the slide animation that palette / IPC `Move Pane`
      // actions use, then shift focus over to the new pane.
      focusedWorkspaceIndex = adjustedTarget
      restoreScroll(in: currentWorkspace)
      showToast(toastLabel)
      // Direction uses pre-adjustment target vs. sourceIndex — stable even
      // when source was destroyed (its removal doesn't change this comparison).
      let slidingUp = target > sourceIndex
      animateSlide(fromVC: sourceVC, toVC: targetVC, slidingUp: slidingUp) {
        [weak self] in
        guard let self else { return }
        if sourceDestroyed {
          sourceVC.view.removeFromSuperview()
          sourceVC.removeFromParent()
        }
        self.setFocus(columnIndex: insertIndex, paneIndex: 0)
      }
    } else if isSameWs {
      // Same-workspace move (in-place column split). No slide:
      // source and target VCs are the same view, and the user's
      // viewport isn't switching workspaces. Re-focus on the new
      // column so the moved pane stays the active surface.
      showToast(toastLabel)
      if sourceIndex == focusedWorkspaceIndex {
        setFocus(columnIndex: insertIndex, paneIndex: 0)
      } else {
        notifySidebarWorklaneDidChange()
      }
    } else {
      // Source was off-screen (sidebar drag from a background
      // workspace). Skip the slide animation entirely — sliding an
      // off-screen source onto the visible workspace and back would
      // blank the pane area, and the user's view isn't changing
      // workspaces anyway. Keep focus on whatever workspace was
      // already current. `restoreScroll` is intentionally skipped
      // here: the visible workspace's live scroll offset is already
      // the authoritative state.
      let focusedWsId = workspaces[safe: focusedWorkspaceIndex]?.id
      if sourceDestroyed {
        sourceVC.view.removeFromSuperview()
        sourceVC.removeFromParent()
      }
      if let focusedWsId,
        let liveIndex = workspaces.firstIndex(where: { $0.id == focusedWsId })
      {
        focusedWorkspaceIndex = liveIndex
      }
      // When target = current, the new column is now sitting in the
      // visible workspace. Refocus on it so the drop lands the user
      // on the moved pane. When target != current, the new column
      // lives in a background workspace; the next switch to it picks
      // up the seeded focused index.
      if adjustedTarget == focusedWorkspaceIndex {
        setFocus(columnIndex: insertIndex, paneIndex: 0)
      } else {
        notifySidebarWorklaneDidChange()
      }
      showToast(toastLabel)
    }
  }

  // MARK: - Move pane into a specific column

  /// Move a pane into the column identified by `targetColumnId`.
  /// Covers three drop shapes the worklane drag-drop path resolves
  /// the same way: in-column reorder (source column == target
  /// column), cross-column move within the same workspace, and
  /// cross-workspace column merge. `position` is the pane index
  /// inside the target column where the moved pane should land
  /// (`nil` = append at the trailing edge).
  ///
  /// Private boundary applies the same way as the workspace-level
  /// variant — moves whose source and target workspaces disagree on
  /// `isPrivate` are rejected with the shared toast, since the
  /// pane's `WKWebsiteDataStore` is bound at construction time and
  /// can't switch profiles mid-flight.
  public func movePane(
    _ paneId: ULID, toColumnId targetColumnId: ULID, position: Int? = nil
  ) {
    logger.info("movePane(paneId:toColumnId) entry")
    guard let loc = locatePane(id: paneId) else {
      logger.debug("movePane(toColumnId:) guard failed: pane not found")
      return
    }
    var targetWsIdx: Int?
    var targetColIdx: Int?
    for (wsIdx, ws) in workspaces.enumerated() {
      if let colIdx = ws.columns.firstIndex(where: { $0.id == targetColumnId }) {
        targetWsIdx = wsIdx
        targetColIdx = colIdx
        break
      }
    }
    guard let targetWsIdx, let targetColIdx else {
      logger.debug("movePane(toColumnId:) guard failed: target column not found")
      return
    }

    let sourceWs = workspaces[loc.workspaceIndex]
    let sourceColumn = sourceWs.columns[loc.columnIndex]
    let pane = sourceColumn.panes[loc.paneIndex]
    let targetWs = workspaces[targetWsIdx]
    let targetColumn = targetWs.columns[targetColIdx]

    if sourceColumn === targetColumn {
      reorderPaneWithinColumn(
        pane: pane, column: sourceColumn,
        sourceWsIndex: loc.workspaceIndex,
        sourceColumnIndex: loc.columnIndex,
        sourcePaneIndex: loc.paneIndex,
        position: position)
      return
    }

    mergePaneIntoColumn(
      pane: pane,
      sourceWs: sourceWs, sourceWsIndex: loc.workspaceIndex,
      sourceColumn: sourceColumn, sourceColumnIndex: loc.columnIndex,
      sourcePaneIndex: loc.paneIndex,
      targetWs: targetWs, targetWsIndex: targetWsIdx,
      targetColumn: targetColumn, targetColumnIndex: targetColIdx,
      position: position)
  }

  /// In-column reorder branch of `movePane(_:toColumnId:position:)`.
  /// `position` is the post-insert pane index the caller wants the
  /// moved pane to land at; the actual array op happens
  /// remove-then-insert, so we shift the index by one when the
  /// source sits before the target slot.
  private func reorderPaneWithinColumn(
    pane: PaneModel, column: ColumnModel,
    sourceWsIndex: Int, sourceColumnIndex: Int,
    sourcePaneIndex: Int, position: Int?
  ) {
    let oldIdx = sourcePaneIndex
    let rawPosition = position ?? column.panes.count
    let adjusted = oldIdx < rawPosition ? rawPosition - 1 : rawPosition
    let clamped = min(max(adjusted, 0), column.panes.count - 1)
    if clamped == oldIdx {
      // Drag callers route through `isNoOpAction` first, so a same-
      // slot drop here implies a palette / IPC caller passed a
      // position that resolves to the source's own index — likely a
      // bug worth catching in Console.
      logger.warning(
        "[workspaces/move] reorderPaneWithinColumn no-op same-position drop")
      return
    }
    // Dismiss find / URL bar suggestion popovers before the column
    // rebuild. The pane stays attached but pane frames slide, and a
    // popover anchored to the old slot would otherwise hover at a
    // stale screen position.
    if sourceWsIndex == focusedWorkspaceIndex {
      dismissAllFindSessions(in: workspaces[sourceWsIndex])
      focusedPane?.urlBar.dismissSuggestionDropdown()
    }
    column.panes.remove(at: oldIdx)
    column.panes.insert(pane, at: clamped)
    column.focusedPaneIndex = clamped
    rebuildColumnView(column: column)
    if sourceWsIndex == focusedWorkspaceIndex {
      setFocus(columnIndex: sourceColumnIndex, paneIndex: clamped, scroll: false)
    }
    showToast("Move Pane")
    notifySidebarWorklaneDidChange()
  }

  /// Cross-column branch of `movePane(_:toColumnId:position:)`.
  /// Handles same-workspace column merge and cross-workspace
  /// column merge identically; the only diverging behaviour is the
  /// toast wording and whether the source workspace tears down
  /// when it's left empty.
  private func mergePaneIntoColumn(
    pane: PaneModel,
    sourceWs: WorkspaceModel, sourceWsIndex: Int,
    sourceColumn: ColumnModel, sourceColumnIndex: Int,
    sourcePaneIndex: Int,
    targetWs: WorkspaceModel, targetWsIndex: Int,
    targetColumn _: ColumnModel, targetColumnIndex: Int,
    position: Int?
  ) {
    // Cross-private boundary guard — matches the diagnostic shape
    // `performCrossWorkspaceMove` emits so source / target flags
    // are readable side-by-side in Console.app.
    if sourceWs.isPrivate != targetWs.isPrivate {
      logger.error(
        "movePane(toColumnId:) blocked: cross-private-boundary move (source=\(sourceWs.isPrivate ? "private" : "public", privacy: .public), target=\(targetWs.isPrivate ? "private" : "public", privacy: .public))")
      showCrossPrivateBoundaryToast()
      return
    }

    let sourceVC = workspaceVCs[sourceWsIndex]
    // Snapshot the "source was visible at drop time" flag before
    // any array mutation shifts indices around. Later branches use
    // this to decide whether the user needs a slide animation: a
    // background-source drop keeps the viewport still, while a
    // current-source drop has to travel to the target workspace.
    let sourceWasCurrent = sourceWsIndex == focusedWorkspaceIndex
    if sourceWasCurrent {
      dismissAllFindSessions(in: sourceWs)
      focusedPane?.urlBar.dismissSuggestionDropdown()
      sourceWs.scrollX =
        sourceVC.scrollView.contentView.bounds.origin.x
        - hoverPeekScrollCompensation
    }
    preserveSurfaces(in: sourceWs)
    if targetWs.id != sourceWs.id {
      preserveSurfaces(in: targetWs)
    }
    clearAllFocusBorders(in: sourceWs)
    if targetWs.id != sourceWs.id {
      clearAllFocusBorders(in: targetWs)
    }

    // Snapshot the focused workspace's identity so any source-side
    // cleanup that shifts array indices doesn't leave the focus
    // pointing at the wrong workspace.
    let focusedWsId = workspaces[safe: focusedWorkspaceIndex]?.id

    // 1. Detach pane from source column.
    clearFocusBorder(pane)
    pane.containerView.removeFromSuperview()
    sourceColumn.panes.remove(at: sourcePaneIndex)

    var adjustedTargetWsIdx = targetWsIndex
    var adjustedTargetColIdx = targetColumnIndex
    var sourceWsDestroyed = false

    if sourceColumn.panes.isEmpty {
      sourceColumn.containerView.removeFromSuperview()
      sourceWs.columns.removeAll { $0 === sourceColumn }
      // If target column lived in the same workspace and at a
      // higher index than the just-removed source column, the
      // target's array slot shifted left by one.
      if targetWs.id == sourceWs.id, sourceColumnIndex < adjustedTargetColIdx {
        adjustedTargetColIdx -= 1
      }
      if sourceWs.columns.isEmpty {
        workspaces.remove(at: sourceWsIndex)
        workspaceVCs.remove(at: sourceWsIndex)
        sourceWsDestroyed = true
        if adjustedTargetWsIdx > sourceWsIndex {
          adjustedTargetWsIdx -= 1
        }
      } else {
        sourceWs.focusedColumnIndex = min(
          sourceWs.focusedColumnIndex, sourceWs.columns.count - 1)
        rebuildStackView(in: sourceVC)
      }
    } else {
      sourceColumn.focusedPaneIndex = min(
        sourcePaneIndex, sourceColumn.panes.count - 1)
      rebuildColumnView(column: sourceColumn)
    }

    // 2. Insert pane into target column. The moved pane's
    // `containerView` keeps its leading/trailing constraints intact
    // through `removeFromSuperview` because they reference the
    // column's superview anchors — `rebuildColumnView` rebinds them
    // to the new column's stackView when it re-inserts the pane.
    let liveTargetWs = workspaces[adjustedTargetWsIdx]
    let liveTargetColumn = liveTargetWs.columns[adjustedTargetColIdx]
    let insertIndex = min(
      max(position ?? liveTargetColumn.panes.count, 0),
      liveTargetColumn.panes.count)
    liveTargetColumn.panes.insert(pane, at: insertIndex)
    liveTargetColumn.focusedPaneIndex = insertIndex
    rebuildColumnView(column: liveTargetColumn)

    // 3. Re-resolve the focused workspace's index after any array
    // mutations and shift focus to the moved pane when the target
    // workspace is current.
    if let focusedWsId,
      let liveIdx = workspaces.firstIndex(where: { $0.id == focusedWsId })
    {
      focusedWorkspaceIndex = liveIdx
    } else {
      // The previously focused workspace was destroyed (only path:
      // source was current and source ws collapsed to empty).
      focusedWorkspaceIndex = adjustedTargetWsIdx
    }

    let isCrossWs = targetWs.id != sourceWs.id
    let toastLabel =
      isCrossWs
      ? "Move Pane to Workspace \(adjustedTargetWsIdx + 1)"
      : "Move Pane"

    let targetVC = workspaceVCs[adjustedTargetWsIdx]
    if isCrossWs, sourceWasCurrent {
      // Cross-workspace merge that originated from the visible
      // workspace. Without a slide here the source VC's view
      // would already be off-screen (or detached) while the
      // target VC is still `isHidden = true`. The new-column
      // path runs `animateSlide` for the same reason. Reuse that
      // animation so the user's viewport visibly travels to the
      // destination workspace, and defer the VC tear-down to the
      // completion handler so the from-side stays paintable.
      restoreScroll(in: currentWorkspace)
      showToast(toastLabel)
      let slidingUp = targetWsIndex > sourceWsIndex
      animateSlide(fromVC: sourceVC, toVC: targetVC, slidingUp: slidingUp) {
        [weak self] in
        guard let self else { return }
        if sourceWsDestroyed {
          sourceVC.view.removeFromSuperview()
          sourceVC.removeFromParent()
        }
        self.setFocus(columnIndex: adjustedTargetColIdx, paneIndex: insertIndex)
      }
      return
    }

    if sourceWsDestroyed {
      sourceVC.view.removeFromSuperview()
      sourceVC.removeFromParent()
    }
    showToast(toastLabel)
    if adjustedTargetWsIdx == focusedWorkspaceIndex {
      setFocus(columnIndex: adjustedTargetColIdx, paneIndex: insertIndex)
    } else {
      notifySidebarWorklaneDidChange()
    }
  }

  /// Shared rejection toast for cross-private-boundary pane moves.
  /// Both the drag-drop path (worklane sidebar fires this through
  /// `onCrossPrivateBoundaryAttempt`) and the palette / IPC path
  /// (`performCrossWorkspaceMove`) route through here so the
  /// wording stays in one place.
  public func showCrossPrivateBoundaryToast() {
    showToast("Can't move pane across the private boundary", style: .error)
  }

  // MARK: - Helpers

  /// Release stashed undo-close surfaces belonging to the given workspace.
  /// Called when that workspace is being torn down — their (colIdx, paneIdx)
  /// references would be meaningless once the workspace is gone. Stash
  /// entries owned by other workspaces are left alone so undo still works
  /// there after a switch.
  func flushRecentlyClosed(in workspace: WorkspaceModel) {
    recentlyClosed.removeAll { closed in
      guard closed.workspaceId == workspace.id else { return false }
      closed.timer.invalidate()
      closed.pane.terminalView?.releaseDetachedSurface()
      return true
    }
  }

  /// Restore focus to the current workspace's remembered pane position,
  /// clamping indices in case columns/panes were removed. Callers are
  /// expected to follow up with `restoreScroll(in:)` — scrolling is
  /// suppressed here so the workspace's saved offset isn't clobbered.
  func restoreFocusInCurrentWorkspace() {
    let ws = currentWorkspace
    logger.debug("restoreFocusInCurrentWorkspace: wsId=\(String(describing: ws.id), privacy: .public) columns=\(ws.columns.count) wsFocusedCol=\(ws.focusedColumnIndex) wsIdx=\(self.focusedWorkspaceIndex)")
    guard !ws.columns.isEmpty else { return }
    let colIdx = min(max(ws.focusedColumnIndex, 0), ws.columns.count - 1)
    let column = ws.columns[colIdx]
    let paneIdx = min(max(column.focusedPaneIndex, 0), column.panes.count - 1)
    logger.debug("restoreFocus → setFocus(col=\(colIdx), pane=\(paneIdx))")
    setFocus(columnIndex: colIdx, paneIndex: paneIdx, scroll: false)
  }

  /// Drop the focus border from every pane in `workspace`. Called before
  /// a workspace switch so that (a) the outgoing pane's border doesn't
  /// persist when we come back, and (b) the incoming workspace can start
  /// from a clean slate before `setFocus` re-applies on the current pane.
  /// Using the blanket sweep instead of relying on `setFocus`'s previous-
  /// pane logic makes the code resilient to any past state where a border
  /// ended up on a pane that no longer matches the computed `focusedPane`.
  func clearAllFocusBorders(in workspace: WorkspaceModel) {
    for column in workspace.columns {
      for pane in column.panes {
        clearFocusBorder(pane)
      }
    }
  }

  /// Mark all terminal surfaces in the workspace as "keep alive" so that
  /// detaching their container views from the stack view doesn't free the
  /// underlying ghostty surface. The flag is left sticky across workspace
  /// switches — it's overwritten only by the next `preserveSurfaces`
  /// call, `removePane` (flips false on explicit close), or
  /// `closeCurrentWorkspace` (flips false before final detach). That lets
  /// surfaces survive repeated switch cycles without leaking.
  func preserveSurfaces(in workspace: WorkspaceModel) {
    for column in workspace.columns {
      for pane in column.panes {
        pane.terminalView?.keepSurfaceAlive = true
      }
    }
  }

  /// Restore the workspace's saved horizontal scroll position. Called
  /// after `restoreFocusInCurrentWorkspace` to override the default
  /// "scroll-to-focused-column" behavior — we want switching back to
  /// land the user exactly where they left off. `scrollX` is stored
  /// in logical coordinates; the live `bounds.origin.x` always
  /// includes the active hover-peek compensation on top.
  func restoreScroll(in workspace: WorkspaceModel) {
    let liveX = workspace.scrollX + hoverPeekScrollCompensation
    scrollView.contentView.setBoundsOrigin(NSPoint(x: liveX, y: 0))
  }
}
