import AppKit
import GhosttyKit

public final class PaneContainerViewController: NSViewController {
  let ghosttyApp: GhosttyApp
  public let browsingHistory = BrowsingHistory()
  public let bookmarks = Bookmarks()
  public let downloadsStore: DownloadsStore
  public let downloadsManager: DownloadsManager

  public internal(set) var workspaces: [WorkspaceModel] = [WorkspaceModel()]
  /// Parallel to `workspaces`: the child view controller hosting each
  /// workspace's scrollView + stackView. Kept in lockstep on every
  /// create/close/restore path so `workspaces[i]` ↔ `workspaceVCs[i]`.
  var workspaceVCs: [WorkspaceViewController] = []
  var focusedWorkspaceIndex: Int = 0

  /// Sidebar child VC. Set exactly once in `viewDidLoad` via
  /// `installSidebar()`, then non-nil for the rest of the VC's life.
  /// The implicitly-unwrapped type encodes that invariant so
  /// state-sync call sites don't need `guard let` boilerplate.
  var sidebarVC: SidebarViewController!

  /// Leading constraint of the sidebar view. Captured in
  /// `installSidebar` so the state machine can animate it between
  /// `-sidebarWidth` (hidden, parked off-screen) and `0` (revealed,
  /// flush with the window's leading edge).
  weak var sidebarLeadingConstraint: NSLayoutConstraint?

  /// Edge hover hit zone view. Installed by `installSidebar`; fires
  /// hover-in/out events into the sidebar state machine so the
  /// cursor can reveal a hidden sidebar by approaching the left edge.
  weak var edgeHitZone: EdgeHoverHitZoneView?

  /// Transparent absorber covering the leftmost ``sidebarWidth``
  /// while the sidebar is in unpinned hover-peek. Sits in z-order
  /// between the workspace VCs and the sidebar overlay so the
  /// cursor / hit-test / responder mechanisms find it first and
  /// never descend into the panes that physically extend under the
  /// glass during a peek. See ``SidebarPeekShieldView``. Hidden in
  /// `.hidden` and `.pinnedOpen` (where the workspace's
  /// `scrollView.contentInsets.left` already keeps panes off the
  /// sidebar's footprint).
  weak var peekShield: SidebarPeekShieldView?

  /// Hover-peek's "visual shift cancel" offset currently applied to
  /// every workspace's `clipView.bounds.origin.x`. While the sidebar
  /// is in `.hoverPeek` we inflate `scrollView.contentInsets.left`
  /// (so AppKit treats the leading strip as off-document for cursor
  /// and tracking dispatch) AND advance the scroll origin by the
  /// same amount, so the visible content lands at its pre-peek
  /// position. This property records the currently-applied advance
  /// so `applySidebarLayout` can dispatch the *delta* to each
  /// scroll view rather than recompute absolute offsets.
  ///
  /// `WorkspaceModel.scrollX` is stored in *logical* coordinates —
  /// i.e. the value the user perceives as their scroll position,
  /// independent of the active sidebar state. Save sites subtract
  /// this compensation (`live - compensation = logical`) and restore
  /// sites add it back (`logical + compensation = live`). The
  /// invariant `live bounds.origin.x = ws.scrollX + compensation`
  /// holds for every workspace VC at all times: `applySidebarLayout`
  /// dispatches the delta to *every* VC's live origin so non-current
  /// workspaces stay in sync with the new compensation, and a save
  /// of any one VC always recovers the same logical scrollX.
  var hoverPeekScrollCompensation: CGFloat = 0

  /// `scrollView.contentInsets.left` currently set on every
  /// workspace VC. Tracked centrally so `applySidebarLayout` can
  /// compute the inset delta against the previous *target* value
  /// rather than reading a (possibly mid-animation) live value off
  /// one of the scroll views, and so `installWorkspaceView` can
  /// initialise a freshly-inserted workspace's inset to the same
  /// value as its peers without going through the sidebar VC.
  var currentLeadingInset: CGFloat = 0

  var currentWorkspace: WorkspaceModel {
    precondition(!workspaces.isEmpty, "workspaces invariant violated: must contain at least one element")
    return workspaces[focusedWorkspaceIndex]
  }

  var currentWorkspaceVC: WorkspaceViewController {
    precondition(!workspaceVCs.isEmpty, "workspaceVCs invariant violated: must contain at least one element")
    return workspaceVCs[focusedWorkspaceIndex]
  }

  /// Visible scrollView — always the current workspace's. Non-current
  /// workspaces retain their own scrollViews in detached state so a
  /// switch restores scroll position without reconstruction.
  var scrollView: OverlayScrollView { currentWorkspaceVC.scrollView }
  var stackView: NSStackView { currentWorkspaceVC.stackView }

  public internal(set) var columns: [ColumnModel] {
    get { currentWorkspace.columns }
    set { currentWorkspace.columns = newValue }
  }

  var focusedColumnIndex: Int {
    get { currentWorkspace.focusedColumnIndex }
    set { currentWorkspace.focusedColumnIndex = newValue }
  }

  var focusedPane: PaneModel? {
    columns[safe: focusedColumnIndex]?.focusedPane
  }

  let defaultPaneWidth: CGFloat = 640
  let minPaneWidth: CGFloat = 100
  let minPaneHeight: CGFloat = 50
  let focusBorderWidth: CGFloat = 2
  var focusBorderColor: NSColor {
    Self.accentColor(forWorkspaceAt: focusedWorkspaceIndex)
  }

  /// Bottom-center action-feedback hub. Pills are tinted with the
  /// focused workspace's accent at *post-action* time, so an action
  /// that lands the user on a different workspace (close current,
  /// move pane to N, switch) shows the destination's color — the
  /// place the user's focus actually ends up. Created in
  /// `viewDidLoad`.
  public let toasts = ToastCenter()
  weak var toastOverlay: ToastOverlayView?

  nonisolated(unsafe) var scrollEventMonitor: Any?

  // MARK: - Undo Close

  static let undoTimeout: TimeInterval = 10

  /// Recently closed pane with enough info to restore it to its original position.
  struct ClosedPane {
    let pane: PaneModel
    /// Id of the workspace the pane belonged to. Restore and flush paths
    /// scope themselves by this id so closing one workspace doesn't strand
    /// stash entries belonging to another.
    let workspaceId: ULID
    let columnIndex: Int
    let paneIndex: Int
    let columnWidth: CGFloat?
    /// true if this was the only pane in the column (column was also removed)
    let wasOnlyPaneInColumn: Bool
    let timer: Timer
  }

  nonisolated(unsafe) var recentlyClosed: [ClosedPane] = []

  /// Window-global URL bar toggle. The menu / palette action flips
  /// this for every pane simultaneously; per-pane `.peek` reveals
  /// driven by ⌘L stay independent of this flag and self-collapse
  /// when the URL field gives up first responder.
  var urlBarVisible = false

  /// Monotonic counters that pair each scheduled URL bar hover-in /
  /// hover-out with its eventual fire. Split into separate in / out
  /// counters so cancelling a pending out doesn't accidentally
  /// invalidate an in-flight in (or vice versa) — a single shared
  /// counter previously let `cancelURLBarHoverOut` (called when the
  /// cursor crossed from the hit zone onto the bar's body) bump the
  /// generation, which then made the still-pending hover-in fire
  /// see a generation mismatch and skip opening the peek.
  var urlBarHoverInGeneration: Int = 0
  var urlBarHoverOutGeneration: Int = 0
  /// Separate timers per direction. Only the focused pane's hit
  /// zone is active at any one time, so per-direction is enough —
  /// no need to multiplex by pane.
  var urlBarHoverInTimer: Timer?
  var urlBarHoverOutTimer: Timer?

  var titleDebounceTimer: Timer?
  var lastShownTitle: String = ""
  static let titleDebounceInterval: TimeInterval = 0.1

  public let commandPalette = CommandPaletteView()
  /// Actions from the most recent `searchActions` call, retained so that
  /// the command palette can look up the handler by index on Execute.
  var cachedActionResults: [Action] = []
  /// Snapshot of `actions()` taken when the palette opens. The action
  /// list doesn't change while the palette is visible, so caching at
  /// `show` time avoids re-building the full array (with all its
  /// closure captures) on every keystroke.
  var cachedAllActions: [Action] = []

  // MARK: - Find in Page

  /// Pane the active find session targets. Each `PaneModel` owns its
  /// own `FindBarView`; this reference identifies which pane's bar
  /// the container has bound its callbacks to so ⌘G / ⌘⇧G route the
  /// query to the right pane. Held separately from `focusedPane` so
  /// subsequent focus moves (sidebar click, workspace switch, URL bar
  /// edit) don't silently redirect the session. Weak so a pane
  /// closing while the bar is open doesn't strand the reference.
  weak var findBarTargetPane: PaneModel?

  /// Debounce timer for match-count updates. `onSearch` fires on
  /// every keystroke; `callAsyncJavaScript` is cheap per call but
  /// cumulative cost during fast typing is noticeable, so coalesce
  /// with a short delay before issuing the count script.
  var findCountDebounceTimer: Timer?

  // MARK: - Init

  public init(ghosttyApp: GhosttyApp) {
    self.ghosttyApp = ghosttyApp
    let store = DownloadsStore()
    self.downloadsStore = store
    self.downloadsManager = DownloadsManager(store: store)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  // MARK: - Lifecycle

  public override func loadView() {
    let v = NSView()
    // `NSViewController.transition` drives its slide animation through
    // Core Animation on the container's backing layer. Without a layer
    // the animation becomes a no-op and we'd see exactly the "screen
    // doesn't change" symptom that 2→1 exhibited.
    v.wantsLayer = true
    view = v
  }

  public override func viewDidLoad() {
    super.viewDidLoad()
    installInitialWorkspaceVC()
    installScrollEventMonitor()
    setupCommandPalette()

    var initiallyPinned = false
    if let session = SessionState.load() {
      initiallyPinned = session.sidebarPinned
      restoreSession(session)
    }
    if columns.isEmpty {
      addColumn()
    }
    // Install sidebar last so its view sits on top of every
    // workspace VC. The pinned flag decides whether the sidebar
    // starts flush (push layout, workspace offset by
    // `sidebarWidth`) or parked off-screen (hidden, workspace
    // flush against the leading edge).
    installSidebar(initiallyPinned: initiallyPinned)
    installToastOverlay()
  }

  /// Pin a bottom-center toast overlay above every other subview so
  /// pills sit on top of pane content (and the sidebar's glass) but
  /// pass clicks through to whichever pane is underneath. Auto-sized
  /// to fit its current pill stack.
  private func installToastOverlay() {
    let overlay = ToastOverlayView()
    overlay.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(overlay)
    NSLayoutConstraint.activate([
      overlay.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -32),
    ])
    toastOverlay = overlay
    toasts.attach(overlay: overlay)
  }

  /// Convenience: post a toast in the current workspace's accent.
  /// Routes through `ToastCenter.post` so call sites don't have to
  /// look up the accent themselves.
  public func showToast(_ message: String, style: ToastStyle = .info) {
    toasts.post(message, style: style, accent: focusBorderColor)
  }

  /// Seed the container with a `WorkspaceViewController` for the default
  /// `workspaces[0]` and install its view full-bounds. `restoreSession`
  /// may later replace this VC wholesale if a persisted session exists.
  private func installInitialWorkspaceVC() {
    NSLog("[e05/ws] installInitialWorkspaceVC entry: view.bounds=%@", String(describing: view.bounds))
    let vc = WorkspaceViewController(workspace: workspaces[0])
    addChild(vc)
    workspaceVCs.append(vc)
    installWorkspaceView(vc, makeCurrent: true)
    NSLog(
      "[e05/ws] installInitialWorkspaceVC done: workspaceVCs.count=%d, subviews=%d",
      workspaceVCs.count, view.subviews.count)
  }

  /// Describe each subview of the container's view for debugging. Maps
  /// each subview back to its owning WorkspaceVC (if any) so we can tell
  /// which workspace's view ended up where in the hierarchy.
  func dumpSubviews(_ tag: String) {
    let subs = view.subviews.enumerated().map { (i, sv) -> String in
      if let vc = workspaceVCs.first(where: { $0.isViewLoaded && $0.view === sv }) {
        return "[\(i)]ws=\(vc.workspace.id)"
      }
      return "[\(i)]other=\(type(of: sv))"
    }
    NSLog("[e05/ws] %@ subviews=%@", tag, subs.joined(separator: " "))
  }

  /// Add `vc.view` as a constraint-pinned subview of the container. All
  /// workspaces stay installed simultaneously; the `topConstraint.constant`
  /// determines whether each view is visible (0), below (+height), or
  /// above (-height). Switching animates that constant. This replaces
  /// the `NSViewController.transition` path (which dropped its completion
  /// handler silently after the first call) with a plain layout animation.
  ///
  /// New workspace views are inserted *below* the edge hit zone (and
  /// therefore below the sidebar overlay) when one is present, so a
  /// runtime-created workspace doesn't bury the sidebar under itself —
  /// `addSubview(_:)` would otherwise place the new view at the very top
  /// of the z-order and cover the sidebar. Initial install (during
  /// `viewDidLoad`, before `installSidebar`) falls through to the plain
  /// `addSubview` path.
  func installWorkspaceView(_ vc: WorkspaceViewController, makeCurrent: Bool = false) {
    let wv = vc.view
    wv.translatesAutoresizingMaskIntoConstraints = false
    // Non-current workspaces stay hidden to avoid visual overlap when
    // the initial `view.bounds.height` is still 0 (viewDidLoad runs
    // before the window is sized). `viewDidLayout` will later push
    // their top constants to ±window.height.
    wv.isHidden = !makeCurrent
    if let edgeHitZone {
      view.addSubview(wv, positioned: .below, relativeTo: edgeHitZone)
    } else {
      view.addSubview(wv)
    }

    let initialConstant: CGFloat = makeCurrent ? 0 : max(view.bounds.height, 1)
    let top = wv.topAnchor.constraint(equalTo: view.topAnchor, constant: initialConstant)
    // Root view spans the full window width in every sidebar state —
    // the sidebar overlays it and the columns scrolled under the
    // sidebar give the glass a blur source. The pinned-sidebar
    // offset is applied below as a `scrollView.contentInsets.left`,
    // not as a leading constant on the root view.
    NSLayoutConstraint.activate([
      top,
      wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      wv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      wv.heightAnchor.constraint(equalTo: view.heightAnchor),
    ])
    vc.topConstraint = top
    // `viewDidLoad` runs before `installSidebar`, so the first call
    // here resolves to 0 (`currentLeadingInset` defaults to 0 and
    // `applyInitialState` rewrites it during `installSidebar`).
    // `createWorkspace` / `restoreSession` addenda honour the
    // current pinned inset so a new workspace doesn't open with the
    // leftmost column buried under a pinned sidebar.
    vc.scrollView.contentInsets.left = currentLeadingInset
    // Seed the live scroll origin from the workspace's logical
    // `scrollX` plus the active hover-peek compensation, so the
    // invariant `live bounds.origin.x = ws.scrollX + compensation`
    // holds from the moment the VC enters the hierarchy. Used by
    // both `createWorkspace` (scrollX = 0, compensation possibly
    // non-zero while peeking) and `restoreSession` (scrollX = saved
    // logical, compensation = 0 since peek isn't restored).
    let initialOriginX = vc.workspace.scrollX + hoverPeekScrollCompensation
    if initialOriginX != 0 {
      vc.scrollView.contentView.setBoundsOrigin(NSPoint(x: initialOriginX, y: 0))
    }

    NSLog(
      "[e05/ws] installWorkspaceView wsId=%@ current=%@ topConstant=%f bounds.h=%f hidden=%@",
      String(describing: vc.workspace.id),
      makeCurrent ? "yes" : "no",
      initialConstant,
      view.bounds.height,
      wv.isHidden ? "yes" : "no")
  }

  /// Flag flipped by `animateSlide` so that `viewDidLayout` doesn't stomp
  /// on mid-animation top-constraint values while the window resizes or
  /// another layout pass is triggered.
  var isAnimatingWorkspaceSwitch = false

  /// Factory: construct a `PaneModel` with the terminal dependency the
  /// container owns. Kept as a method so future per-pane dependencies
  /// land in one place. The browser data store comes from the
  /// **target** workspace (not the focused one) so panes built for a
  /// new workspace honour its private flag even before the container
  /// switches over to it.
  func makePane(address: PaneAddress, in workspace: WorkspaceModel? = nil) -> PaneModel {
    let ws = workspace ?? currentWorkspace
    return PaneModel(address: address, ghosttyApp: ghosttyApp, dataStore: ws.dataStore)
  }

  private var hasAppearedOnce = false

  /// Focus target captured during `restoreSession`, re-applied once the
  /// window becomes key. The viewDidLoad-time `restoreFocus` loses its
  /// `makeFirstResponder` call to AppKit's default initial-responder
  /// search (which lands on the leftmost pane), and that fallback's
  /// `onFocusChanged` callback rewrites `ws.focusedColumnIndex` to 0.
  /// Snapshotting the intended target lets us re-apply from the clean
  /// value, not whatever ended up in memory after the clobber.
  ///
  /// Doubles as a cold-restore latch: while non-nil, `handleFocusChange`
  /// drops AppKit-driven focus changes so the `_setUpFirstResponder`
  /// cascade can't schedule a `scrollToColumn(at: 0)` that would clobber
  /// the saved scrollX. Cleared in `viewDidAppear` immediately before
  /// re-applying the snapshotted focus.
  var pendingInitialFocus: (workspaceIndex: Int, columnIndex: Int, paneIndex: Int)?

  public override func viewDidAppear() {
    super.viewDidAppear()
    DispatchQueue.main.async { [weak self] in
      self?.scrollView.scrollerStyle = .overlay
    }
    // Re-sync traffic lights against the sidebar state now that the
    // window is attached. In `installSidebar` the window may still
    // be nil (the contentViewController assignment hadn't wired
    // the view into the window hierarchy yet), in which case
    // `applyTrafficLights` early-returned. Running the seeding
    // again here picks up the final state for `.hidden` starts.
    if let sidebarVC {
      applySidebarLayout(state: sidebarVC.currentState, animated: false, completion: nil)
    }
    if !hasAppearedOnce {
      hasAppearedOnce = true
      if let target = pendingInitialFocus {
        pendingInitialFocus = nil
        NSLog(
          "[e05/ws] viewDidAppear re-applying focus → ws=%d col=%d pane=%d",
          target.workspaceIndex, target.columnIndex, target.paneIndex)
        // Wipe every border in the current workspace first. Between
        // restoreFocus and viewDidAppear, AppKit's key-window init
        // can hand first responder to the leftmost terminal pane,
        // whose `onFocusChanged` callback applies a border on *that*
        // pane. If we only setFocus target, the terminal keeps its
        // stray border — hence "両方のペインに枠線" / [f][] symptom.
        if workspaces.indices.contains(target.workspaceIndex) {
          let ws = workspaces[target.workspaceIndex]
          clearAllFocusBorders(in: ws)
          if ws.columns.indices.contains(target.columnIndex) {
            ws.focusedColumnIndex = target.columnIndex
            ws.columns[target.columnIndex].focusedPaneIndex = target.paneIndex
          }
        }
        if focusedWorkspaceIndex == target.workspaceIndex {
          setFocus(columnIndex: target.columnIndex, paneIndex: target.paneIndex, scroll: false)
        }
        // Re-apply scrollX now that the stackView actually has a
        // content size. The viewDidLoad-time `restoreScroll` call
        // ran when stackView.width was 0, so NSClipView clamped the
        // requested offset to 0. Re-applying here with the saved
        // `workspace.scrollX` puts the viewport where it was saved.
        restoreScroll(in: currentWorkspace)
        NSLog("[e05/ws] viewDidAppear restoreScroll x=%f", currentWorkspace.scrollX)

        // The saved `scrollX` lives in document-view coordinates and
        // doesn't know about the current `contentInsets.left` — a
        // session that was saved with the sidebar unpinned and is
        // now restored with it pinned (or vice versa) puts the
        // focused column behind the sidebar. Snap to a centred
        // origin (via `computeScrollTargetX`, which honours the
        // inset) when the focused column ended up outside the
        // user-visible region. `documentVisibleRect` reports the
        // full clip-view rect including the sidebar inset, so
        // shrink it to the post-inset visible band before testing
        // — otherwise a column hidden under the sidebar still
        // tests as `contains == true` and the snap is skipped.
        // Direct `setBoundsOrigin` matches the immediate-snap idiom
        // the rest of `restoreScroll` uses instead of triggering
        // an entrance tween.
        let insets = scrollView.contentInsets
        var trueVisible = scrollView.documentVisibleRect
        trueVisible.origin.x += insets.left
        trueVisible.size.width -= insets.left + insets.right
        if let focused = columns[safe: focusedColumnIndex],
          !trueVisible.contains(focused.containerView.frame),
          let targetX = computeScrollTargetX(for: focused)
        {
          scrollView.contentView.setBoundsOrigin(NSPoint(x: targetX, y: 0))
        }
      }
    }
  }

  private var isUpdatingLayout = false

  public override func viewDidLayout() {
    super.viewDidLayout()
    guard !isUpdatingLayout else { return }
    isUpdatingLayout = true
    // Refresh every workspace's column widths, not just the current
    // one. Sidebar reveal/hide shifts every workspace VC's leading,
    // so a non-current workspace with a `.fraction` preset would
    // otherwise keep its width frozen at the old visibleWidth (e.g.
    // pinned-sidebar value) until the next time it becomes current
    // AND the layout engine happens to re-run. That manifested as a
    // broken aspect ratio when ⌘B + Ctrl+Tab were mashed: the
    // workspace that was mid-switch got its column stranded at the
    // narrower, pinned-width value.
    for vc in workspaceVCs where vc.isViewLoaded {
      // `.fraction` is anchored to the user-visible portion of the
      // scroll view, not its raw clip width — pinning the sidebar
      // inflates `contentInsets.left` and the visible region shrinks
      // by that much, so a `.fraction(1.0)` column has to shrink to
      // match or it overflows past the sidebar inset.
      let visibleWidth = effectiveVisibleWidth(in: vc.scrollView)
      for column in vc.workspace.columns {
        // Folded columns keep their fixed strip width regardless
        // of window size — the saved unfoldedWidth is what the
        // fraction preset will restore to.
        if column.isFolded { continue }
        if case .fraction(let f) = column.currentPreset, visibleWidth > 0 {
          column.widthConstraint?.constant = visibleWidth * f
        }
        for pane in column.panes {
          pane.containerView.setFrameSize(pane.containerView.frame.size)
        }
      }
    }

    // Park non-current workspace views at ±window.height so they stay
    // fully offscreen even after window resize. The sign stays stable
    // (above vs below) unless the workspace is the current one. Skipped
    // mid-animation to avoid snapping interpolated constants.
    // The `!=` guards keep this pass idempotent — rewriting the same
    // constant would dirty the constraint engine and risk scheduling
    // another layout loop.
    if !isAnimatingWorkspaceSwitch {
      let h = view.bounds.height
      for (i, vc) in workspaceVCs.enumerated() {
        guard let top = vc.topConstraint else { continue }
        let desired: CGFloat =
          i == focusedWorkspaceIndex
          ? 0
          : (top.constant < 0 ? -h : h)
        if top.constant != desired {
          top.constant = desired
        }
      }
    }
    isUpdatingLayout = false
  }

  deinit {
    if let monitor = scrollEventMonitor {
      NSEvent.removeMonitor(monitor)
    }
    for closed in recentlyClosed {
      closed.timer.invalidate()
    }
  }

  // MARK: - Scroll Event Monitor

  /// Intercept horizontal scroll events before GhosttyTerminalView consumes them.
  private func installScrollEventMonitor() {
    scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
      [weak self] event in
      guard let self else { return event }

      let locationInView = self.scrollView.convert(event.locationInWindow, from: nil)
      guard self.scrollView.bounds.contains(locationInView) else { return event }

      if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
        self.scrollView.scrollWheel(with: event)
        return nil
      }

      return event
    }
  }

}
