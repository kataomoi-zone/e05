import AppKit

extension PaneContainerViewController {
  // MARK: - Accent color palette

  /// Fixed palette mapped positionally: `palette[i % palette.count]` is the
  /// color for the workspace displayed as "Workspace \(i + 1)". Because it
  /// tracks array position — not an id baked into the workspace itself —
  /// number and color stay aligned when workspaces are added or removed.
  /// Workspaces beyond the palette length cycle back to the first color;
  /// a later config plumbing pass can expose this list to the user.
  public static let accentColorPalette: [NSColor] = [
    NSColor(srgbRed: 0xce / 255, green: 0x05 / 255, blue: 0x5b / 255, alpha: 1),
    NSColor(srgbRed: 0xb0 / 255, green: 0xbf / 255, blue: 0x1f / 255, alpha: 1),
    NSColor(srgbRed: 0xec / 255, green: 0x6e / 255, blue: 0x65 / 255, alpha: 1),
    NSColor(srgbRed: 0x02 / 255, green: 0x79 / 255, blue: 0xc2 / 255, alpha: 1),
  ]

  /// Accent color for the workspace at `position`. Wraps via modulo so any
  /// non-negative index resolves to a palette entry, keeping this function
  /// total even when the workspace count exceeds the palette length.
  /// Falls back to `.systemBlue` if the palette itself is empty (a
  /// theoretically impossible state, guarded for safety).
  public static func accentColor(forWorkspaceAt position: Int) -> NSColor {
    guard !accentColorPalette.isEmpty else { return .systemBlue }
    let safePosition = max(position, 0)
    return accentColorPalette[safePosition % accentColorPalette.count]
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
    NSLog(
      "[e05/ws] switchWorkspace(to:%d) entry: focused=%d, wsCount=%d, targetCol=%d targetPane=%d",
      index, focusedWorkspaceIndex, workspaces.count,
      workspaces[safe: index]?.focusedColumnIndex ?? -1,
      workspaces[safe: index]?.columns[safe: workspaces[safe: index]?.focusedColumnIndex ?? 0]?.focusedPaneIndex ?? -1)
    guard index != focusedWorkspaceIndex,
      workspaces.indices.contains(index)
    else {
      NSLog("[e05/ws] switchWorkspace guard failed")
      return
    }

    // Dismiss the find bar before the slide animation begins. The
    // completion-handler path eventually runs `setFocus`, which would
    // close the bar anyway, but that fires after the 250ms slide —
    // leaving the overlay visibly stranded on the outgoing workspace
    // for the duration. Closing up front lets the slide start clean.
    closeFindBar()

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
      NSLog(
        "[e05/ws] animateSlide missing constraints — from=%@ to=%@",
        fromVC.topConstraint == nil ? "nil" : "ok",
        toVC.topConstraint == nil ? "nil" : "ok")
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

    NSLog(
      "[e05/ws] animateSlide start: slidingUp=%@ fromConst=%f toStart=%f h=%f",
      slidingUp ? "yes" : "no", fromTop.constant, toTop.constant, h)

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
          NSLog("[e05/ws] animateSlide end: subviews=%d", self.view.subviews.count)
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
    NSLog(
      "[e05/ws] createWorkspace entry: focused=%d, wsCount=%d, private=%@",
      focusedWorkspaceIndex, workspaces.count, isPrivate ? "yes" : "no")

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
    NSLog(
      "[e05/ws] closeCurrentWorkspace entry: focused=%d, wsCount=%d",
      focusedWorkspaceIndex, workspaces.count)
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

    workspaces.remove(at: closingIndex)
    workspaceVCs.remove(at: closingIndex)

    if workspaces.isEmpty {
      closingVC.view.removeFromSuperview()
      closingVC.removeFromParent()
      view.window?.close()
      return
    }

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
    NSLog(
      "[e05/ws] closeWorkspace(at:%d) non-current: focused=%d wsCount=%d",
      index, focusedWorkspaceIndex, workspaces.count)

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
    notifySidebarWorklaneDidChange()
  }

  // MARK: - Move pane across workspaces

  /// Move the focused pane into the target workspace as a new single-pane
  /// column at its right edge, then slide to the target. The pane's
  /// surface is preserved across the move. If the source column/workspace
  /// is left empty, it collapses per the standard invariants.
  public func movePane(toWorkspaceId id: ULID) {
    NSLog("[e05/ws] movePane(toWorkspaceId) entry: focused=%d", focusedWorkspaceIndex)
    guard let target = workspaces.firstIndex(where: { $0.id == id }),
      target != focusedWorkspaceIndex,
      let column = columns[safe: focusedColumnIndex],
      let pane = column.focusedPane
    else {
      NSLog("[e05/ws] movePane guard failed")
      return
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
    let sourceIsPrivate = workspaces[focusedWorkspaceIndex].isPrivate
    if sourceIsPrivate != workspaces[target].isPrivate {
      NSLog(
        "[e05/ws] movePane blocked: cross-private-boundary move (source=%@, target=%@)",
        sourceIsPrivate ? "private" : "public",
        workspaces[target].isPrivate ? "private" : "public")
      showToast("Can't move pane across the private boundary", style: .error)
      return
    }
    let paneIndex = column.focusedPaneIndex
    let sourceIndex = focusedWorkspaceIndex
    let sourceWs = workspaces[sourceIndex]
    let sourceVC = workspaceVCs[sourceIndex]

    // Preserve surfaces on the outgoing side — both the pane being moved
    // and any other panes left behind in source-workspace columns.
    sourceWs.scrollX = sourceVC.scrollView.contentView.bounds.origin.x - hoverPeekScrollCompensation
    preserveSurfaces(in: sourceWs)

    // Blanket-clear focus borders on both sides so neither workspace's
    // stray pane keeps a border visible while the slide is animating,
    // matching the convention used by `switchWorkspace`.
    clearAllFocusBorders(in: sourceWs)
    clearAllFocusBorders(in: workspaces[target])

    // 1. Detach pane from source column.
    clearFocusBorder(pane)
    pane.containerView.removeFromSuperview()
    column.panes.remove(at: paneIndex)

    var adjustedTarget = target
    var sourceDestroyed = false

    if column.panes.isEmpty {
      // Source column empty → remove it (propagate to workspace removal)
      column.containerView.removeFromSuperview()
      sourceWs.columns.removeAll { $0 === column }

      if sourceWs.columns.isEmpty {
        workspaces.remove(at: sourceIndex)
        workspaceVCs.remove(at: sourceIndex)
        sourceDestroyed = true
        if adjustedTarget > sourceIndex { adjustedTarget -= 1 }
      } else {
        sourceWs.focusedColumnIndex = min(sourceWs.focusedColumnIndex, sourceWs.columns.count - 1)
        // Rebuild source VC's stackView to drop the removed column's handle.
        rebuildStackView(in: sourceVC)
      }
    } else {
      column.focusedPaneIndex = min(paneIndex, column.panes.count - 1)
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
    targetWs.columns.append(newColumn)
    let newIdx = targetWs.columns.count - 1
    targetWs.focusedColumnIndex = newIdx

    rebuildStackView(in: targetVC)

    focusedWorkspaceIndex = adjustedTarget
    restoreScroll(in: currentWorkspace)
    showToast("Move Pane to Workspace \(adjustedTarget + 1)")

    // Direction uses pre-adjustment target vs. sourceIndex — stable even
    // when source was destroyed (its removal doesn't change this comparison).
    let slidingUp = target > sourceIndex
    animateSlide(fromVC: sourceVC, toVC: targetVC, slidingUp: slidingUp) { [weak self] in
      guard let self else { return }
      if sourceDestroyed {
        sourceVC.view.removeFromSuperview()
        sourceVC.removeFromParent()
      }
      self.setFocus(columnIndex: newIdx, paneIndex: 0)
    }
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
    NSLog(
      "[e05/ws] restoreFocusInCurrentWorkspace: wsId=%@ columns=%d wsFocusedCol=%d wsIdx=%d",
      String(describing: ws.id), ws.columns.count, ws.focusedColumnIndex, focusedWorkspaceIndex)
    guard !ws.columns.isEmpty else { return }
    let colIdx = min(max(ws.focusedColumnIndex, 0), ws.columns.count - 1)
    let column = ws.columns[colIdx]
    let paneIdx = min(max(column.focusedPaneIndex, 0), column.panes.count - 1)
    NSLog("[e05/ws] restoreFocus → setFocus(col=%d, pane=%d)", colIdx, paneIdx)
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
