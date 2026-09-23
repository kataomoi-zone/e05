import AppKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "PaneMap")

/// What an open pane map changed, so closing it can put exactly that back,
/// plus where the selection currently sits.
@MainActor
final class PaneMapSession {
  let shield: PaneMapShieldView
  let background: CGColor?
  var guide: PaneMapGuideView?
  /// One translucent cover per pane the selection is not on, keyed by the
  /// pane it covers.
  var scrims: [ObjectIdentifier: NSView] = [:]
  /// Whether the sidebar's edge hover zone was already hidden before the
  /// map turned it off (a peek would rewrite every row's inset).
  var edgeHitZoneWasHidden = false
  /// The pane currently wearing the selection border, and the view that
  /// actually wears it (a folded column's strip stands in for its panes),
  /// so both can be given their own back when the selection moves on or
  /// the map closes.
  var highlighted: PaneModel?
  var highlightedView: NSView?
  /// Name plates, one per row, and a marker on each pinned column.
  /// Parented to the row rather than to the zoomed-out workspace inside
  /// it, so they travel with what they label and stay legible instead of
  /// shrinking with it.
  var rowLabels: [CALayer] = []
  var pinBadges: [NSView] = []
  /// `nonisolated(unsafe)`, as the container's own monitors are, so the
  /// deinit below can reach them.
  nonisolated(unsafe) var keyMonitor: Any?
  nonisolated(unsafe) var clickMonitor: Any?
  /// The pins that hold the map's own layout, dropped again on close.
  var mapConstraints: [NSLayoutConstraint] = []
  var selection: PaneMapGeometry.Slot
  /// The pane each column hands back to a sideways move. Seeded from the
  /// live layout and kept here rather than on the columns, so cancelling
  /// the map leaves every workspace's own focus untouched.
  var preferredPanes: [[Int]]
  /// Row frames and the selected pane's rect the current transforms were
  /// computed from, so a layout pass that moves something can be told
  /// apart from one that doesn't — the camera is aimed at the selection,
  /// and a row can scroll its columns sideways without moving itself.
  var rowFrames: [CGRect] = []
  var selectionRect: CGRect = .null
  /// When the camera stops moving. A hover before then would pick the
  /// pane that is about to arrive under the pointer, not the one there.
  var cameraSettles: CFTimeInterval = 0
  /// Aiming the camera now moves the rows, which is a layout change, so it
  /// must not run from inside a layout pass or start itself again.
  var aiming = false
  var aimScheduled = false
  /// The window the rows were measured against. They are pinned to
  /// constants taken from it, so a different one means the map has to go.
  var windowSize: CGSize = .zero

  init(
    shield: PaneMapShieldView,
    background: CGColor?,
    selection: PaneMapGeometry.Slot,
    preferredPanes: [[Int]]
  ) {
    self.shield = shield
    self.background = background
    self.selection = selection
    self.preferredPanes = preferredPanes
  }

  /// Take the map's monitors off, once. Clearing them as well is what
  /// makes it once: `deinit` calls this too, and AppKit does not support
  /// being handed the same monitor twice.
  ///
  /// Closing the map calls it rather than leaving it to `deinit`, because
  /// a key monitor that outlives the map answers every bare key in the
  /// app with `nil` — a dead keyboard, not a leak.
  nonisolated func removeMonitors() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    keyMonitor = nil
    clickMonitor = nil
  }

  /// The window can be closed with the map still up, which the map never
  /// hears about: the title bar is outside what it covers, so the click
  /// that closes the window never reaches its own watcher.
  deinit { removeMonitors() }
}

/// The bar along the bottom of the map: what is selected, and the keys
/// that act on it. Screen-space — a child of the shield rather than of a
/// row — so it stays the same size whatever the map is scaled to.
final class PaneMapGuideView: NSView {
  private let titleLabel = NSTextField(labelWithString: "")
  private let keysLabel = NSTextField(labelWithString: "")

  var title: String = "" {
    didSet {
      titleLabel.stringValue = title
      needsLayout = true
    }
  }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
    titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingTail
    keysLabel.font = .systemFont(ofSize: 11.5)
    keysLabel.stringValue = "←↑↓→ / hjkl  Move     ⏎  Open     ⎋  Close"
    for label in [titleLabel, keysLabel] {
      label.translatesAutoresizingMaskIntoConstraints = false
      addSubview(label)
    }
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      keysLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      keysLabel.trailingAnchor.constraint(lessThanOrEqualTo: titleLabel.trailingAnchor),
      keysLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
      keysLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
    ])
    applyColors()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  private func applyColors() {
    layer?.backgroundColor = AppColors.popoverSurface.cgColor(under: effectiveAppearance)
    layer?.borderWidth = 1
    layer?.borderColor = AppColors.findBarBorder.cgColor(under: effectiveAppearance)
    titleLabel.textColor = .labelColor
    keysLabel.textColor = .secondaryLabelColor
  }
}

/// Covers the workspaces while the map is open, so a click picks a pane to
/// go to rather than landing in one, and the pointer stops picking up the
/// cursors the panes set for themselves.
final class PaneMapShieldView: NSView {
  var onClick: ((NSPoint) -> Void)?
  var onHover: ((NSPoint) -> Void)?
  var onScroll: ((CGSize) -> Void)?

  override func hitTest(_ point: NSPoint) -> NSView? {
    frame.contains(point) ? self : nil
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .arrow)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
        owner: self))
  }

  override func mouseDown(with event: NSEvent) {
    onClick?(convert(event.locationInWindow, from: nil))
  }

  override func mouseMoved(with event: NSEvent) {
    onHover?(convert(event.locationInWindow, from: nil))
  }

  override func rightMouseDown(with event: NSEvent) {}
  override func otherMouseDown(with event: NSEvent) {}

  override func scrollWheel(with event: NSEvent) {
    onScroll?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
  }
}

extension PaneContainerViewController {
  /// How far the map shrinks the workspaces: far enough that a workspace
  /// wider than the window fits in a row of it, and not so far that a
  /// pane stops being recognisable from its own content.
  static let paneMapScale: CGFloat = 0.42

  /// Space between two workspace rows, as a fraction of the window height.
  /// Enough to read as a break between workspaces and to carry the row's
  /// name without it looking like it belongs to the row above, and no more
  /// — the rows are what the map is for.
  static let paneMapRowGap: CGFloat = 0.12

  /// Breathing room kept between the map and the window's edges, so a row
  /// never sits flush against one and the first row's name has somewhere
  /// to be.
  static let paneMapEdgeMargin: CGFloat = 44

  /// Short enough to read as the map arriving rather than as a wait.
  static let paneMapZoomDuration: CFTimeInterval = 0.12
  /// How heavily the panes the selection is not on are washed out.
  static let paneMapScrimAlpha: CGFloat = 0.45
  static let paneMapAnimationKey = "paneMapZoom"

  var isPaneMapOpen: Bool { paneMapSession != nil }

  func togglePaneMap() {
    isPaneMapOpen ? closePaneMap() : openPaneMap()
  }

  // MARK: - Open / close

  /// Lay every workspace out as a row, one above the other in index
  /// order, and shrink the lot around the focused pane. `applyPaneMapLayout`
  /// is where the shrinking happens and says how.
  func openPaneMap() {
    // A sidebar mid-transition still owes every row an inset and a scroll
    // origin, written from a block it has already queued. Those would land
    // on top of the map's own and slide each row's columns a sidebar's
    // width sideways, so wait for it the way a workspace switch is waited
    // for. A settled hover peek is the same problem one move away: the
    // pointer has to be on the sidebar to hold it open, so the first
    // twitch after the map appeared would retract it — and a retract
    // closes the map. Leave the peek to end on its own.
    guard !isPaneMapOpen, !isAnimatingWorkspaceSwitch, !isAnimatingSidebar,
      sidebarVC?.currentState != .hoverPeek,
      let rootLayer = view.layer, let focused = focusedPane
    else { return }
    // Both are child windows: they float above the map at full size, and
    // keystrokes aimed at them never reach the map's key monitor. The
    // workspace switch drops them for the same reason.
    dismissAllFindSessions(in: currentWorkspace)
    focused.urlBar.dismissSuggestionDropdown()
    // The live origin is about to become the map's; park the logical one
    // on the model, which is where closing reads it back from and what a
    // session save while the map is open will write out.
    currentWorkspace.scrollX = scrollView.contentView.bounds.origin.x - hoverPeekScrollCompensation

    let shield = PaneMapShieldView(frame: view.bounds)
    shield.autoresizingMask = [.width, .height]
    shield.wantsLayer = true
    // Under the sidebar, which stays live: it highlights rows on hover and
    // shows their close buttons, so making it inert would leave it looking
    // clickable and doing nothing. Clicking it leaves the map instead (see
    // the mouse monitor below).
    if let edgeHitZone {
      view.addSubview(shield, positioned: .below, relativeTo: edgeHitZone)
    } else {
      view.addSubview(shield)
    }
    let session = PaneMapSession(
      shield: shield,
      background: rootLayer.backgroundColor,
      selection: PaneMapGeometry.Slot(
        workspace: focusedWorkspaceIndex,
        column: focusedColumnIndex,
        pane: columns[safe: focusedColumnIndex]?.focusedPaneIndex ?? 0,
        rect: focused.containerView.convert(focused.containerView.bounds, to: view)),
      preferredPanes: workspaces.map { $0.columns.map(\.focusedPaneIndex) })
    let guide = PaneMapGuideView()
    guide.translatesAutoresizingMaskIntoConstraints = false
    shield.addSubview(guide)
    NSLayoutConstraint.activate([
      guide.centerXAnchor.constraint(equalTo: shield.centerXAnchor),
      guide.bottomAnchor.constraint(equalTo: shield.bottomAnchor, constant: -20),
      guide.widthAnchor.constraint(lessThanOrEqualTo: shield.widthAnchor, multiplier: 0.6),
    ])
    session.guide = guide
    shield.onClick = { [weak self] point in self?.paneMapClick(at: point) }
    shield.onHover = { [weak self] point in self?.paneMapHover(at: point) }
    shield.onScroll = { [weak self] delta in self?.panPaneMap(by: delta) }
    rootLayer.backgroundColor = NSColor.underPageBackgroundColor.cgColor(
      under: view.effectiveAppearance)
    // A hover-peek would rewrite every row's leading inset and scroll
    // offset underneath the map, so the edge that arms one is off for the
    // duration. The rest of the sidebar stays live.
    session.edgeHitZoneWasHidden = edgeHitZone?.isHidden ?? false
    edgeHitZone?.isHidden = true
    // Before the rows are moved, not after: `viewDidLayout` parks every
    // non-current workspace at ±window.height unless the map is open, and
    // the layout passes below would put the rows it has just spread out
    // back on top of each other.
    paneMapSession = session

    // Where the selected pane is at full size, for the zoom to start from.
    let before = focused.containerView.convert(focused.containerView.bounds, to: view)
    applyPaneMapLayout()
    session.selection = PaneMapGeometry.Slot(
      workspace: session.selection.workspace,
      column: session.selection.column,
      pane: session.selection.pane,
      rect: paneMapRect(of: session.selection) ?? session.selection.rect)
    aimPaneMapCamera(animated: false)
    highlightPaneMapSelection()
    addPaneMapRowLabels()
    addPaneMapPinBadges()
    if let after = paneMapRect(of: session.selection) {
      zoomPaneMapRows(workspaceVCs, from: before, to: after, duration: Self.paneMapZoomDuration)
      // The rows are where they will be, but are drawn on their way there.
      // A hover reading the layout now would pick the pane about to arrive
      // under the pointer rather than the one showing there.
      session.cameraSettles = CACurrentMediaTime() + Self.paneMapZoomDuration
    }

    session.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard let self, event.window === self.view.window else { return event }
      return self.handlePaneMapKey(event)
    }
    // A click on anything the map is not covering — the sidebar — is the
    // user leaving the map. Close it first and let the click go on to do
    // what it was aimed at, rather than have it switch workspace with the
    // rows still spread out.
    session.clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
      [weak self] event in
      // `hitTest` wants the point in the content view's *superview* — the
      // window's frame view, whose coordinates are the window's own. No
      // conversion: converting into the content view first only happens to
      // agree while the window carries a full-size content view.
      guard let self, let window = self.view.window, event.window === window,
        let hit = window.contentView?.hitTest(event.locationInWindow), hit !== shield
      else { return event }
      self.closePaneMap()
      return event
    }
    logger.info("open: workspaces=\(self.workspaceVCs.count) scale=\(Self.paneMapScale)")
  }

  func closePaneMap() {
    guard let session = paneMapSession else { return }
    restorePaneMapHighlight()
    for label in session.rowLabels { label.removeFromSuperlayer() }
    for badge in session.pinBadges { badge.removeFromSuperview() }
    paneMapSession = nil
    session.removeMonitors()
    for scrim in session.scrims.values { scrim.removeFromSuperview() }
    edgeHitZone?.isHidden = session.edgeHitZoneWasHidden
    session.shield.removeFromSuperview()
    view.layer?.backgroundColor = session.background

    let h = view.bounds.height
    NSLayoutConstraint.deactivate(session.mapConstraints)
    for (i, vc) in workspaceVCs.enumerated() {
      vc.trailingConstraint?.isActive = true
      vc.heightConstraint?.isActive = true
      vc.stackBottomConstraint?.isActive = true
      vc.scrollView.magnification = 1
      vc.scrollView.freezesScrolling = false
      vc.view.layer?.removeAnimation(forKey: Self.paneMapAnimationKey)
      vc.view.isHidden = i != focusedWorkspaceIndex
      vc.leadingConstraint?.constant = 0
      vc.topConstraint?.constant =
        i == focusedWorkspaceIndex ? 0 : (i < focusedWorkspaceIndex ? -h : h)
    }
    for vc in workspaceVCs { applyLeadingInset(in: vc) }
    // Restore the scroll offsets only once the rows are back to the
    // window's width — a clip view wider than its document clamps
    // whatever it is handed.
    view.layoutSubtreeIfNeeded()
    for vc in workspaceVCs {
      vc.scrollView.contentView.setBoundsOrigin(
        NSPoint(x: vc.workspace.scrollX + hoverPeekScrollCompensation, y: 0))
      vc.scrollView.reflectScrolledClipView(vc.scrollView.contentView)
    }
    logger.info("close")
  }

  /// Lay the workspaces out as rows of the map: each one zoomed out inside
  /// its own scroll view, sized to what it now occupies, stacked down the
  /// container.
  ///
  /// The zoom is `NSScrollView.magnification` — real geometry, the thing
  /// AppKit has for showing a whole document small — and not a layer
  /// transform. A transform shrinks only the picture: AppKit still lays
  /// the workspace out at full size, decides from *that* what is on
  /// screen, and never draws the panes it believes are off it. Terminals
  /// and web views host their own layers and would show up regardless,
  /// leaving a map that looks almost right with every suspended pane an
  /// empty rectangle.
  ///
  /// Two things have to be held still for the zoom not to reflow the
  /// panes: the column strip, which otherwise grows to fill a clip view
  /// that is now `1/scale` taller, and the row itself, which is no longer
  /// the height of the window.
  ///
  /// LIMITATION: a pinned column is a sibling of the scroll view rather
  /// than part of the document, so `magnification` does not reach it — it
  /// draws at full size over its row, and the top and bottom pins holding
  /// it to the row do shrink it, which reflows its panes for as long as
  /// the map is up. Moving it into the stack fixes both and cannot be
  /// done: a live pane does not survive leaving the view hierarchy (a
  /// terminal comes back with its scrollback gone and its keyboard dead).
  /// The remaining route is a fixed size plus a layer transform, with the
  /// map's own rects scaled to match for that one column.
  private func applyPaneMapLayout() {
    guard let session = paneMapSession else { return }
    let scale = Self.paneMapScale
    let rowHeight = view.bounds.height
    session.windowSize = view.bounds.size
    for (i, vc) in workspaceVCs.enumerated() {
      if vc.view.isHidden {
        vc.view.isHidden = false
        // The same reseed a workspace slide does: a terminal skips size
        // updates while hidden, so one parked across a window resize would
        // otherwise show at its old size.
        for column in vc.workspace.columns {
          for pane in column.panes { pane.terminalView?.resyncSurfaceSize() }
        }
      }
      // Drop the sidebar's share of the leading reserve for as long as the
      // map is up. On screen that lane is the sidebar; in the map it would
      // be an empty strip down the left of every row. The pinned column's
      // own reserve stays, and its overlay moves to where the lane starts.
      vc.scrollView.contentInsets.left = pinnedColumnReserve(in: vc)
      pinnedColumn(in: vc)?.pinLeadingConstraint?.constant = WorkspaceViewController.outerMargin
      let strip = max(vc.stackView.frame.width, vc.stackView.fittingSize.width)
      let content = vc.scrollView.contentInsets.left + strip
      let stripHeight = vc.stackView.frame.height

      vc.stackBottomConstraint?.isActive = false
      vc.trailingConstraint?.isActive = false
      vc.heightConstraint?.isActive = false
      let pins = [
        vc.stackView.heightAnchor.constraint(equalToConstant: stripHeight),
        vc.view.widthAnchor.constraint(equalToConstant: content * scale),
        vc.view.heightAnchor.constraint(equalToConstant: rowHeight * scale),
      ]
      NSLayoutConstraint.activate(pins)
      session.mapConstraints.append(contentsOf: pins)

      vc.scrollView.magnification = scale
      vc.scrollView.freezesScrolling = true
      vc.topConstraint?.constant =
        CGFloat(i - focusedWorkspaceIndex) * rowHeight * scale * (1 + Self.paneMapRowGap)
    }
    view.layoutSubtreeIfNeeded()
    // Show each row from its leading edge. `reflectScrolledClipView` as
    // well as the origin, or the scroll view still believes the row sits
    // where the user left it and puts it back on the next layout pass.
    for vc in workspaceVCs {
      vc.scrollView.contentView.setBoundsOrigin(
        NSPoint(x: -vc.scrollView.contentInsets.left, y: 0))
      vc.scrollView.reflectScrolledClipView(vc.scrollView.contentView)
    }
  }

  // MARK: - Camera and selection mark

  /// Where the map is allowed to sit: what the sidebar leaves visible,
  /// less a margin. Never against the window's very edge — a row flush
  /// with it reads as cut off, and the top row's name lives above it.
  ///
  /// Shared by aiming and clamping so the two cannot come to hold the map
  /// against different rectangles.
  private func paneMapViewport() -> CGRect {
    let viewport = CGRect(
      x: currentLeadingInset, y: 0,
      width: view.bounds.width - currentLeadingInset, height: view.bounds.height)
    let margin = min(Self.paneMapEdgeMargin, min(viewport.width, viewport.height) / 3)
    return viewport.insetBy(dx: margin, dy: margin)
  }

  /// Put the selection in the middle of the window, offset by however far
  /// scrolling has pushed the map, and hold the whole map against the
  /// window's edges.
  ///
  /// The rows are moved, not transformed: their positions are what AppKit
  /// lays out and draws from. `animated` slides them there from wherever
  /// they were, which is a transform, but a transient one.
  private func aimPaneMapCamera(animated: Bool) {
    guard let session = paneMapSession, !session.aiming,
      let rect = paneMapRect(of: session.selection)
    else { return }
    session.aiming = true
    defer { session.aiming = false }
    let before = workspaceVCs.map(\.view.frame.origin)
    let viewport = paneMapViewport()
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    // Scale 1: the rows are already at map size, so this is only asking
    // where to move them.
    let target = PaneMapGeometry.clampedTarget(
      CGPoint(x: viewport.midX, y: viewport.midY),
      box: workspaceVCs.map(\.view.frame).reduce(CGRect.null) { $0.union($1) },
      scale: 1,
      center: centre,
      viewport: viewport)
    for vc in workspaceVCs {
      vc.leadingConstraint?.constant += target.x - centre.x
      // A top constraint counts downward; the window's y counts up.
      vc.topConstraint?.constant -= target.y - centre.y
    }
    view.layoutSubtreeIfNeeded()
    session.rowFrames = workspaceVCs.map(\.view.frame)
    session.selectionRect = paneMapRect(of: session.selection) ?? rect
    session.cameraSettles =
      CACurrentMediaTime() + (animated ? Self.paneMapZoomDuration : 0)
    logPaneMapGeometry("aim")
    guard animated else { return }
    slidePaneMapRows(from: before, duration: Self.paneMapZoomDuration)
  }

  /// Put the map back inside the window without touching where it is
  /// pointed.
  ///
  /// What a layout pass can invalidate is the clamp — the window got
  /// smaller, the sidebar took a strip — not the user's aim. Re-aiming
  /// instead would pull the map to whatever is selected, and since a hover
  /// changes the selection, every pointer move would drag the whole map
  /// under the pointer. That is what "it jumps so the hovered pane is
  /// centred" was.
  private func clampPaneMapCamera() {
    guard let session = paneMapSession, !session.aiming else { return }
    session.aiming = true
    defer { session.aiming = false }
    let box = workspaceVCs.map(\.view.frame).reduce(CGRect.null) { $0.union($1) }
    guard !box.isNull else { return }
    let centre = CGPoint(x: box.midX, y: box.midY)
    let corrected = PaneMapGeometry.clampedTarget(
      centre, box: box, scale: 1, center: centre, viewport: paneMapViewport())
    if abs(corrected.x - centre.x) > 0.5 || abs(corrected.y - centre.y) > 0.5 {
      for vc in workspaceVCs {
        vc.leadingConstraint?.constant += corrected.x - centre.x
        vc.topConstraint?.constant -= corrected.y - centre.y
      }
      view.layoutSubtreeIfNeeded()
    }
    session.rowFrames = workspaceVCs.map(\.view.frame)
    session.selectionRect = paneMapRect(of: session.selection) ?? session.selectionRect
    logPaneMapGeometry("clamp")
  }

  /// One line saying where the map is and what moved it: several things
  /// can, and a map that drifts on its own is only tellable apart from one
  /// the user moved by which of them ran, and what the rows' own scroll
  /// offsets were doing at the time.
  private func logPaneMapGeometry(_ cause: String) {
    guard let session = paneMapSession else { return }
    logger.debug(
      "\(cause, privacy: .public): selection=\(session.selection.workspace)/\(session.selection.column)/\(session.selection.pane) rect=\(NSStringFromRect(session.selectionRect), privacy: .public) rows=\(self.workspaceVCs.map { NSStringFromRect($0.view.frame) }.joined(separator: " "), privacy: .public) origins=\(self.workspaceVCs.map { String(format: "%.0f", $0.scrollView.contentView.bounds.origin.x) }.joined(separator: " "), privacy: .public)"
    )
  }

  /// Carry the rows from where they were to where they now are. The
  /// animation is a transform and is gone when it lands, so what AppKit
  /// draws from stays the layout.
  private func slidePaneMapRows(from previous: [CGPoint], duration: CFTimeInterval) {
    for (i, vc) in workspaceVCs.enumerated() {
      guard let layer = vc.view.layer, let origin = previous[safe: i] else { continue }
      let dx = origin.x - vc.view.frame.minX
      let dy = origin.y - vc.view.frame.minY
      guard abs(dx) > 0.5 || abs(dy) > 0.5 else { continue }
      let slide = CABasicAnimation(keyPath: "transform")
      slide.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(dx, dy, 0))
      slide.toValue = NSValue(caTransform3D: CATransform3DIdentity)
      slide.duration = duration
      slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
      layer.add(slide, forKey: Self.paneMapAnimationKey)
    }
  }

  /// Zoom rows between two sizes of the same pane: the map opening out of
  /// the pane the user was in, or closing into the one they picked.
  ///
  /// Which rows, because the two are not the same set. Opening moves the
  /// whole map; landing moves only the row being landed on — by then the
  /// workspace switch has parked the others off the window, and a zoom
  /// would carry one of them back across it for the length of the
  /// animation.
  private func zoomPaneMapRows(
    _ vcs: [WorkspaceViewController], from: CGRect, to: CGRect, duration: CFTimeInterval
  ) {
    guard from.width > 1, to.width > 1 else { return }
    let scale = from.width / to.width
    let centre = CGPoint(x: to.midX, y: to.midY)
    let target = CGPoint(x: from.midX, y: from.midY)
    for vc in vcs {
      guard let layer = vc.view.layer else { continue }
      let frame = vc.view.frame
      // A layer scales about its anchor point, so the shift is what the
      // projection does to that one point.
      let anchor = CGPoint(
        x: frame.minX + layer.anchorPoint.x * frame.width,
        y: frame.minY + layer.anchorPoint.y * frame.height)
      let moved = PaneMapGeometry.project(anchor, scale: scale, center: centre, target: target)
      let zoom = CABasicAnimation(keyPath: "transform")
      zoom.fromValue = NSValue(
        caTransform3D: CATransform3DConcat(
          CATransform3DMakeScale(scale, scale, 1),
          CATransform3DMakeTranslation(moved.x - anchor.x, moved.y - anchor.y, 0)))
      zoom.toValue = NSValue(caTransform3D: CATransform3DIdentity)
      zoom.duration = duration
      zoom.timingFunction = CAMediaTimingFunction(name: .easeOut)
      layer.add(zoom, forKey: Self.paneMapAnimationKey)
    }
  }

  /// Scrolling moves the map rather than the selection, so the pointer can
  /// reach panes the zoom left off screen.
  ///
  /// A relative move from wherever the map is, never a re-aim with the
  /// accumulated scroll added on: the reference point would then move
  /// whenever the selection did, and since a hover changes the selection,
  /// the first scroll after one would snap the map over to centre whatever
  /// the pointer last passed over. The clamp still holds it in the window.
  private func panPaneMap(by delta: CGSize) {
    guard let session = paneMapSession, !session.aiming else { return }
    session.aiming = true
    // `scrollingDeltaX` is positive for a gesture revealing content to the
    // left, which moves the map right; the vertical pair is the same
    // reading in a coordinate space whose y grows upward.
    for vc in workspaceVCs {
      vc.leadingConstraint?.constant += delta.width
      vc.topConstraint?.constant += delta.height
    }
    view.layoutSubtreeIfNeeded()
    session.aiming = false
    clampPaneMapCamera()
  }

  /// Mark the selection by thickening the selected pane's own border,
  /// rather than by drawing a ring over the map.
  ///
  /// The border belongs to the pane's layer, so it is shrunk, scrolled and
  /// moved by exactly what moves the pane — there is no second copy of the
  /// map's geometry to drift out of step with the first, which is what two
  /// rounds of "the frame is in the wrong place" came down to. The width
  /// is divided by the map's scale so it reads at its usual weight.
  private func highlightPaneMapSelection() {
    guard let session = paneMapSession,
      let column = workspaces[safe: session.selection.workspace]?.columns[
        safe: session.selection.column],
      let pane = column.panes[safe: session.selection.pane]
    else { return }
    guard pane !== session.highlighted else { return }
    restorePaneMapHighlight()
    session.highlighted = pane
    // A folded column shows a strip instead of its panes, so the strip is
    // what gets marked — the same substitution the focus border makes.
    let marked = column.isFolded ? column.foldedLabelView : pane.containerView
    session.highlightedView = marked
    marked.wantsLayer = true
    marked.layer?.borderWidth = focusBorderWidth / Self.paneMapScale
    marked.layer?.borderColor = Self.accentColor(forWorkspaceAt: session.selection.workspace)
      .cgColor(under: view.effectiveAppearance)
    dimPaneMapPanes(except: marked)
    session.guide?.title = pane.title.isEmpty ? pane.address.description : pane.title
  }

  /// Everything but the selection sits back a little, so the eye lands on
  /// the marked pane before it reads any of the others.
  ///
  /// A cover laid over each pane rather than `alphaValue` on the pane
  /// itself. Lowering a pane's opacity asks AppKit to composite that whole
  /// subtree differently, and what went missing under it was exactly the
  /// content its panes draw for themselves — a suspended pane's logo and
  /// title, a start pane's logo — leaving the Reload button, which has a
  /// layer of its own, sitting alone on an empty pane. A cover can only
  /// wash what is underneath it.
  private func dimPaneMapPanes(except selected: NSView) {
    guard let session = paneMapSession else { return }
    // Cover every pane once, then move the hole as the selection moves.
    // Rebuilding the covers on each pointer move would churn the view tree
    // on every hover, for a picture that changes in two places.
    let wash = NSColor.underPageBackgroundColor
      .withAlphaComponent(Self.paneMapScrimAlpha)
      .cgColor(under: view.effectiveAppearance)
    for host in paneMapPaneHosts() where host !== selected {
      guard session.scrims[ObjectIdentifier(host)] == nil else { continue }
      let scrim = NSView(frame: host.bounds)
      scrim.autoresizingMask = [.width, .height]
      scrim.wantsLayer = true
      scrim.layer?.backgroundColor = wash
      scrim.layer?.cornerRadius = host.layer?.cornerRadius ?? 0
      host.addSubview(scrim)
      session.scrims[ObjectIdentifier(host)] = scrim
    }
    session.scrims.removeValue(forKey: ObjectIdentifier(selected))?.removeFromSuperview()
  }

  /// Every view the map dims or marks: a pane, or the strip a folded
  /// column shows instead of its panes.
  private func paneMapPaneHosts() -> [NSView] {
    workspaces.flatMap { workspace in
      workspace.columns.flatMap { column -> [NSView] in
        column.isFolded ? [column.foldedLabelView] : column.panes.map(\.containerView)
      }
    }
  }

  /// Name each row in the gap above it, so a row is identifiable when its
  /// panes are too small to read. Parented to the row for the same reason
  /// the selection border is: it then travels with it for free.
  private func addPaneMapRowLabels() {
    guard let session = paneMapSession else { return }
    let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    for (i, vc) in workspaceVCs.enumerated() {
      guard let rowLayer = vc.view.layer else { continue }
      let text = vc.workspace.displayName(at: i) as NSString
      let size = text.size(withAttributes: [.font: font])
      let plate = CALayer()
      plate.anchorPoint = .zero
      plate.bounds = CGRect(x: 0, y: 0, width: size.width + 10, height: size.height)
      // Row coordinates: just above the row's top edge, close enough to
      // read as this row's name rather than the one above's. The row
      // itself is not scaled — only the workspace inside it is — so the
      // name is drawn at its natural size and stays legible.
      plate.position = CGPoint(
        x: WorkspaceViewController.outerMargin, y: vc.view.bounds.height + 2)

      let bar = CALayer()
      bar.anchorPoint = .zero
      bar.frame = CGRect(x: 0, y: 0, width: 3, height: size.height)
      bar.cornerRadius = 1.5
      bar.backgroundColor = Self.accentColor(forWorkspaceAt: i)
        .cgColor(under: view.effectiveAppearance)
      plate.addSublayer(bar)

      let title = CATextLayer()
      title.anchorPoint = .zero
      title.frame = CGRect(x: 9, y: 0, width: size.width, height: size.height)
      title.string = text
      title.font = font
      title.fontSize = font.pointSize
      title.foregroundColor = NSColor.secondaryLabelColor.cgColor(under: view.effectiveAppearance)
      title.contentsScale = view.window?.backingScaleFactor ?? 2
      plate.addSublayer(title)

      rowLayer.addSublayer(plate)
      session.rowLabels.append(plate)
    }
  }

  /// Hand the highlighted pane's border back: the one its workspace's
  /// focus gives it, or none.
  private func restorePaneMapHighlight() {
    guard let session = paneMapSession, let pane = session.highlighted else { return }
    session.highlighted = nil
    session.highlightedView?.layer?.borderWidth = 0
    session.highlightedView?.layer?.borderColor = nil
    session.highlightedView = nil
    let workspace = workspaceContaining(pane: pane)
    let isFocused =
      workspace.map { ws in
        ws.columns[safe: ws.focusedColumnIndex]?.focusedPane?.id == pane.id
      } ?? false
    if isFocused { applyFocusBorder(pane, in: workspace) }
  }

  /// Mark pinned columns while the map is up. On screen a pin explains
  /// itself — the other columns slide under it — but the map shows every
  /// column at rest, where it would read as just the leftmost one.
  private func addPaneMapPinBadges() {
    guard let session = paneMapSession else { return }
    let side: CGFloat = 15
    let inset: CGFloat = 9
    for (i, vc) in workspaceVCs.enumerated() {
      guard let column = pinnedColumn(in: vc),
        let glyph = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
      else { continue }
      // A view, not a layer: AppKit inserts a layer-backed view's own
      // subviews *above* any sublayer added by hand, so a layer here would
      // sit under the very column it marks. (The row name plates get away
      // with being layers only because they hang in the gap, over no
      // subview at all.)
      let badge = NSImageView(image: glyph)
      badge.imageScaling = .scaleProportionallyUpOrDown
      badge.contentTintColor = Self.accentColor(forWorkspaceAt: i)
      let rect = column.containerView.convert(column.containerView.bounds, to: vc.view)
      badge.frame = CGRect(
        x: rect.minX + inset, y: rect.maxY - side - inset, width: side, height: side)
      vc.view.addSubview(badge, positioned: .above, relativeTo: column.containerView)
      session.pinBadges.append(badge)
    }
  }

  // MARK: - Selection

  /// Every pane's rect, grouped workspace → column → pane in the
  /// container's coordinate space. Read fresh on each move: the rows are
  /// laid out by Auto Layout, so this is where their geometry lives.
  private func paneMapSlots() -> [[[PaneMapGeometry.Slot]]] {
    workspaces.enumerated().map { wsIndex, workspace in
      workspace.columns.enumerated().map { columnIndex, column -> [PaneMapGeometry.Slot] in
        // A folded column is one target, not one per pane: its panes all
        // answer with the same strip, so a click would always resolve to
        // the first of them — silently moving the column off the pane the
        // user was on — and a move down would step through identical
        // rects, leaving the selection mark still while the key repeated.
        guard !column.isFolded else {
          return [
            PaneMapGeometry.Slot(
              workspace: wsIndex,
              column: columnIndex,
              pane: column.focusedPaneIndex,
              rect: column.containerView.convert(column.containerView.bounds, to: view))
          ]
        }
        return column.panes.enumerated().map { paneIndex, pane in
          PaneMapGeometry.Slot(
            workspace: wsIndex,
            column: columnIndex,
            pane: paneIndex,
            rect: paneMapRect(of: pane, in: column))
        }
      }
      // Left to right as drawn: a pinned column leaves the scrolling
      // stack for the row's leading edge, so its index no longer says
      // where it is.
      .sorted { ($0.first?.rect.minX ?? 0) < ($1.first?.rect.minX ?? 0) }
    }
  }

  /// Where a pane sits on the map. A folded column hides its panes behind
  /// a 30pt strip, so every pane in one answers with the strip: it is what
  /// the map shows, and what a move into that column should land on.
  private func paneMapRect(of pane: PaneModel, in column: ColumnModel) -> CGRect {
    let host = column.isFolded ? column.containerView : pane.containerView
    return host.convert(host.bounds, to: view)
  }

  private func paneMapRect(of slot: PaneMapGeometry.Slot) -> CGRect? {
    guard let column = workspaces[safe: slot.workspace]?.columns[safe: slot.column],
      let pane = column.panes[safe: slot.pane]
    else { return nil }
    return paneMapRect(of: pane, in: column)
  }

  private func selectInPaneMap(_ slot: PaneMapGeometry.Slot, moveCamera: Bool) {
    guard let session = paneMapSession, slot != session.selection else { return }
    session.selection = slot
    // The watcher that re-aims after a layout pass compares the selected
    // pane's rect with the one the camera was aimed from. Moving the
    // selection is not the map moving, so it gets the new rect here — or
    // the watcher reads the difference as the map having shifted and
    // recentres, which is the hover dragging the whole map around.
    session.selectionRect = paneMapRect(of: slot) ?? slot.rect
    if session.preferredPanes.indices.contains(slot.workspace),
      session.preferredPanes[slot.workspace].indices.contains(slot.column)
    {
      session.preferredPanes[slot.workspace][slot.column] = slot.pane
    }
    highlightPaneMapSelection()
    // A key press recentres on what it selected, wherever scrolling had
    // left the map. A hover leaves the map alone: the pointer is resting
    // on a pane, and pulling the map out from under it would send the
    // selection somewhere the user is not pointing.
    guard moveCamera else { return }
    aimPaneMapCamera(animated: true)
  }

  private func movePaneMapSelection(_ direction: PaneMapGeometry.Direction) {
    guard let session = paneMapSession else { return }
    guard
      let next = PaneMapGeometry.neighbor(
        of: session.selection,
        direction: direction,
        in: paneMapSlots(),
        preferring: session.preferredPanes)
    else { return }
    selectInPaneMap(next, moveCamera: true)
  }

  /// Close the map and put focus on the selected pane, bringing its
  /// column into view the way a hover focus does.
  private func confirmPaneMapSelection() {
    guard let session = paneMapSession, let picked = paneMapRect(of: session.selection) else {
      return
    }
    let slot = session.selection
    // Where the pane is on screen right now, shrunk into the map. The
    // layout is about to become the one it will land in, and this is what
    // the zoom below starts from. Already on-screen coordinates: the map
    // is laid out at map size rather than drawn that way.
    let from = picked
    closePaneMap()
    guard let workspace = workspaces[safe: slot.workspace],
      let column = workspace.columns[safe: slot.column],
      column.panes.indices.contains(slot.pane)
    else { return }
    workspace.focusedColumnIndex = slot.column
    column.focusedPaneIndex = slot.pane
    if slot.workspace == focusedWorkspaceIndex {
      setFocus(columnIndex: slot.column, paneIndex: slot.pane, scroll: false)
    } else {
      // The switch restores focus from the indices just set. No slide: the
      // zoom is the transition.
      switchWorkspace(to: slot.workspace, duration: 0)
    }
    settlePaneMapColumn(at: slot.column)
    view.layoutSubtreeIfNeeded()
    if let landed = paneMapRect(of: slot), let vc = workspaceVCs[safe: slot.workspace] {
      zoomPaneMapRows([vc], from: from, to: landed, duration: Self.paneMapZoomDuration)
    }
  }

  /// Bring the column into view without the animated scroll `.settle`
  /// normally makes: the zoom is the animation, and it has to be measured
  /// against the layout it is zooming to.
  private func settlePaneMapColumn(at index: Int) {
    guard let column = columns[safe: index], !column.isPinned,
      let logicalX = computeScrollTargetX(for: column, mode: .settle)
    else { return }
    scrollView.contentView.setBoundsOrigin(
      NSPoint(x: logicalX + hoverPeekScrollCompensation, y: 0))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  private func paneMapSlot(at point: NSPoint) -> PaneMapGeometry.Slot? {
    guard let session = paneMapSession else { return nil }
    // The shield answers for everything it covers, the guide bar included.
    // That bar is a caption over whichever row happens to be behind it, and
    // neither pointing at a legend nor clicking one asks to go anywhere.
    if let guide = session.guide, guide.frame.contains(point) { return nil }
    // The rects are where the panes are: the map is laid out at its size,
    // not painted at it.
    return paneMapSlots().joined().joined().first { $0.rect.contains(point) }
  }

  private func paneMapClick(at point: NSPoint) {
    guard let slot = paneMapSlot(at: point) else { return }
    selectInPaneMap(slot, moveCamera: false)
    confirmPaneMapSelection()
  }

  private func paneMapHover(at point: NSPoint) {
    // Hovering rides on the same preference as hover focus: with it off
    // the map answers the keyboard and clicks only. A hover mid-pan reads
    // the camera it is heading for, so the map has to have arrived.
    guard PreferencesStore.shared.preferences.focusPaneUnderCursor == true,
      let session = paneMapSession, CACurrentMediaTime() >= session.cameraSettles,
      let slot = paneMapSlot(at: point)
    else { return }
    selectInPaneMap(slot, moveCamera: false)
  }

  /// Put the map back in the window after a layout pass moved what the
  /// camera was clamped against, and leave it when a pass has taken the
  /// map's own ground away.
  ///
  /// **On the next tick, never from inside the pass**: both answers move
  /// the rows, and a layout change made during a layout pass asks the
  /// window to lay out again, which AppKit aborts the app over once it
  /// stops converging.
  func reapplyPaneMapCameraIfGeometryMoved() {
    // An empty record means the map is still being opened — the layout
    // passes that spread the rows out are its own, and it aims the camera
    // itself once they have run.
    guard let session = paneMapSession, !session.rowFrames.isEmpty, !session.aiming,
      !session.aimScheduled
    else { return }
    let selected = paneMapRect(of: session.selection)
    // The rows are pinned to constants measured at open — the window's
    // height, each row's own width — and the name plates and pin badges
    // are placed against those, one row at a time. A window that has
    // changed size, a workspace that has come or gone, or a selection
    // whose pane has closed underneath it all need the map built again
    // rather than nudged; leaving is the honest answer.
    guard view.bounds.size == session.windowSize,
      workspaceVCs.count == session.rowFrames.count, selected != nil
    else {
      session.aimScheduled = true
      DispatchQueue.main.async { [weak self] in
        self?.paneMapSession?.aimScheduled = false
        self?.closePaneMap()
      }
      return
    }
    guard
      session.rowFrames != workspaceVCs.map(\.view.frame)
        || session.selectionRect != selected
    else { return }
    session.aimScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self, let session = self.paneMapSession else { return }
      session.aimScheduled = false
      self.clampPaneMapCamera()
    }
  }

  // MARK: - Keys

  /// The map takes every bare key so the focused pane underneath doesn't
  /// see any of them. A chord leaves the map first and then goes on to do
  /// what it says, rather than running against the shrunk layout; the
  /// map's own chord just closes it.
  private func handlePaneMapKey(_ event: NSEvent) -> NSEvent? {
    // First, so that the binding still closes the map when it has been
    // remapped to a bare key: the switch below answers every one of those
    // and would swallow it without ever asking.
    guard !isPaneMapToggle(event) else {
      closePaneMap()
      return nil
    }
    let chord = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.shift, .capsLock, .numericPad, .function])
    guard chord.isEmpty else {
      closePaneMap()
      return event
    }
    switch event.keyCode {
    case KeyCode.escape: closePaneMap()
    case KeyCode.returnKey, KeyCode.numpadEnter: confirmPaneMapSelection()
    case KeyCode.leftArrow: movePaneMapSelection(.left)
    case KeyCode.rightArrow: movePaneMapSelection(.right)
    case KeyCode.upArrow: movePaneMapSelection(.up)
    case KeyCode.downArrow: movePaneMapSelection(.down)
    default:
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "h": movePaneMapSelection(.left)
      case "l": movePaneMapSelection(.right)
      case "k": movePaneMapSelection(.up)
      case "j": movePaneMapSelection(.down)
      default: break
      }
    }
    return nil
  }

  /// Whether the event is the chord currently bound to the map, override
  /// included — swallowing it is what keeps the close from being undone
  /// by the menu running the toggle straight after.
  private func isPaneMapToggle(_ event: NSEvent) -> Bool {
    guard let action = menuActionsSnapshot.first(where: { $0.id == "toggle_pane_map" }),
      let key = action.keyEquivalent,
      event.charactersIgnoringModifiers?.lowercased() == key.lowercased()
    else { return false }
    let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    return event.modifierFlags.intersection(mask) == action.modifierMask.intersection(mask)
  }
}
