import AppKit

/// Root visual container of the sidebar. Wraps an `NSGlassEffectView`
/// (macOS 26 Tahoe Liquid Glass) whose `contentView` hosts the header,
/// the mode-dependent content area (worklane / per-mode views /
/// placeholder), and the bottom places section.
///
/// Subviews must be added to `contentView` — adding siblings outside
/// of it carries no z-order guarantee (Apple, WWDC25 session 310).
/// Multiple glass panels (e.g. per-workspace accent bars) would need
/// an `NSGlassEffectContainerView` so AppKit merges them liquidly; the
/// current single-glass layout doesn't benefit from one.
///
/// The mode area hosts four visually exclusive views (`worklane`,
/// `bookmarksView`, `historyView`, `downloadsView`) plus a
/// `placeholder` fallback, all sharing the same rect. `applyMode`
/// flips `isHidden` on exactly one.
@MainActor
final class SidebarOverlayView: NSView {
  let header = SidebarHeaderView()
  let worklane = WorklaneSectionView()
  let placeholder = PlaceholderContentView()
  let places = PlacesSectionView()

  /// Called when the cursor enters the sidebar's visible footprint.
  /// The state machine uses this together with `onHoverExit` to keep
  /// `.hoverPeek` alive while the user is interacting with the sidebar
  /// contents (clicking a bookmark, scrolling, resizing a window).
  var onHoverEnter: (() -> Void)?
  /// Called when the cursor actually leaves the sidebar. Spurious
  /// `mouseExited` events from nested subview tracking areas are
  /// filtered out before this fires (see `cursorIsStillInsideBounds`).
  var onHoverExit: (() -> Void)?

  private var hoverTrackingArea: NSTrackingArea?

  /// Current bookmarks-mode view, installed by the view controller
  /// once the container reference (which owns the `Bookmarks` store)
  /// is available. Nil until then; `applyMode(.bookmarks)` tolerates
  /// the absence by falling through to the placeholder.
  private(set) var bookmarksView: NSView?

  /// Current history-mode view, installed by the view controller
  /// once the container reference (which owns the `BrowsingHistory`
  /// store) is available. Nil until then; `applyMode(.history)`
  /// tolerates the absence by falling through to the placeholder.
  private(set) var historyView: NSView?

  /// Current downloads-mode view, installed by the view controller
  /// once the container reference (which owns the `DownloadsManager`)
  /// is available. Nil until then; `applyMode(.downloads)` tolerates
  /// the absence by falling through to the placeholder.
  private(set) var downloadsView: NSView?

  /// Current extensions-mode view, installed by the view controller
  /// once the container reference is set (the view subscribes to the
  /// process-lifetime `ExtensionController` singleton, but the install
  /// path mirrors the other modes for symmetry). Nil until then;
  /// `applyMode(.extensions)` tolerates the absence by falling through
  /// to the placeholder.
  private(set) var extensionsView: NSView?

  private let glass = NSGlassEffectView()
  private let content = NSView()

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    translatesAutoresizingMaskIntoConstraints = false
    setupGlass()
    setupContent()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setupGlass() {
    glass.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    // NSGlassEffectView attaches its `contentView` lazily: right after
    // assignment `content.superview` is still nil; AppKit wires it in
    // during the first layout pass (observed on macOS 26 Tahoe beta).
    // Trust the Apple docs' Auto Layout guarantee and let the layout
    // cycle run — manual testing confirms header renders correctly
    // without explicit pinning.
    glass.contentView = content
    addSubview(glass)
    NSLayoutConstraint.activate([
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    glass.wantsLayer = true
    glass.layer?.cornerRadius = AppMetrics.surfaceCornerRadius
    glass.layer?.cornerCurve = .continuous
    glass.layer?.masksToBounds = true
    applyGlassTint()
  }

  /// Keep the glass tint in sync with the current appearance so the
  /// sidebar doesn't look brighter than the surrounding workspace
  /// chrome when the user is in dark mode. In light mode we leave
  /// `tintColor` nil — the OS default already blends with the bright
  /// workspace background.
  private func applyGlassTint() {
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    glass.tintColor = isDark ? AppColors.sidebarGlassTint : nil
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyGlassTint()
  }

  private func setupContent() {
    content.addSubview(header)
    content.addSubview(worklane)
    content.addSubview(placeholder)
    content.addSubview(places)
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: content.topAnchor),
      header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: content.trailingAnchor),

      // worklane and placeholder occupy the same rect — only one
      // is visible at a time, toggled by the view controller in
      // response to mode changes. Worklane is pinned to the full
      // available height (rather than `lessThanOrEqualTo`) so its
      // internal scroll view has a bounded frame to scroll within;
      // letting it shrink with content meant unbounded growth pushed
      // the sidebar past the window edge as workspaces accumulated.
      worklane.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
      worklane.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
      worklane.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
      worklane.bottomAnchor.constraint(equalTo: places.topAnchor, constant: -8),

      placeholder.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
      placeholder.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
      placeholder.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
      placeholder.bottomAnchor.constraint(equalTo: places.topAnchor, constant: -8),

      places.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
      places.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
      places.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
    ])

    // Default state: Tabs mode visible, placeholder hidden. The view
    // controller re-synchronises this on its first `applyMode` call.
    placeholder.isHidden = true
  }

  /// Install the bookmarks-mode view into the shared mode area. Called
  /// by the view controller after `container` is available (the view
  /// needs the `Bookmarks` store from the container to subscribe for
  /// mutations). Starts hidden; `applyMode(.bookmarks)` toggles it.
  func setBookmarksView(_ view: NSView) {
    bookmarksView?.removeFromSuperview()
    bookmarksView = view
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isHidden = true
    content.addSubview(view)
    NSLayoutConstraint.activate([
      view.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
      view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
      view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
      view.bottomAnchor.constraint(equalTo: places.topAnchor, constant: -8),
    ])
  }

  /// Install the history-mode view into the shared mode area. Mirrors
  /// `setBookmarksView`: same rect, same hidden-by-default state; the
  /// view controller flips visibility on mode change.
  func setHistoryView(_ view: NSView) {
    historyView?.removeFromSuperview()
    historyView = view
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isHidden = true
    content.addSubview(view)
    NSLayoutConstraint.activate([
      view.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
      view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
      view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
      view.bottomAnchor.constraint(equalTo: places.topAnchor, constant: -8),
    ])
  }

  /// Install the downloads-mode view into the shared mode area.
  /// Mirrors `setBookmarksView` / `setHistoryView`: same rect, same
  /// hidden-by-default state; the view controller flips visibility on
  /// mode change.
  func setDownloadsView(_ view: NSView) {
    downloadsView?.removeFromSuperview()
    downloadsView = view
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isHidden = true
    content.addSubview(view)
    NSLayoutConstraint.activate([
      view.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
      view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
      view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
      view.bottomAnchor.constraint(equalTo: places.topAnchor, constant: -8),
    ])
  }

  /// Install the extensions-mode view into the shared mode area.
  /// Mirrors the other `set…View` installers — same rect, same
  /// hidden-by-default state; the view controller flips visibility on
  /// mode change.
  func setExtensionsView(_ view: NSView) {
    extensionsView?.removeFromSuperview()
    extensionsView = view
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isHidden = true
    content.addSubview(view)
    NSLayoutConstraint.activate([
      view.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
      view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
      view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
      view.bottomAnchor.constraint(equalTo: places.topAnchor, constant: -8),
    ])
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let old = hoverTrackingArea { removeTrackingArea(old) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    hoverTrackingArea = area
    syncHoverWithCurrentCursor()
  }

  // Cursor over the sidebar's transparent gaps must read as `arrow`,
  // not whatever the workspace pane underneath would install (link
  // hover → pointing hand, text → I-beam). Use the older cursor-rect
  // mechanism rather than a `cursorUpdate` tracking area: AppKit
  // resolves cursor rects hierarchically so a row's own cursor rect
  // (PaneRow / WorkspaceHeaderRow / PlacesRow / SidebarListCellView →
  // pointing hand) wins over this fallback when the cursor is over
  // its bounds. A `cursorUpdate` tracking area on the overlay would
  // have out-claimed every child instead, breaking row hover cursors
  // entirely (verified regression in macOS 26 Tahoe).
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .arrow)
  }

  /// Block click-through in the sidebar's transparent regions. The
  /// glass panel intentionally has empty space between rows and around
  /// the worklane, but those gaps must still feel like sidebar surface
  /// to the user — clicking there should not select text or follow a
  /// link in the workspace pane sitting visually behind the sidebar.
  ///
  /// `NSGlassEffectView` reports its transparent areas as non-hit
  /// (returns nil for points its own subviews don't cover), so without
  /// this override AppKit descends past the sidebar overlay and lands
  /// on the workspace pane underneath. Forcing a non-nil return for
  /// any in-bounds point closes that gap.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard !isHidden, window != nil, bounds.contains(local) else {
      return super.hitTest(point)
    }
    return super.hitTest(point) ?? self
  }

  // Final-stop absorbers for any click that bubbles up through the
  // responder chain from a structural subview (NSGlassEffectView's
  // content `NSView`, the empty padding around `worklane` /
  // `places` / `header`, etc.) without one of the per-container
  // absorbers (`FlippedClipView` for worklane, `PlacesSectionView`
  // for the bottom strip) catching it first. Without this the
  // `NSResponder` default forwards mouseDown all the way up past the
  // overlay, where `NSGlassEffectView`'s pass-through delivers the
  // click to the workspace pane visually beneath.
  override func mouseDown(with _: NSEvent) {}
  override func mouseDragged(with _: NSEvent) {}
  override func mouseUp(with _: NSEvent) {}

  override func mouseEntered(with _: NSEvent) { onHoverEnter?() }

  override func mouseExited(with _: NSEvent) {
    // Nested tracking areas (hover-reveal buttons in sidebar cells,
    // pin button, row hover) fire spurious parent `mouseExited` when
    // the cursor crosses into their subrect. Re-check the global
    // cursor position against our bounds and suppress the exit if
    // the cursor is still inside — otherwise `.hoverPeek` would
    // collapse the moment the user tries to interact with a cell.
    if cursorIsStillInsideBounds() { return }
    onHoverExit?()
  }

  /// Mirrors the probe in `EdgeHoverHitZoneView`: AppKit skips the
  /// synthesised `mouseEntered` when a freshly rebuilt tracking area
  /// already contains the cursor (e.g. the hoverPeek animation brings
  /// the sidebar out from under a stationary pointer). Probe only in
  /// the inside direction — firing `onHoverExit` here would race with
  /// the sidebar state machine's pending hover-in/hover-out timers
  /// and invalidate them via the shared generation counter, which
  /// regressed the edge-hover path entirely. Real exits still arrive
  /// through `mouseExited`.
  private func syncHoverWithCurrentCursor() {
    guard let window else { return }
    let mouseInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    if bounds.contains(mouseInView) {
      onHoverEnter?()
    }
  }
}
