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
    func installSidebar(initiallyPinned: Bool) {
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
        let sidebarConst: CGFloat = state.isRevealed ? 0 : -Self.sidebarWidth
        let workspaceConst: CGFloat = state.pushesContent ? Self.sidebarWidth : 0

        applyTrafficLights(revealed: state.isRevealed, animated: animated)

        guard animated else {
            sidebarLeadingConstraint?.constant = sidebarConst
            for vc in workspaceVCs {
                vc.leadingConstraint?.constant = workspaceConst
            }
            view.layoutSubtreeIfNeeded()
            completion?()
            return
        }

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
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Self.sidebarAnimationDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                self.sidebarLeadingConstraint?.animator().constant = sidebarConst
                for vc in self.workspaceVCs {
                    vc.leadingConstraint?.animator().constant = workspaceConst
                }
                self.view.layoutSubtreeIfNeeded()
            }, completionHandler: {
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
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.sidebarAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for type in buttons {
                window.standardWindowButton(type)?.animator().alphaValue = targetAlpha
            }
        }, completionHandler: {
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
