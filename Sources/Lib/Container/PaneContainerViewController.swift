import AppKit
import GhosttyKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "Container")

public final class PaneContainerViewController: NSViewController {
  let ghosttyApp: GhosttyApp
  public let browsingHistory = BrowsingHistory.shared
  public let bookmarks = Bookmarks.shared
  public let downloadsStore = DownloadsStore.shared
  public let downloadsManager: DownloadsManager

  public internal(set) var workspaces: [WorkspaceModel] = [WorkspaceModel()]
  /// Parallel to `workspaces`: the child view controller hosting each
  /// workspace's scrollView + stackView. Kept in lockstep on every
  /// create/close/restore path so `workspaces[i]` ↔ `workspaceVCs[i]`.
  var workspaceVCs: [WorkspaceViewController] = []
  var focusedWorkspaceIndex: Int = 0

  /// Pending debounced session autosave. Every layout / focus
  /// mutation (via `notifySidebarWorklaneDidChange`) and browser
  /// navigation (`onURLChange`) reschedules this, collapsing a burst
  /// of changes into one write once activity settles. It is the only
  /// save path that survives a crash / force-quit; the other,
  /// `applicationWillTerminate`, runs only on a clean quit.
  var sessionAutosaveWorkItem: DispatchWorkItem?

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
    precondition(
      !workspaces.isEmpty, "workspaces invariant violated: must contain at least one element")
    return workspaces[focusedWorkspaceIndex]
  }

  var currentWorkspaceVC: WorkspaceViewController {
    precondition(
      !workspaceVCs.isEmpty, "workspaceVCs invariant violated: must contain at least one element")
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
  /// Floor for browser and terminal column widths. Matches the floor
  /// the two major browsers hard-code for their own windows so a single
  /// pane stays as usable as a freshly-resized browser window: Brave
  /// pins `NSWindow.contentMinSize` to 500pt via Chromium's
  /// `kMainBrowserContentsMinimumWidth`; Zen (Firefox base) pins
  /// `NSWindow.minSize` to 450pt via the root `min-width` rule. We sit
  /// on the lower bound because a window manager that tiles panes
  /// rewards packing density. Folded columns (30pt strip) bypass this
  /// floor by deactivating the column's `minimumWidthConstraint`;
  /// cycle-width presets below the floor are clamped — the Settings
  /// row pre-clamps `.points` entries on commit (so the user sees the
  /// floor reflected in the field), and Auto Layout still floors
  /// `.fraction` entries that resolve under the floor at apply time.
  /// `static` so the Settings UI can read the floor without a VC
  /// reference.
  static let minPaneWidth: CGFloat = 450
  /// Slack allowed when asking whether a web view's pinch magnification
  /// is still at its 1.0 baseline. A gesture rarely settles on exactly
  /// 1, so an equality test would read a page as magnified at 1.0000003.
  /// Matches the tolerance the worklane's zoom-reset gate uses for the
  /// same question.
  static let magnificationTolerance: CGFloat = 0.001
  let minPaneHeight: CGFloat = 50
  var focusBorderWidth: CGFloat { AppMetrics.focusedPaneBorderWidth }
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
  nonisolated(unsafe) var keyEventMonitor: Any?

  nonisolated(unsafe) var mouseMovedMonitor: Any?

  /// Pending settle for the workspace scroll (see `scheduleScrollSettle`).
  var scrollSettleWorkItem: DispatchWorkItem?

  /// Pending hover-focus check (see `scheduleHoverFocus`).
  var hoverFocusWorkItem: DispatchWorkItem?

  /// How long the pointer and the workspace both have to hold still
  /// before the pane under the pointer takes focus. Long enough that a
  /// pointer travelling across the window does not focus everything on
  /// its way past, short enough to feel like a consequence of stopping.
  static let hoverFocusDelay: TimeInterval = 0.3

  /// How long the scroll origin has to hold still before the settle
  /// runs. Short enough that the seat still reads as part of the gesture
  /// that asked for it; long enough that a hand resting on the trackpad
  /// between two pushes is not read as a stop.
  static let scrollSettleDelay: TimeInterval = 0.2

  /// Trackpad gestures get a single routing decision (pane vs. workspace)
  /// at their `.began` event, applied to every subsequent `.changed` /
  /// `.ended` / momentum event in the same gesture so the routing
  /// can't flip mid-stream when the page's `horizontalScrollEdge`
  /// shifts under the user's finger. The lock survives between
  /// gestures with no harm — the next `.began` overwrites it
  /// outright. Mouse-wheel events (no phase) bypass the lock and
  /// decide per event.
  private enum ScrollGestureLock {
    case pane
    case workspace
  }
  private var scrollGestureLock: ScrollGestureLock?

  /// Single 1 Hz tick that drives `BrowserPaneView.updateAudioStateOnce`
  /// across every pane, replacing the per-pane Task that earlier drafts
  /// kept. One main-actor wakeup per second covers all panes; probes
  /// run sequentially so each pane's `await` suspends the main actor
  /// long enough for other UI work to interleave between IPC
  /// round-trips. See the implementation for the rationale on why a
  /// `TaskGroup` isn't used.
  private var mediaTickTask: Task<Void, Never>?

  /// Dispatch source subscribed to system memory-pressure events.
  /// Fires on `.warning` / `.critical` transitions so the suspend
  /// sweep can run immediately under heap pressure instead of
  /// waiting for the next idle-threshold tick.
  /// Lives for the lifetime of the container; cancelled in the
  /// teardown path alongside `mediaTickTask`.
  private var memoryPressureSource: DispatchSourceMemoryPressure?

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

  /// Throttles the worklane rebuild on a title storm: left to fire
  /// (not reset) so a churning pane can't starve another pane's update.
  var worklaneTitleTimer: Timer?
  /// Debounces the focused pane's header overlay: reset on every
  /// focused-pane title change so the overlay only appears once the
  /// title settles, filtering out rapid shell-prompt / progress-bar
  /// churn. Keyed to the focused pane only, so an unfocused pane's
  /// storm doesn't reset it.
  var headerTitleTimer: Timer?
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
  /// Snapshot pushed in from `AppDelegate.setupMenuKeyBindings` so the
  /// menu-item tag stamped at build time indexes against the same array
  /// the dispatch path reads from. AppDelegate keeps a transient local
  /// copy while building the menu; this property is the canonical
  /// store the validator and dispatcher consult.
  ///
  /// Single-window assumption: the array is built once per menu
  /// rebuild from the sole `PaneContainerViewController`. If
  /// multi-window support lands, the snapshot becomes per-window
  /// (or re-fetched on focus change) because the handler closures
  /// capture `[weak self]`. The tag-based index also assumes a
  /// static action order — dynamic action lists would require
  /// id-based lookup instead.
  public var menuActionsSnapshot: [Action] = []

  /// Set when closing the last pane/column cascades into quitting the
  /// app: that gesture already confirmed killing its process at the pane
  /// level, so `applicationShouldTerminate` consumes this to skip a
  /// redundant second "Quit e05?" prompt. One-shot — cleared as it's read.
  public var suppressQuitConfirmation = false

  // MARK: - Find in Page
  //
  // Each `PaneModel` owns its own `FindBarView`. `focusedPane`
  // identifies which bar receives ⌘F / ⌘G / ⌘⇧G; the per-pane
  // debounce timer lives on `PaneModel.findCountDebounceTimer` so
  // typing into one pane's bar can't invalidate a pending match-count
  // update for another pane's bar.

  // MARK: - Init

  public init(ghosttyApp: GhosttyApp) {
    self.ghosttyApp = ghosttyApp
    self.downloadsManager = DownloadsManager.shared
    super.init(nibName: nil, bundle: nil)
    // Hand the manager a lazy way to find the host window. The
    // container is installed long before AppKit attaches a window
    // to its root view, so resolution has to defer to call time.
    downloadsManager.windowProvider = { [weak self] in self?.view.window }
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
    installKeyEventMonitor()
    installMouseMovedMonitor()
    setupCommandPalette()

    var initiallyPinned = false
    var initiallyCollapsedIds: [String] = []
    let restored = SessionState.load()
    // Before the restore hands any path out, and only against a session
    // that actually loaded — see ``ScrollbackStore/pruneOrphans(against:)``
    // for why nil deletes nothing.
    ScrollbackStore.default.pruneOrphans(against: restored)
    if let session = restored {
      initiallyPinned = session.sidebarPinned
      initiallyCollapsedIds = session.collapsedIds ?? []
      restoreSession(session)
    }
    if columns.isEmpty {
      // Cold-start fallback when the session restored no columns. A
      // fresh terminal, so honor the new-terminal cwd preference.
      addColumn(dependencies: newTerminalPaneDependencies)
    }
    // Install sidebar last so its view sits on top of every
    // workspace VC. The pinned flag decides whether the sidebar
    // starts flush (push layout, workspace offset by
    // `sidebarWidth`) or parked off-screen (hidden, workspace
    // flush against the leading edge). Collapsed ULIDs are filtered
    // against live workspace / column ids inside `installSidebar`
    // since the live IDs aren't known until that point.
    installSidebar(
      initiallyPinned: initiallyPinned,
      initiallyCollapsedIds: initiallyCollapsedIds)
    installToastOverlay()
    startMediaAudibleTick()
    startMemoryPressureMonitor()
  }

  /// Fallback idle threshold (in minutes) past which a non-focused
  /// browser pane gets suspended by the 1 Hz tick. Half of Chrome /
  /// Edge's 2 h default and more aggressive than Safari / Firefox's
  /// pressure-only stance — long enough that flipping between panes
  /// mid-research doesn't reload the one you just glanced at, short
  /// enough that a pane left from this morning is reclaimed by the
  /// afternoon. Used when ``E05Preferences/suspendIdleMinutes`` is
  /// `nil`; the 1 Hz tick reads the override on every pass so
  /// changes from the Settings tab take effect without a restart.
  private static let defaultSuspendIdleMinutes: Int = 60

  /// Kick off the shared 1 Hz audio-state probe loop. Each tick walks
  /// every browser pane in the container and asks it to refresh its
  /// `isPlayingAudio` flag through `BrowserPaneView.updateAudioStateOnce`;
  /// state changes fan out through `onAudioStateChanged`, which the
  /// URL bar and sidebar already subscribe to. Probes run sequentially
  /// — each pane's `await` suspends the main actor, so other UI work
  /// can interleave between IPC round-trips, and we avoid the Swift 6
  /// region-based isolation friction a `TaskGroup` would introduce.
  ///
  /// Once every pane has a fresh `isPlayingAudio` reading the tick
  /// runs `suspendSweep(trigger: .idle)` so the same walk also
  /// drives the idle suspend sweep. Piggy-backing keeps the runloop
  /// wake-up count at "one timer total" rather than adding a
  /// dedicated suspend timer.
  private func startMediaAudibleTick() {
    mediaTickTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        if Task.isCancelled { return }
        guard let self else { return }
        for ws in self.workspaces {
          for col in ws.columns {
            for pane in col.panes {
              if Task.isCancelled { return }
              if let bv = pane.browserView {
                await bv.updateAudioStateOnce()
              }
            }
          }
        }
        self.suspendSweep(trigger: .idle)
      }
    }
  }

  /// Subscribe to the system memory-pressure dispatch source so the
  /// suspend sweep can react to actual heap pressure rather than
  /// waiting for the next idle-threshold tick. A `.warning` event
  /// runs the sweep with a short idle floor in place of the configured
  /// threshold — parked panes are reclaimed, but one the user touched
  /// in the last few minutes survives, because `.warning` fires
  /// readily and yanking a mid-use pane is more disruptive than the
  /// memory it frees. A `.critical` event drops the floor entirely:
  /// every eligible non-focused pane goes. The focused pane stays
  /// alive regardless of
  /// pressure level — taking down the page the user is currently
  /// looking at would be more disruptive than the memory cost of
  /// keeping it, and pressure events generally fire *ahead of* an
  /// OOM rather than in lieu of one.
  ///
  /// The dispatch source is queued onto `.main` so the handler
  /// already runs on the main thread, but Swift 6's `@MainActor`
  /// isolation contract is a separate language-level concept from
  /// "running on `DispatchQueue.main`". The handler reconciles the
  /// two with `MainActor.assumeIsolated`, which asserts the thread
  /// match (cheap in release, traps in debug if violated) and lets
  /// us call `@MainActor` state synchronously without spawning a
  /// `Task` per event.
  private func startMemoryPressureMonitor() {
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical], queue: .main)
    source.setEventHandler { [weak self, weak source] in
      let level = source?.data ?? []
      MainActor.assumeIsolated {
        self?.handleMemoryPressure(level: level)
      }
    }
    source.resume()
    memoryPressureSource = source
  }

  private func handleMemoryPressure(level: DispatchSource.MemoryPressureEvent) {
    // Bit-wise build so the rare "critical+warning accumulated since
    // the last fire" case renders both labels rather than collapsing
    // to whichever single name a priority chain happens to pick.
    var parts: [String] = []
    if level.contains(.critical) { parts.append("critical") }
    if level.contains(.warning) { parts.append("warning") }
    let name = parts.isEmpty ? "normal" : parts.joined(separator: "+")
    logger.warning(
      "[browser/memory-pressure] system pressure level=\(name, privacy: .public), running suspend sweep"
    )
    suspendSweep(trigger: level.contains(.critical) ? .memoryCritical : .memoryWarning)
  }

  /// What kicked off a sweep, and how aggressively it reclaims:
  /// - `.idle`: the 1 Hz tick. Honours the configured idle threshold,
  ///   and is the only trigger the user can switch off.
  /// - `.memoryWarning`: a system `.warning` pressure event. Ignores
  ///   the configured threshold but keeps a short idle floor, so a
  ///   pane the user touched in the last few minutes survives a
  ///   warning that fires while they are still flipping through panes.
  /// - `.memoryCritical`: a system `.critical` pressure event. Drops
  ///   the floor entirely — every eligible non-focused pane goes,
  ///   because the alternative at that level is the OS killing us.
  enum SuspendTrigger {
    case idle
    case memoryWarning
    case memoryCritical

    /// Stable label for the suspend log. Spelled out rather than
    /// derived from the case name so renaming a case can't silently
    /// break a log grep.
    var logLabel: String {
      switch self {
      case .idle: return "idle"
      case .memoryWarning: return "memory-warning"
      case .memoryCritical: return "memory-critical"
      }
    }
  }

  /// Outcome of resolving a sweep's idle gate for a trigger.
  enum SweepCutoff: Equatable {
    /// The idle sweep is disabled (`suspendIdleMinutes <= 0`) and this
    /// trigger honours that — skip the whole sweep.
    case disabled
    /// No age gate: every otherwise-eligible pane may be reclaimed
    /// (a `.memoryCritical` event).
    case all
    /// Reclaim panes whose `lastActiveAt` is at or before this instant.
    case idleSince(Date)
  }

  /// What the sweep should do with one pane.
  enum SweepDecision: Equatable {
    /// Leave the pane as-is (unsuspendable, exempt, playing media,
    /// loopback, host-exempt, or still within the idle window).
    case keep
    /// Pane holds focus: pin its idle clock to `now` and keep it, so
    /// the countdown starts when it loses focus, not when it opened.
    case refreshFocusClock
    /// Reclaim the pane's `WKWebView`.
    case suspend
  }

  /// Idle floor applied under a `.memoryWarning` sweep. Panes active
  /// within this window survive a warning (a later `.critical`
  /// reclaims them anyway). Short enough to relieve pressure by
  /// reclaiming genuinely-parked panes, long enough that the pane you
  /// glanced at a minute ago is still there.
  private nonisolated static let memoryWarningGraceSeconds: TimeInterval = 5 * 60

  /// Walk every browser pane and suspend any that isn't currently
  /// focused, isn't playing media, isn't a loopback dev server, and
  /// has been idle past the cutoff the `trigger` resolves to. Shared
  /// by the 1 Hz idle tick and the memory-pressure handler so every
  /// path applies the same focused / media / exempt / loopback guard
  /// set — the trigger only changes the idle cutoff.
  ///
  /// Runs entirely synchronously with no `await`. The
  /// `memoryPressureSource` handler relies on that — `setEventHandler`
  /// serialises events on the main queue but doesn't serialise
  /// against `Task`-spawned continuations, so if this method ever
  /// grows an `await` the handler will need a re-entrancy guard
  /// (an `isSweeping` flag, or moving sweeps onto a single serial
  /// async queue).
  private func suspendSweep(trigger: SuspendTrigger) {
    // Read the idle preference once per sweep so a Settings change
    // lands on the next pass without a restart.
    let idleMinutes =
      PreferencesStore.shared.preferences.suspendIdleMinutes
      ?? Self.defaultSuspendIdleMinutes
    let now = Date()
    let cutoff = Self.sweepCutoff(trigger: trigger, idleMinutes: idleMinutes, now: now)
    if cutoff == .disabled { return }
    // Protect the focused pane in *every* workspace, not just the
    // current one: a user reading a long article on a non-current
    // workspace doesn't move focus or change URL, so its
    // `lastActiveAt` clock keeps drifting past the cutoff. Without
    // this set, switching back to that workspace an hour later
    // would find the article gone and the placeholder up.
    let focusedPaneIds = Set(
      workspaces.compactMap { ws -> ULID? in
        ws.columns[safe: ws.focusedColumnIndex]?.focusedPane?.id
      })
    for ws in workspaces {
      for col in ws.columns {
        for pane in col.panes {
          guard let bv = pane.browserView else { continue }
          let host = bv.currentHost
          let decision = Self.sweepDecision(
            canSuspend: bv.canSuspend,
            isFocused: focusedPaneIds.contains(pane.id),
            isSuspendExempt: pane.isSuspendExempt,
            isPlayingMedia: bv.hasActiveMedia || bv.isPlayingAudio,
            hasOpenPopups: bv.hasOpenPopups,
            host: host,
            isHostExempt: host.map { SuspendHostExemptStore.shared.isExempt(host: $0) } ?? false,
            lastActiveAt: pane.lastActiveAt,
            cutoff: cutoff)
          switch decision {
          case .keep:
            continue
          case .refreshFocusClock:
            // Heartbeat the focused pane so its idle countdown starts
            // at the moment it loses focus (see `sweepDecision`).
            pane.lastActiveAt = now
          case .suspend:
            // Suspends are infrequent; log the trigger and idle age so
            // "why did this pane reload?" stays traceable.
            let idleSec = Int(now.timeIntervalSince(pane.lastActiveAt))
            logger.info(
              "[browser/suspend] reclaiming host=\(host ?? "?", privacy: .public) trigger=\(trigger.logLabel, privacy: .public) idleSec=\(idleSec, privacy: .public)"
            )
            bv.suspend()
          }
        }
      }
    }
  }

  /// Resolve the idle gate for `trigger`. Pure so the gating maths
  /// (warning floor, disabled idle sweep, critical bypass) can be
  /// exercised without a live container; `now` is injected for the
  /// same reason. Non-positive `idleMinutes` disables the idle sweep
  /// but not the memory-pressure triggers, which come from the OS.
  nonisolated static func sweepCutoff(
    trigger: SuspendTrigger, idleMinutes: Int, now: Date
  ) -> SweepCutoff {
    switch trigger {
    case .idle:
      if idleMinutes <= 0 { return .disabled }
      return .idleSince(now.addingTimeInterval(-TimeInterval(idleMinutes * 60)))
    case .memoryWarning:
      // Keep a short floor, but never be *less* aggressive than the
      // idle sweep: a tight idle threshold (say 1 min) is honoured
      // here too; a disabled idle sweep falls back to the grace floor.
      let floor =
        idleMinutes > 0
        ? min(TimeInterval(idleMinutes * 60), memoryWarningGraceSeconds)
        : memoryWarningGraceSeconds
      return .idleSince(now.addingTimeInterval(-floor))
    case .memoryCritical:
      return .all
    }
  }

  /// Decide one pane's fate. Pure: every guard input is passed in so
  /// the ladder — and its order — can be tested without a live
  /// `BrowserPaneView`. `isHostExempt` is resolved by the caller from
  /// the host-keyed store; loopback is checked here. `canSuspend`
  /// mirrors the guards inside `BrowserPaneView.suspend()`.
  nonisolated static func sweepDecision(
    canSuspend: Bool,
    isFocused: Bool,
    isSuspendExempt: Bool,
    isPlayingMedia: Bool,
    hasOpenPopups: Bool,
    host: String?,
    isHostExempt: Bool,
    lastActiveAt: Date,
    cutoff: SweepCutoff
  ) -> SweepDecision {
    if cutoff == .disabled { return .keep }
    guard canSuspend else { return .keep }
    // Focus wins over every reclaim reason, and refreshes the clock.
    if isFocused { return .refreshFocusClock }
    if isSuspendExempt { return .keep }
    // Media playback keeps a pane alive regardless of focus or memory
    // pressure — suspending mid-video / mid-track is the most jarring
    // reclaim a user can hit. The caller folds muted-but-playing video
    // (`hasActiveMedia`) and audible playback (`isPlayingAudio`) into
    // this one flag.
    if isPlayingMedia { return .keep }
    // A window the page opened is where the user is, and the pane it
    // belongs to has lost focus precisely because of it — a sign-in
    // being typed into a popup reads as an idle pane. Suspending would
    // drop the web view the popup is talking to and take the popup
    // with it, mid-password.
    if hasOpenPopups { return .keep }
    if let host {
      if isHostExempt { return .keep }
      // Loopback dev servers (localhost:3000, 127.0.0.1, …) are spared
      // by default: a suspended local app loses its in-memory session
      // and a reload often can't reproduce the state.
      if isLoopbackHost(host) { return .keep }
    }
    if case .idleSince(let instant) = cutoff, lastActiveAt > instant {
      return .keep
    }
    return .suspend
  }

  /// Loopback hosts the suspend sweep always spares. Loopback only —
  /// LAN / RFC1918 ranges stay in scope so a router admin page or a
  /// colleague's dev box on the LAN suspends like any other site.
  nonisolated static func isLoopbackHost(_ host: String) -> Bool {
    let lower = host.lowercased()
    if lower == "localhost" || lower.hasSuffix(".localhost") { return true }
    if lower == "::1" || lower == "[::1]" { return true }
    // 127.0.0.0/8, but only for genuine IPv4 literals so a registrable
    // name like "127.example.com" isn't mistaken for loopback.
    if lower.hasPrefix("127."), isIPv4Literal(lower) { return true }
    return false
  }

  /// Whether `s` is a dotted-decimal IPv4 literal (four 0–255 octets).
  /// Keeps ``isLoopbackHost`` from treating a hostname that merely
  /// starts with `127.` as a loopback address.
  nonisolated static func isIPv4Literal(_ s: String) -> Bool {
    let octets = s.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4 else { return false }
    return octets.allSatisfy { octet in
      !octet.isEmpty && octet.count <= 3
        && octet.allSatisfy { $0.isASCII && $0.isNumber }
        && (Int(octet).map { (0...255).contains($0) } ?? false)
    }
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
    logger.debug(
      "installInitialWorkspaceVC entry: view.bounds=\(String(describing: self.view.bounds), privacy: .public)"
    )
    let vc = WorkspaceViewController(workspace: workspaces[0])
    addChild(vc)
    workspaceVCs.append(vc)
    installWorkspaceView(vc, makeCurrent: true)
    logger.debug(
      "installInitialWorkspaceVC done: workspaceVCs.count=\(self.workspaceVCs.count), subviews=\(self.view.subviews.count)"
    )
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
    logger.debug(
      "\(tag, privacy: .public) subviews=\(subs.joined(separator: " "), privacy: .public)")
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
    // leftmost column buried under a pinned sidebar. Composed with any
    // pinned-column reserve so a session-restored pin isn't dropped
    // when its view is seated.
    vc.scrollView.contentInsets.left = totalLeadingInset(in: vc)
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

    logger.debug(
      "installWorkspaceView wsId=\(String(describing: vc.workspace.id), privacy: .public) current=\(makeCurrent ? "yes" : "no", privacy: .public) topConstant=\(initialConstant) bounds.h=\(self.view.bounds.height) hidden=\(wv.isHidden ? "yes" : "no", privacy: .public)"
    )
  }

  /// Flag flipped by `animateSlide` so that `viewDidLayout` doesn't stomp
  /// on mid-animation top-constraint values while the window resizes or
  /// another layout pass is triggered.
  var isAnimatingWorkspaceSwitch = false

  /// Factory: construct a `PaneModel` with the terminal dependency
  /// the container owns. Kept as a method so future per-pane
  /// dependencies land in one place. The browser data store comes
  /// from the **target** workspace (not the focused one) so panes
  /// built for a new workspace honour its private flag even before
  /// the container switches over to it — `dependencies.dataStore` is
  /// only filled in from the workspace when the caller leaves it
  /// nil. Optional browser-specific inputs (suspend-deferred boot,
  /// restored title / history) live on `PaneDependencies`; see
  /// `PaneModel.init` for the field-level contract.
  func makePane(
    address: PaneAddress,
    in workspace: WorkspaceModel? = nil,
    dependencies: PaneDependencies = .init()
  ) -> PaneModel {
    let ws = workspace ?? currentWorkspace
    var deps = dependencies
    // Default the data store from the resolved workspace if the
    // caller did not pass one explicitly. Caller-supplied values
    // win so call sites that genuinely need a different store
    // (rare) can still override.
    if deps.dataStore == nil { deps.dataStore = ws.dataStore }
    return PaneModel(address: address, ghosttyApp: ghosttyApp, dependencies: deps)
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
    // Hover focus needs a pointer position between panes, not only the
    // ones a view happens to track, so the window has to post moves
    // itself. Set here rather than in `viewDidLoad` for the same reason
    // the traffic lights are re-synced below: there is no window yet at
    // that point.
    view.window?.acceptsMouseMovedEvents = true
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
        logger.info(
          "viewDidAppear re-applying focus → ws=\(target.workspaceIndex) col=\(target.columnIndex) pane=\(target.paneIndex)"
        )
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
        logger.info("viewDidAppear restoreScroll x=\(self.currentWorkspace.scrollX)")

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
          let targetX = computeScrollTargetX(for: focused, mode: .center)
        {
          // `computeScrollTargetX` returns a logical origin; add the live
          // peek compensation like every other apply site. It is zero here
          // (viewDidAppear can't be in `.hoverPeek` — peek is edge-hover
          // driven), but matching the convention keeps the logical/live
          // split uniform rather than depending on that fact implicitly.
          scrollView.contentView.setBoundsOrigin(
            NSPoint(x: targetX + hoverPeekScrollCompensation, y: 0))
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
      // `.fraction` is intentionally not re-evaluated here. Cycle
      // Width resolves the fraction to an absolute point value at
      // press time (against the visible region minus the perimeter)
      // and writes that to the constraint; from then on the column
      // stays at its committed width. A pane is a live HTML / terminal
      // surface and any width churn from a sidebar peek or a window
      // resize would re-flow the page or thrash the terminal cell
      // grid, which is worse than letting the column extend past the
      // visible region (scrolling reaches the rest).
      //
      // The `setFrameSize` poke below is a separate concern — it
      // re-syncs each pane's host view with its own frame so the
      // terminal surface metric stays in step with any layout pass,
      // independent of the column width preset.
      for column in vc.workspace.columns {
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
    if let monitor = keyEventMonitor {
      NSEvent.removeMonitor(monitor)
    }
    if let monitor = mouseMovedMonitor {
      NSEvent.removeMonitor(monitor)
    }
    // No cancel for `scrollSettleWorkItem`: it captures `self` weakly, so
    // a pending settle finds nothing and returns. Reading the property
    // from a nonisolated deinit would need it to be Sendable, which
    // `DispatchWorkItem` is not — the same reason the session autosave's
    // work item is left alone here.
    for closed in recentlyClosed {
      closed.timer.invalidate()
    }
    mediaTickTask?.cancel()
    memoryPressureSource?.cancel()
  }

  // MARK: - Scroll Event Monitor

  /// Route every scrollWheel event between pane content and the
  /// workspace's horizontal pane-navigation scroll view. Vertical
  /// gestures always belong to the pane (the browser, terminal, and
  /// finder all scroll their own content vertically). Horizontal
  /// gestures over a browser pane stay in the pane while the page has
  /// horizontal-scrollable content available in the gesture's
  /// direction; otherwise (no horizontal overflow, or at the edge
  /// against the gesture direction) the gesture spills to the
  /// workspace scrollView for pane navigation. Terminal / finder /
  /// off-pane regions are workspace-by-default for horizontal
  /// gestures since they have no horizontal-overflow concept.
  ///
  /// The decision is latched at the gesture's `.began` event and
  /// reused for every subsequent `.changed` / `.ended` / momentum
  /// event in the same gesture, so mid-gesture changes to a page's
  /// horizontal scroll state can't toggle the routing mid-stream.
  /// Mouse-wheel events arrive without a phase and are decided per
  /// event.
  private func installScrollEventMonitor() {
    scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
      [weak self] event in
      guard let self else { return event }
      return self.routeScrollEvent(event)
    }
  }

  /// Bring the focused column back into frame when the user types into
  /// it. Horizontal scrolling is free and focus doesn't follow it, so the
  /// focused pane can sit entirely outside the viewport while it still
  /// owns the keyboard — keystrokes land somewhere the user can't see,
  /// and the only way back was to scroll and hunt for the pane taking
  /// them.
  ///
  /// Three things this deliberately does not react to:
  ///
  /// - **Chords.** A modifier means a command, not typing, and the
  ///   commands that move focus scroll for themselves. Reacting would
  ///   queue a tween toward the column the user is leaving — including
  ///   ⌘W, where it aims at a column that is about to be removed. The
  ///   AppDelegate's own key monitors all filter modifiers the same way.
  /// - **Text controls in the window.** The URL field, the palette and
  ///   the worklane's workspace-rename field all take typing while the
  ///   user is deliberately looking somewhere else in the workspace;
  ///   dragging the columns out from under them would be the opposite of
  ///   helpful.
  /// - **A column already fully on screen**, tested here rather than
  ///   left to `scrollToColumn`. That function forces a layout pass
  ///   before it decides, which is far too much to spend on every
  ///   repeat of a held-down key in a terminal.
  /// Cheap approximation of "`.settle` would not move for this column",
  /// used to skip the scroll call before it forces a layout pass — too
  /// much to spend on every repeat of a held-down key in a terminal.
  /// Ignores insets and the inter-column gap, so the exact answer still
  /// comes from `columnScrollTargetX`; this only has to be right about
  /// the common case of a column plainly seated, in either sense of it:
  /// a narrow one wholly on screen, a wide one covering the screen.
  private func seatsWithoutScrolling(_ column: ColumnModel) -> Bool {
    let visible = scrollView.documentVisibleRect
    let frame = column.containerView.frame
    return visible.contains(frame) || frame.contains(visible)
  }

  private func installKeyEventMonitor() {
    keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard let self, let window = self.view.window,
        event.window === window,
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift).isEmpty,
        !(window.firstResponder is NSText),
        let column = self.columns[safe: self.focusedColumnIndex],
        !self.seatsWithoutScrolling(column)
      else { return event }
      // `.settle` rather than frame-in: a column wider than the viewport
      // is seated when it covers the screen, and frame-in would instead
      // haul it back to its leading edge on every keystroke and make the
      // far side of an oversized pane impossible to type in.
      _ = self.scrollToColumn(at: self.focusedColumnIndex, mode: .settle)
      return event
    }
  }

  private func routeScrollEvent(_ event: NSEvent) -> NSEvent? {
    // A local monitor sees events for every window the app has, and
    // `locationInWindow` is relative to whichever one that is. Without
    // this, a scroll inside an auxiliary panel — Settings, a popup a
    // page opened — is measured against the main window's geometry,
    // where it usually does land inside the pane area, and gets routed
    // to the workspace instead of to the panel under the pointer.
    guard event.window === view.window else { return event }

    let locationInView = scrollView.convert(event.locationInWindow, from: nil)
    guard scrollView.bounds.contains(locationInView) else { return event }

    let decision: ScrollGestureLock
    if event.phase == .began {
      let d = decideScrollLock(for: event)
      scrollGestureLock = d
      decision = d
    } else if event.phase == [] && event.momentumPhase == [] {
      // Mouse wheel: no phase to latch against, decide per event.
      decision = decideScrollLock(for: event)
    } else if let locked = scrollGestureLock {
      decision = locked
    } else {
      // Phase event with no prior `.began` (e.g., a stray momentum
      // event after our monitor was reattached). Decide ad-hoc rather
      // than dropping the event.
      decision = decideScrollLock(for: event)
    }

    switch decision {
    case .workspace:
      scrollView.scrollWheel(with: event)
      // A column sliding under a motionless pointer is the other way the
      // pane it is over can change. Armed here rather than inside the
      // settle so it still runs with the snap-back turned off — the two
      // are separate settings.
      scheduleHoverFocus()
      scheduleScrollSettle(after: event)
      return nil
    case .pane:
      return event
    }
  }

  /// Decide when the workspace scroll has actually stopped, and run the
  /// settle then.
  ///
  /// The question is answered by watching the scroll origin hold still,
  /// not by reading the event phases. Phases describe a trackpad gesture
  /// in two acts — `phase` reaches `.ended` when the fingers lift, then a
  /// second stream of momentum events plays out the fling — and the end
  /// of the second act does not reliably arrive. A fling that runs into
  /// the end of the workspace has its momentum cut short, and the
  /// `.ended` that would have closed the stream never comes; waiting for
  /// it meant the settle simply never ran, which is exactly how this
  /// looked in use.
  ///
  /// Re-arming while the origin is still moving is what a plain debounce
  /// could not do. A fixed delay fires in the gaps of a thinning momentum
  /// tail, and the remaining momentum then drags the seated column back
  /// out from under the snap.
  ///
  /// `momentumPhase == .ended` is still honoured when it does arrive, as
  /// a way to settle on the same frame the fling stops rather than one
  /// delay later.
  private func scheduleScrollSettle(after event: NSEvent) {
    guard PreferencesStore.shared.preferences.scrollSnapBackDistance > 0 else { return }
    scrollSettleWorkItem?.cancel()
    scrollSettleWorkItem = nil
    if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
      settleScroll()
      return
    }
    armScrollSettleCheck()
  }

  /// Look again after `scrollSettleDelay`, and settle only if the scroll
  /// origin has not moved since this check was armed.
  private func armScrollSettleCheck() {
    let anchorX = scrollView.contentView.bounds.origin.x
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.scrollSettleWorkItem = nil
      guard abs(self.scrollView.contentView.bounds.origin.x - anchorX) < 0.5 else {
        // Still travelling — under a finger or on momentum. Settling into
        // a position that is about to change is what makes a snap fight
        // the fling, so ask again instead.
        self.armScrollSettleCheck()
        return
      }
      self.settleScroll()
    }
    scrollSettleWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollSettleDelay, execute: work)
  }

  /// Nudge a scroll that stopped just short of leaving the focused pane
  /// fully on screen.
  ///
  /// The correction runs against the direction just scrolled, so it is
  /// only wanted while it is small: closing a sliver reads as tidying
  /// up, while a bigger one takes back a scroll the user meant. How
  /// small is the user's to set, and zero turns it off.
  ///
  /// `.settle` rather than `.frameIn` because frame-in pins a column
  /// wider than the viewport to its leading edge, which would undo every
  /// scroll made inside a pane bigger than the screen. For anything that
  /// fits, the two are the same move.
  private func settleScroll() {
    scrollSettleWorkItem = nil
    let limit = PreferencesStore.shared.preferences.scrollSnapBackDistance
    guard limit > 0 else { return }
    guard let column = columns[safe: focusedColumnIndex] else { return }
    // A pinned column rides in the fixed leading overlay rather than the
    // scrolling stack, so a scroll never leaves it half off screen.
    guard !column.isPinned else { return }

    // The target is read off column frames, so let the layout settle
    // before asking for it.
    view.layoutSubtreeIfNeeded()
    let currentX = scrollView.contentView.bounds.origin.x - hoverPeekScrollCompensation
    guard let target = computeScrollTargetX(for: column, mode: .settle),
      abs(target - currentX) <= limit
    else { return }
    _ = scrollToColumn(at: focusedColumnIndex, mode: .settle)
  }

  private func decideScrollLock(for event: NSEvent) -> ScrollGestureLock {
    if abs(event.scrollingDeltaX) <= abs(event.scrollingDeltaY) {
      return .pane
    }
    guard let hit = paneAtWindowLocation(event.locationInWindow),
      let browserView = columns[hit.column].panes[hit.pane].browserView
    else {
      return .workspace
    }
    // A pinch-magnified page overflows its pane at the rendering layer,
    // so a horizontal gesture over it is a pan across the zoomed
    // content. `horizontalScrollEdge` is reported by a script reading
    // the DOM, and `magnification` is a visual scale that leaves
    // `scrollWidth` untouched — so the script keeps saying "nothing to
    // scroll" and the pan would go to the workspace, leaving the part of
    // the page that just went off the edge reachable only by zooming
    // back out.
    //
    // LIMITATION: the pane keeps every horizontal gesture for as long as
    // the page is magnified, so column swiping is unavailable until the
    // zoom returns to 1 (⌘0, or a pinch back). Panning wins because
    // zooming in is a request to look closely at *this* page, and the
    // columns stay reachable by keyboard and sidebar meanwhile. Serving
    // both would need the edge of the magnified viewport: WebKit exposes
    // no offset for it, and the page cannot see it either, since this is
    // a view scale rather than page pinch-zoom.
    //
    // Only zooming *in* overflows — a pinch that shrinks the page has
    // nothing to pan, so it must keep spilling to the workspace. The
    // tolerance matches the worklane's zoom-reset gate: a gesture rarely
    // settles on exactly 1, and an exact test would leave the pane
    // holding every gesture at 1.0000003.
    if browserView.webView.magnification > 1 + Self.magnificationTolerance {
      return .pane
    }
    return canPaneAbsorbHorizontal(
      deltaX: event.scrollingDeltaX,
      edge: browserView.horizontalScrollEdge
    ) ? .pane : .workspace
  }

  /// Whether the pane's horizontal scroll capability accommodates a
  /// gesture of the given delta. `deltaX` follows NSEvent's
  /// natural-scrolling convention: a positive value corresponds to a
  /// gesture that scrolls the page back toward its leading content
  /// (the user's swipe reveals what was hidden to the left), and a
  /// negative value scrolls forward toward trailing content. The edge
  /// labels mirror that — `right` means "the page can still scroll
  /// rightward into trailing content," etc. — so the absorb check is
  /// the natural conjunction.
  private func canPaneAbsorbHorizontal(
    deltaX: CGFloat,
    edge: BrowserPaneView.HorizontalScrollEdge
  ) -> Bool {
    switch edge {
    case .none: return false
    case .both: return true
    case .left: return deltaX > 0
    case .right: return deltaX < 0
    }
  }

  /// Hit-test every pane in the current workspace's columns for a
  /// window-space point. Non-current workspaces are parked off-screen
  /// by `viewDidLayout` so their pane frames never overlap any visible
  /// cursor position; restricting the scan to `columns` (=
  /// `currentWorkspace.columns`) avoids a confusing match against an
  /// off-screen pane that happens to share a coordinate with the
  /// cursor. Panes don't overlap within a workspace, so first-hit is
  /// unambiguous. Returns `nil` when the cursor is over chrome
  /// (sidebar, gaps between panes, the URL bar's hover-peek body,
  /// etc.) — those land on the workspace by default.
  private func paneAtWindowLocation(_ pointInWindow: NSPoint) -> (column: Int, pane: Int)? {
    // Only what the viewport actually shows can be hit. Two ways a pane
    // frame reaches somewhere the pane is not: a column scrolled past
    // the right edge keeps a frame that goes out of the window with it,
    // and columns pass *under* the sidebar, which overlays the scroll
    // view rather than shortening it. Both put a pane's frame beneath a
    // pointer that is looking at something else entirely.
    //
    // `currentLeadingInset` rather than the scroll view's own
    // `contentInsets.left`: the latter is the sidebar reserve *plus* the
    // pinned-column reserve, and a pinned column is a real column
    // sitting visibly inside that strip. Subtracting the whole inset
    // would make the pin the one column nothing can hit.
    var band = scrollView.convert(scrollView.bounds, to: nil)
    band.origin.x += currentLeadingInset
    band.size.width -= currentLeadingInset
    guard band.contains(pointInWindow) else { return nil }
    for (columnIndex, col) in columns.enumerated() {
      for (paneIndex, pane) in col.panes.enumerated() {
        let frame = pane.containerView.convert(pane.containerView.bounds, to: nil)
        if frame.contains(pointInWindow) {
          return (columnIndex, paneIndex)
        }
      }
    }
    return nil
  }

  // MARK: - Hover Focus

  /// Give focus to the pane the pointer is resting on, once both the
  /// pointer and the workspace have been still long enough to call it
  /// resting.
  ///
  /// The dwell is the whole idea. A pointer crossing a pane on its way
  /// somewhere else should not drag focus through every pane it passes
  /// over, so the check is armed on each movement and only the one that
  /// survives ``hoverFocusDelay`` untouched gets to act. The scroll
  /// origin is held to the same standard: a column sliding under a
  /// motionless pointer is the workspace moving, not the user choosing.
  private func installMouseMovedMonitor() {
    mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) {
      [weak self] event in
      self?.scheduleHoverFocus()
      return event
    }
  }

  func scheduleHoverFocus() {
    guard PreferencesStore.shared.preferences.focusPaneUnderCursor == true else { return }
    hoverFocusWorkItem?.cancel()
    hoverFocusWorkItem = nil
    guard let window = view.window, window.isKeyWindow, window.attachedSheet == nil else { return }
    let mouse = NSEvent.mouseLocation
    let originX = scrollView.contentView.bounds.origin.x
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.hoverFocusWorkItem = nil
      // A newer movement would have replaced this work item, so reaching
      // here already means the pointer held still; the comparison covers
      // a move that arrived without an event, and the origin covers a
      // scroll still running under it.
      guard NSEvent.mouseLocation == mouse,
        abs(self.scrollView.contentView.bounds.origin.x - originX) < 0.5
      else { return }
      self.focusPaneUnderCursor()
    }
    hoverFocusWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverFocusDelay, execute: work)
  }

  private func focusPaneUnderCursor() {
    guard let window = view.window, window.isKeyWindow, window.attachedSheet == nil else { return }
    guard !isAnimatingWorkspaceSwitch else { return }
    // The last movement before the pointer left the window is still the
    // one that armed this check, and it fires on whatever the pointer is
    // resting on now — which may be another app entirely.
    let mouse = NSEvent.mouseLocation
    guard window.frame.contains(mouse) else { return }
    let pointInWindow = window.convertPoint(fromScreen: mouse)
    // Nothing under the pointer but chrome — a gap, the sidebar, the
    // find bar — is not a request to focus anything.
    guard let hit = paneAtWindowLocation(pointInWindow) else { return }
    let pane = columns[hit.column].panes[hit.pane]
    guard pane.id != focusedPane?.id else { return }
    // Same scroll every other way of taking focus makes, and it cannot
    // move the pane out from under the pointer: bringing a column into
    // view only ever widens the slice of it that is on screen, and the
    // pointer is already inside that slice. `scroll: false` on the focus
    // call so it doesn't run its own frame-in first — `.settle` is the
    // one to make, since frame-in would pin a column wider than the
    // screen to its leading edge and undo a scroll made inside it.
    setFocus(columnIndex: hit.column, paneIndex: hit.pane, scroll: false)
    _ = scrollToColumn(at: hit.column, mode: .settle)
  }
}
