import AppKit

extension PaneContainerViewController {
  /// Fixed sidebar width in points. The container's workspace views
  /// use this for their leading inset when the sidebar is pinned
  /// open; the sidebar itself uses it for its own width. Kept as a
  /// class-level constant so the state machine animates the same
  /// anchor everywhere.
  public static let sidebarWidth: CGFloat = 260

  /// Duration of the sidebar reveal/hide animation, in seconds.
  /// Ease-out timing so the motion decelerates into place — the
  /// sidebar "settles" at its final position rather than snapping.
  public static let sidebarAnimationDuration: TimeInterval = 0.2

  /// True while the sidebar is transitioning between states. Workspace
  /// switching reads this to skip its own animation; otherwise the
  /// two animations run concurrently and stomp on each other's
  /// intermediate constraint values.
  public var isAnimatingSidebar: Bool {
    sidebarVC?.isAnimating ?? false
  }

  /// Instantiate the sidebar child VC, the edge hit zone, and the
  /// initial state derived from `initiallyPinned`. Called from
  /// `viewDidLoad` after all workspace VCs are installed, so the
  /// sidebar sits on top of them in `subviews` z-order while the hit
  /// zone sits beneath for click pass-through.
  func installSidebar(initiallyPinned: Bool, initiallyCollapsedIds: [String] = []) {
    // Hit zone goes in first so the sidebar ends up above it in
    // z-order. When the sidebar is revealed it fully occludes the
    // 8pt hit zone; when hidden, the hit zone is the only thing at
    // the leading edge and its NSTrackingArea fires hover events.
    let hitZone = EdgeHoverHitZoneView()
    hitZone.onEnter = { [weak self] in self?.sidebarVC?.setEdgeHovered(true) }
    hitZone.onExit = { [weak self] in self?.sidebarVC?.setEdgeHovered(false) }
    view.addSubview(hitZone)
    NSLayoutConstraint.activate([
      hitZone.topAnchor.constraint(equalTo: view.topAnchor),
      hitZone.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hitZone.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      hitZone.widthAnchor.constraint(equalToConstant: EdgeHoverHitZoneView.width),
    ])
    edgeHitZone = hitZone

    // Peek shield sits between the workspace VCs (already in the
    // subviews list) and the sidebar (added next), so it absorbs any
    // cursor / hit-test fall-through that NSGlassEffectView's
    // transparent regions would otherwise let descend into the
    // panes underneath. Hidden by default; the state-machine
    // application below toggles it for `.hoverPeek`.
    let shield = SidebarPeekShieldView()
    shield.translatesAutoresizingMaskIntoConstraints = false
    shield.isHidden = true
    view.addSubview(shield)
    NSLayoutConstraint.activate([
      shield.topAnchor.constraint(equalTo: view.topAnchor),
      shield.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      shield.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      shield.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
    ])
    peekShield = shield

    let vc = SidebarViewController()
    vc.container = self
    addChild(vc)
    let sv = vc.view
    sv.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(sv)
    // Start the sidebar parked off-screen (`-sidebarWidth`) when
    // hidden, or flush at x=0 when pinned. `applyInitialState`
    // below will rewrite this to match `initiallyPinned`; we just
    // need a valid constraint to mutate later.
    let leading = sv.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0)
    NSLayoutConstraint.activate([
      sv.topAnchor.constraint(equalTo: view.topAnchor),
      leading,
      sv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      sv.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
    ])
    sidebarLeadingConstraint = leading
    sidebarVC = vc
    // Filter persisted ULID strings against the live workspace /
    // column ids before seeding. Entries that no longer correspond
    // to a live item (older session.json referencing a workspace or
    // column that's gone) are silently dropped so the seed set
    // matches the AppKit data source's reachable items exactly.
    var liveIds = Set<ULID>()
    for ws in workspaces {
      liveIds.insert(ws.id)
      for column in ws.columns {
        liveIds.insert(column.id)
      }
    }
    let seeded = Set(
      initiallyCollapsedIds.compactMap { raw -> ULID? in
        let id = ULID(raw)
        return liveIds.contains(id) ? id : nil
      })
    vc.seedCollapsed(seeded)
    // `attachContainer()` wires the DownloadsManager listener for
    // the places-section badge. Called after `sidebarVC` is set so
    // the sidebar reads through the same weak back-reference as
    // subsequent reloads.
    sidebarVC.attachContainer()
    sidebarVC.reloadWorklane()
    // Seed the initial state *before* the first layout pass so the
    // sidebar doesn't flicker from `.hidden` to `.pinnedOpen` (or
    // vice versa) when the window first appears.
    sidebarVC.applyInitialState(pinned: initiallyPinned)
  }

  /// Tell the sidebar worklane to rebuild from the current state. Called
  /// from `setFocus` (which every pane/column/workspace mutation path
  /// eventually funnels into). Skipped while a workspace switch animation
  /// is in flight to avoid mid-slide flicker — the animation's completion
  /// calls `restoreFocusInCurrentWorkspace` → `setFocus`, which re-fires
  /// this notify once the animation settles.
  ///
  /// Nil-guarded on `sidebarVC` because the first `setFocus` (from the
  /// initial `addColumn` in `viewDidLoad`) runs before `installSidebar()`.
  func notifySidebarWorklaneDidChange() {
    guard let sidebarVC, !isAnimatingWorkspaceSwitch else { return }
    sidebarVC.reloadWorklane()
  }

  // MARK: - State machine layout application

  /// Drive the sidebar/workspace layout to match `state`. `animated`
  /// wraps the constraint changes in an `NSAnimationContext` group;
  /// the cold-start `applyInitialState` passes `false` so the sidebar
  /// appears in its final position without a visible slide.
  ///
  /// `completion` fires on the main actor once the animation settles
  /// (or immediately when `animated == false`). The sidebar view
  /// controller uses it to clear its `isAnimating` flag.
  func applySidebarLayout(
    state: SidebarState,
    animated: Bool,
    completion: (@MainActor @Sendable () -> Void)?
  ) {
    // The find bar floats centered at the pane bottom and the
    // sidebar slides in from the leading edge — they no longer
    // overlap visually, so revealing the sidebar leaves any open
    // find session intact. Auto-close on focus changes / workspace
    // switches still applies through `setFocus` and `switchWorkspace`.

    let sidebarConst: CGFloat = state.isRevealed ? 0 : -Self.sidebarWidth
    // Both revealed states inflate each workspace's
    // `scrollView.contentInsets.left` so the leftmost column starts
    // past the sidebar — the root spans the full window width in
    // every state, and any column scrolled under the sidebar gives
    // the glass a multi-coloured blur source so the panel reads as
    // Liquid Glass instead of an opaque slab. AppKit also treats the
    // leading inset region as off-document for cursor / tracking
    // dispatch, which is what keeps clicks, link `:hover`, finder
    // resize cursors, etc. from leaking through the glass while the
    // sidebar covers them.
    let pinnedInset: CGFloat = state.reservesLeadingScrollInset ? Self.sidebarWidth : 0

    // Hover-peek visually overlays without shifting the columns —
    // pinned shifts, hover-peek doesn't. The inset above is applied
    // for both, so for hover-peek we have to advance each clip
    // view's `bounds.origin.x` by the inset width to cancel the
    // visual shift the inset would otherwise introduce. Track the
    // currently-applied compensation on the container and dispatch
    // the *delta* on every state change so the user's scroll
    // position relative to the sidebar state stays coherent across
    // hidden ↔ peek ↔ pinned transitions.
    let newCompensation: CGFloat = (state == .hoverPeek) ? Self.sidebarWidth : 0
    let scrollDelta = newCompensation - hoverPeekScrollCompensation
    let insetDelta = pinnedInset - currentLeadingInset
    hoverPeekScrollCompensation = newCompensation
    currentLeadingInset = pinnedInset

    // The peek shield only matters in `.hoverPeek`: hidden state has
    // no sidebar to leak under, and pinned shifts the workspace via
    // the inset above so the panes already sit clear of x<sidebarWidth.
    peekShield?.isHidden = (state != .hoverPeek)

    applyTrafficLights(revealed: state.isRevealed, animated: animated)

    guard animated else {
      sidebarLeadingConstraint?.constant = sidebarConst
      for vc in workspaceVCs {
        vc.scrollView.contentInsets.left = pinnedInset
        if scrollDelta != 0 {
          var origin = vc.scrollView.contentView.bounds.origin
          origin.x += scrollDelta
          vc.scrollView.contentView.setBoundsOrigin(origin)
        }
      }
      view.layoutSubtreeIfNeeded()
      completion?()
      return
    }

    // Whether the visible content position changes between the
    // outgoing and incoming states. `.hoverPeek` is reached by
    // advancing both the inset (push content right) and the scroll
    // origin (compensate by an equal amount), so the *visible*
    // column strip stays put — the inset and origin shifts cancel.
    // `.hidden` ↔ `.pinnedOpen` transitions only move the inset, so
    // the columns slide. `.hoverPeek` ↔ `.pinnedOpen` only moves
    // the origin (inset stays at `sidebarWidth` in both), so the
    // columns also slide. `insetDelta` and `scrollDelta` are derived
    // from the *target* values tracked on the container, so the
    // exact `== 0` compare is safe (both are integer-valued).
    let snapContent = (insetDelta - scrollDelta == 0)

    // Drop the animation onto the next run-loop tick so that any
    // mouseEntered/Exited event that triggered this transition has
    // a chance to flush through AppKit's dispatch cycle first. An
    // `NSAnimationContext` started inside an event handler has a
    // known risk of collapsing to zero duration (same root cause as
    // `PaneContainerViewController+Focus.scrollToColumn`).
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        completion?()
        return
      }
      if snapContent {
        // `.hoverPeek` transitions only — the inset/origin shifts
        // cancel visually, so we snap them synchronously and let the
        // sidebar leading constraint animate alone. This avoids the
        // start-delay that NSClipView's `animator().bounds.origin`
        // exhibits: the clip view routes through NSScrollView's
        // internal scroll machinery, which has its own deceleration
        // timing that NSAnimationContext.duration does not fully
        // override. The lag (~0.1–0.2s on a 0.2s sidebar slide) was
        // visible to the user as the column strip drifting briefly
        // out from under the sidebar at the head of the tween.
        for vc in self.workspaceVCs {
          vc.scrollView.contentInsets.left = pinnedInset
          if scrollDelta != 0 {
            var origin = vc.scrollView.contentView.bounds.origin
            origin.x += scrollDelta
            vc.scrollView.contentView.setBoundsOrigin(origin)
          }
        }
      }
      NSAnimationContext.runAnimationGroup(
        { ctx in
          ctx.duration = Self.sidebarAnimationDuration
          ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
          ctx.allowsImplicitAnimation = true
          self.sidebarLeadingConstraint?.animator().constant = sidebarConst
          if !snapContent {
            for vc in self.workspaceVCs {
              // NSScrollView is `NSAnimatablePropertyContainer`;
              // assigning a fresh `NSEdgeInsets` through the animator
              // interpolates the inset, so the column strip slides
              // into its new start position in lockstep with the
              // sidebar slide. Used for `.hidden` ↔ `.pinnedOpen`.
              if insetDelta != 0 {
                var insets = vc.scrollView.contentInsets
                insets.left = pinnedInset
                vc.scrollView.animator().contentInsets = insets
              }
              if scrollDelta != 0 {
                let newX = vc.scrollView.contentView.bounds.origin.x + scrollDelta
                vc.scrollView.contentView.animator().bounds.origin.x = newX
              }
            }
          }
          self.view.layoutSubtreeIfNeeded()
        },
        completionHandler: {
          MainActor.assumeIsolated {
            completion?()
          }
        })
    }
  }

  /// Toggle the traffic lights in sync with the sidebar reveal.
  ///
  /// The OS buttons live in the window titlebar layer, above the
  /// contentView. We deliberately avoid `isHidden` here: flipping
  /// `isHidden` on `standardWindowButton` was observed to desync the
  /// key-window visual (buttons re-appeared in greyed "inactive"
  /// state on the first reveal and only regained colour after the
  /// next layout pass). `alphaValue` stays in the same render path
  /// across transitions, so the key/inactive look tracks the window
  /// state throughout the fade. `isEnabled` disables the hit region
  /// while the sidebar is hidden so the invisible buttons cannot be
  /// clicked through.
  private func applyTrafficLights(revealed: Bool, animated: Bool) {
    let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    guard let window = view.window else {
      // First call before the window is attached: defer to
      // `viewDidAppear` / the next `applySidebarLayout` call. The
      // AppDelegate initialises the window before
      // `installSidebar` runs, so this guard primarily exists for
      // unit testing without a full NSWindow.
      return
    }
    let targetAlpha: CGFloat = revealed ? 1.0 : 0.0
    // Enable/disable is synchronous, and asymmetric on purpose:
    // on reveal, enable before the fade (click works instantly,
    // even at alpha < 1); on hide, disable only after the fade
    // settles (keeps clicks working until the buttons are visibly
    // gone, and blocks ghost clicks on the invisible buttons
    // afterwards).
    if revealed {
      for type in buttons {
        window.standardWindowButton(type)?.isEnabled = true
      }
    }
    if !animated {
      for type in buttons {
        let button = window.standardWindowButton(type)
        button?.alphaValue = targetAlpha
        button?.isEnabled = revealed
      }
      return
    }
    NSAnimationContext.runAnimationGroup(
      { ctx in
        ctx.duration = Self.sidebarAnimationDuration
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        for type in buttons {
          window.standardWindowButton(type)?.animator().alphaValue = targetAlpha
        }
      },
      completionHandler: {
        MainActor.assumeIsolated {
          if !revealed {
            for type in buttons {
              window.standardWindowButton(type)?.isEnabled = false
            }
          }
        }
      })
  }
}
