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
  /// The implicitly-unwrapped type encodes that invariant so stage 2+
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

  nonisolated(unsafe) var scrollEventMonitor: Any?
  nonisolated(unsafe) var workspaceKeyMonitor: Any?

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

  var urlBarVisible = false

  var titleDebounceTimer: Timer?
  var lastShownTitle: String = ""
  static let titleDebounceInterval: TimeInterval = 0.1

  let commandPalette = CommandPaletteView()
  /// Actions from the most recent `searchActions` call, retained so that
  /// the command palette can look up the handler by index on Execute.
  var cachedActionResults: [Action] = []
  /// Snapshot of `actions()` taken when the palette opens. The action
  /// list doesn't change while the palette is visible, so caching at
  /// `show` time avoids re-building the full array (with all its
  /// closure captures) on every keystroke.
  var cachedAllActions: [Action] = []

  // MARK: - Find in Page

  /// Find-in-page overlay. Constructed lazily on first open and reused
  /// afterwards so typed text and caret state survive close/reopen.
  /// Placement logic lives in `+FindBar`.
  var findBar: FindBarView?

  /// Pane the active find session targets. Held separately from
  /// `focusedPane` so subsequent focus moves (click into the sidebar,
  /// workspace switch, URL bar edit) can't silently redirect the
  /// session to a different pane. Weak so a pane closing while the
  /// bar is open doesn't strand the reference.
  weak var findBarTargetPane: PaneModel?

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
    installWorkspaceKeyMonitor()
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
  func installWorkspaceView(_ vc: WorkspaceViewController, makeCurrent: Bool = false) {
    let wv = vc.view
    wv.translatesAutoresizingMaskIntoConstraints = false
    // Non-current workspaces stay hidden to avoid visual overlap when
    // the initial `view.bounds.height` is still 0 (viewDidLoad runs
    // before the window is sized). `viewDidLayout` will later push
    // their top constants to ±window.height.
    wv.isHidden = !makeCurrent
    view.addSubview(wv)

    let initialConstant: CGFloat = makeCurrent ? 0 : max(view.bounds.height, 1)
    let top = wv.topAnchor.constraint(equalTo: view.topAnchor, constant: initialConstant)
    // Leading starts flush with the sidebar state's push value.
    // `viewDidLoad` runs before `installSidebar`, so the first
    // call resolves to 0 (sidebarVC nil). After `installSidebar`,
    // `createWorkspace` / `restoreSession` addenda need to honour
    // the current push so a new workspace doesn't slip under a
    // pinned sidebar.
    let push = sidebarVC?.currentState.pushesContent == true ? Self.sidebarWidth : 0
    let leading = wv.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: push)
    NSLayoutConstraint.activate([
      top,
      leading,
      wv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      wv.heightAnchor.constraint(equalTo: view.heightAnchor),
    ])
    vc.topConstraint = top
    vc.leadingConstraint = leading

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
  /// land in one place.
  func makePane(address: PaneAddress) -> PaneModel {
    PaneModel(address: address, ghosttyApp: ghosttyApp)
  }

  private var hasAppearedOnce = false

  /// Focus target captured during `restoreSession`, re-applied once the
  /// window becomes key. The viewDidLoad-time `restoreFocus` loses its
  /// `makeFirstResponder` call to AppKit's default initial-responder
  /// search (which lands on the leftmost pane), and that fallback's
  /// `onFocusChanged` callback rewrites `ws.focusedColumnIndex` to 0.
  /// Snapshotting the intended target lets us re-apply from the clean
  /// value, not whatever ended up in memory after the clobber.
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
      let visibleWidth = vc.scrollView.contentView.bounds.width
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
    if let monitor = workspaceKeyMonitor {
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

  /// Intercept Ctrl+Tab / Ctrl+Shift+Tab at the app level. WKWebView's
  /// `performKeyEquivalent` swallows Ctrl+Tab before it reaches the menu
  /// system, so a menu-item key equivalent alone wouldn't fire when a
  /// browser pane has focus. A local event monitor runs ahead of the
  /// responder chain and catches the combo regardless of focus.
  private func installWorkspaceKeyMonitor() {
    let tabKeyCode: UInt16 = 48
    let relevantMask: NSEvent.ModifierFlags = [.control, .command, .option, .shift]
    workspaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard let self, event.keyCode == tabKeyCode else { return event }

      // Don't hijack Ctrl+Tab while text input owns first responder
      // (command palette field, URL bar, etc.). NSTextField delegates
      // key handling to an NSTextView field editor, which inherits
      // from NSText — catching `NSText` covers both.
      if let responder = self.view.window?.firstResponder,
        responder is NSText
      {
        return event
      }
      // Also bail while the command palette is showing, even if its
      // field editor hasn't taken first responder yet — switching
      // workspace while the palette is open leaves the palette
      // stranded over a different workspace's content.
      if self.commandPalette.isVisible {
        return event
      }

      let flags = event.modifierFlags.intersection(relevantMask)
      if flags == .control {
        self.switchWorkspaceNext()
        return nil
      }
      if flags == [.control, .shift] {
        self.switchWorkspacePrevious()
        return nil
      }
      return event
    }
  }
}
