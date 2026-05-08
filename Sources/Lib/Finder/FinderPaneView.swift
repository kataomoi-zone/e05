import AppKit
import QuickLookThumbnailing

/// Native file-browser pane backed by an `NSTableView` in Finder's
/// standard list-view visuals: inset row style, 22pt rows with 16pt
/// `URLResourceKey.effectiveIcon` icons, alternating row backgrounds,
/// and columns for Name / Date Modified / Size / Kind. Keyboard
/// navigation, `QLPreviewPanel` preview on Space, and a bottom status
/// bar mirror the Finder affordances users already know.
///
/// The view emits four callbacks so the container controller can
/// reconcile the surrounding pane state (URL bar, sidebar worklane,
/// session persistence) with every navigation without this view having
/// to reach up into the AppDelegate graph:
///
/// - `onPathChange`: fired after every navigate / goBack / goForward /
///   goUp. The container rebuilds `pane.address = .finder(path:)` and
///   refreshes the URL bar display, so the address acts as a single
///   source of truth for the current cwd.
/// - `onTitleChange`: fired with the directory's `lastPathComponent`
///   so `pane.title` — and the sidebar worklane row — follows the cwd.
/// - `onFocusChanged`: fired when the table view becomes first
///   responder, mirroring the terminal / browser pane affordance that
///   keyboard focus moves pane focus.
/// - `onNavigationStateChange`: fired with `(canGoBack, canGoForward)`
///   so the URL bar's back/forward chevrons dim in sync.
///
/// Behaviour is split across several extensions by responsibility:
///
/// - `FinderPaneView+Directory` — navigate / goBack / goForward /
///   goUp / reload, directory enumeration with the hidden-files
///   filter, sort, icon cache, status-bar refresh.
/// - `FinderPaneView+Table` — NSTableViewDataSource and
///   NSTableViewDelegate conformance plus cell-view factories.
/// - `FinderPaneView+Rename` — inline rename, new folder,
///   move-to-trash, and NSTextFieldDelegate.
/// - `FinderPaneView+QuickLook` — Space preview wiring and
///   QLPreviewPanel data source.
/// - `FinderPaneView+Actions` — row-level actions and the
///   internal-only surface `FinderTableView` uses for key handling.
@MainActor
public final class FinderPaneView: NSView {
  // MARK: - Public API

  public var onPathChange: ((URL) -> Void)?
  public var onTitleChange: ((String) -> Void)?
  public var onFocusChanged: (() -> Void)?
  public var onNavigationStateChange: ((Bool, Bool) -> Void)?

  /// Current working directory. Written from `FinderPaneView+Directory`
  /// via `loadDirectory`; exposed read-only so callers observe the
  /// authoritative cwd without reaching into the navigation internals.
  public internal(set) var currentURL: URL

  public var canGoBack: Bool { !backStack.isEmpty }
  public var canGoForward: Bool { !forwardStack.isEmpty }

  /// `NSView` to receive keyboard focus when the pane is activated.
  /// Routes to the active presentation so arrow keys (and the list
  /// view's vim / Quick Look / Return overrides) reach the right
  /// view without the pane root stealing first responder.
  public var keyboardFocusTarget: NSView {
    switch currentMode {
    case .list: return tableView
    case .icon: return iconCollectionView
    }
  }

  /// Active presentation. Read by `keyboardFocusTarget`,
  /// `selectedURLs` and friends, the data-source / delegate
  /// callbacks, and the visibility helpers in
  /// `FinderPaneView+IconView`. Mutate via `setViewMode(_:)` so the
  /// store write, the cross-pane notification, and the visibility
  /// flip stay in sync.
  public internal(set) var currentMode: FinderViewMode

  /// Hand AppKit's `undo:` / `redo:` selectors the app-global finder
  /// undo manager when this pane sits on the responder chain. Without
  /// this override, `NSResponder.undoManager` walks up to the window
  /// and lands on `nil`, leaving the menu-bar Edit > Undo entry
  /// disabled even after a finder-pane operation has been registered.
  public override var undoManager: UndoManager? { FinderUndoCenter.manager }

  /// Whether the active view has at least one selected entry.
  /// Branches on `currentMode` so menu validations (Move-to-Trash,
  /// Copy, …) reflect icon-mode selection too — the bare
  /// `tableView.selectedRowIndexes` would always read empty while
  /// the user has a row highlighted in the icon grid.
  public var hasSelection: Bool {
    switch currentMode {
    case .list: return !tableView.selectedRowIndexes.isEmpty
    case .icon: return !iconCollectionView.selectionIndexPaths.isEmpty
    }
  }

  // MARK: - Internal state (shared with extensions / subclasses)

  var items: [FileItem] = []
  var backStack: [URL] = []
  var forwardStack: [URL] = []

  let tableView: FinderTableView
  let scrollView = NSScrollView()
  let iconCollectionView: FinderIconCollectionView
  let iconScrollView = NSScrollView()
  let statusBar = FinderStatusBar()
  let directoryMonitor = DirectoryMonitor()

  /// Pending filesystem-event reload, debounced so that a burst of
  /// writes (`git checkout`, `cp -R`, `npm install`, …) coalesces into
  /// a single table reload. Without this, every individual `.write`
  /// event from `DispatchSource` triggers a full enumerator + sort +
  /// `reloadData`, which thrashes the table during high-churn
  /// operations and reads stale intermediate states.
  var pendingReload: DispatchWorkItem?
  static let reloadDebounceInterval: TimeInterval = 0.1

  /// In-flight off-main directory walk. Cancelled when a new reload
  /// starts so a stale 50k-entry walk on `/old/cwd` doesn't apply
  /// after the user has already navigated to `/new/cwd`. The task
  /// also no-ops on apply when `currentURL` no longer matches the
  /// captured snapshot, defending against the race window between
  /// cancel propagation and the MainActor hop.
  var pendingLoadTask: Task<Void, Never>?

  /// Last successful enumerator result, retained so an in-flight
  /// overlay refresh (`FinderOperationTracker.didChangeNotification`)
  /// can re-merge synthetic rows without paying for a fresh
  /// directory walk. Cleared on navigation so a stale parent-dir
  /// snapshot never bleeds into the new cwd.
  var lastLoadedItems: [FileItem] = []

  /// URLs currently rendered as greyed in-flight placeholders. Read
  /// by `tableView(viewFor:row:)` to toggle the spinner visibility,
  /// and by `rowViewForRow` to dim the row alongside the existing
  /// hidden-files dim path.
  var inFlightURLs: Set<URL> = []

  /// Active row-filter needle from the find bar. `nil` means the
  /// pane shows every entry; non-nil narrows `items` to the rows
  /// whose names match (`localizedStandardContains`). Reload paths
  /// (`applyLoadedItems`, `refreshInFlightOverlay`) check this
  /// after the merge so a filesystem event in the middle of a
  /// filter session doesn't tear the filter back to the full list.
  var filterNeedle: String?

  /// Block-based observer for `FinderOperationTracker.didChangeNotification`.
  /// Same `nonisolated(unsafe)` rationale as `settingsObserver` —
  /// Swift 6's nonisolated `deinit` needs to hand the token back to
  /// `removeObserver` without an actor hop.
  nonisolated(unsafe) var operationsObserver: NSObjectProtocol?

  /// Block-based observer for `FinderModeStore.didChangeNotification`.
  /// Same `nonisolated(unsafe)` rationale as `settingsObserver`.
  nonisolated(unsafe) var modeStoreObserver: NSObjectProtocol?

  /// On-demand icon store keyed by file URL. `URLResourceKey.effectiveIconKey`
  /// resolution is the most expensive per-file cost during directory
  /// loads, so icons are fetched lazily in `tableView(viewFor:row:)`
  /// for the ~30 rows actually visible, not eagerly for every entry.
  /// The cache is cleared on `loadDirectory` so navigation to a new
  /// cwd starts with a clean slate; reloads within the same cwd keep
  /// the cache (same URL → same icon). An `AppKit` icon may be a
  /// shared cached instance, but we only read it through
  /// `NSImageView` — we never mutate `.size` — so consumers of the
  /// same NSImage elsewhere in the app aren't affected.
  var iconCache: [URL: NSImage] = [:]

  /// QuickLook-generated thumbnails keyed by file URL. Populated
  /// asynchronously by `scheduleThumbnailFetch(for:)` for icon-mode
  /// cells; the list view never consults this cache because its
  /// 16pt rows don't benefit from full content thumbnails. Cells
  /// display the Launch Services icon until the fetch completes and
  /// fills the cache. Cleared on `loadDirectory` alongside
  /// `iconCache`.
  var thumbnailCache: [URL: NSImage] = [:]

  /// In-flight `QLThumbnailGenerator` work, keyed by file URL.
  /// Bundles the request handle (so a cell leaving the viewport can
  /// `cancel(_:)` it) with a per-fetch identity token. The token
  /// lets a late completion from a cancelled or superseded request
  /// recognise that its slot has been reissued and skip the cache
  /// write — without that check, a fast scroll-off-and-back could
  /// leave a fresh fetch's slot orphaned.
  var thumbnailFetchInFlight: [URL: ThumbnailFetchHandle] = [:]

  /// Monotonic source for the token field of `ThumbnailFetchHandle`.
  /// Wraps via `&+=`; collision is precluded by `scheduleThumbnailFetch`
  /// rejecting a re-issue while the URL still has an entry, so the
  /// counter never has to be unique across all `UInt64.max` values
  /// — only across simultaneously-orphaned in-flight fetches for
  /// the same URL.
  var thumbnailFetchTokenCounter: UInt64 = 0

  /// True from the moment the user starts a live scroll on the
  /// icon-mode scroll view (drag, wheel, trackpad pan) until the
  /// final momentum frame settles. Gates `thumbnailForRow`'s
  /// schedule path so a fast scroll-by doesn't kick off a
  /// `QLThumbnailGenerator` request per intermediate cell — the
  /// post-scroll debounce window picks up the final visible set
  /// instead.
  var isLiveScrolling: Bool = false

  /// Pending debounce job that schedules thumbnail fetches for the
  /// cells visible after a scroll has settled. Cancelled when a new
  /// scroll begins so the fetch only fires once the user has been
  /// quiet for the threshold.
  var pendingThumbnailScheduling: DispatchWorkItem?

  /// Block-based observers for `NSScrollView`'s live-scroll
  /// notifications. Same `nonisolated(unsafe)` rationale as
  /// `settingsObserver`.
  nonisolated(unsafe) var liveScrollWillStartObserver: NSObjectProtocol?
  nonisolated(unsafe) var liveScrollDidEndObserver: NSObjectProtocol?

  static let nameColumn = NSUserInterfaceItemIdentifier("finder.column.name")
  static let dateColumn = NSUserInterfaceItemIdentifier("finder.column.date")
  static let sizeColumn = NSUserInterfaceItemIdentifier("finder.column.size")
  static let kindColumn = NSUserInterfaceItemIdentifier("finder.column.kind")
  static let rowIdentifier = NSUserInterfaceItemIdentifier("finder.row")

  static let statusBarHeight: CGFloat = 22

  /// Sort axis backing the table-column header clicks. `rawValue` is
  /// passed as the `NSSortDescriptor.key` string so AppKit's header
  /// indicator wiring (the ▲/▼ glyph next to the active column) is
  /// driven by the same value the delegate reads back when resolving
  /// the active sort.
  enum SortKey: String {
    case name
    case dateModified
    case size
    case kind
  }

  var currentSortKey: SortKey = .name
  var sortAscending: Bool = true

  /// Block-based observer for `FinderSettings.didChangeNotification`.
  /// Held so `deinit` can pass the token to `removeObserver`:
  /// NotificationCenter retains the closure until the token is
  /// explicitly handed back, so `[weak self]` alone won't free the
  /// subscription when the pane tears down. `nonisolated(unsafe)` is
  /// required because Swift 6 makes `deinit` nonisolated by default
  /// while the property type itself is non-Sendable.
  nonisolated(unsafe) var settingsObserver: NSObjectProtocol?

  /// Active inline-rename session, or `nil` when no rename is in
  /// flight. Carries the URL of the entry being renamed and the
  /// original on-disk name; both are URL-keyed so the commit path
  /// resolves the right file even when a concurrent filesystem
  /// event or sort reshuffles `items` between begin and end editing.
  /// The mode the rename was started under is captured so the end
  /// path can restore the right cell appearance even if the user
  /// flipped view modes mid-edit (defensive — `setViewMode` already
  /// cancels the rename, but the extra grounding makes the
  /// appearance restore robust against future mode-change paths).
  var renameSession: RenameSession?

  /// Two effects gate on this flag:
  /// - `scheduleDebouncedReload` skips reloads so the in-flight
  ///   `moveItem` event we're about to emit doesn't blow the edited
  ///   cell out of the view mid-keystroke.
  /// - `controlTextDidEndEditing` uses it to distinguish a genuine
  ///   rename commit from spurious end-editing notifications (the
  ///   field editor posts one during teardown).
  var isRenaming: Bool { renameSession != nil }

  // MARK: - Init / Deinit

  public init(initialURL: URL) {
    self.currentURL = initialURL
    self.currentMode = FinderModeStore.shared.mode(for: initialURL)
    self.tableView = FinderTableView()
    self.iconCollectionView = FinderIconCollectionView()
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    setupTableView()
    setupIconView()
    setupLayout()
    applyViewModeVisibility()

    directoryMonitor.onChange = { [weak self] in
      self?.scheduleDebouncedReload()
    }

    tableView.dataSource = self
    tableView.delegate = self
    tableView.registerForDraggedTypes([.fileURL, .URL])
    tableView.onFocusChanged = { [weak self] in
      self?.onFocusChanged?()
    }

    // Re-enumerate the current directory whenever the global
    // hidden-files toggle flips so every open finder pane picks up
    // the new filter at once, matching Finder's application-wide
    // behaviour. Matches the sidebar favicon observer pattern
    // (`BookmarksSidebarView` et al.).
    settingsObserver = NotificationCenter.default.addObserver(
      forName: FinderSettings.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reload() }
    }

    // Refresh the in-flight overlay (greyed placeholder rows for
    // archive / copy / paste targets that aren't on disk yet)
    // whenever an operation registers or unregisters. Cheap re-merge
    // against `lastLoadedItems` rather than a fresh enumerator walk.
    operationsObserver = NotificationCenter.default.addObserver(
      forName: FinderOperationTracker.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshInFlightOverlay() }
    }

    // Cross-pane mode sync: a `View as …` action on pane A surfaces
    // through the store's notification, and any open pane on the
    // same cwd applies the new mode through `resyncViewModeFromStore`.
    modeStoreObserver = NotificationCenter.default.addObserver(
      forName: FinderModeStore.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.resyncViewModeFromStore() }
    }

    loadDirectory(url: initialURL, pushHistory: false, announce: false)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  deinit {
    // `DirectoryMonitor` cancels its own DispatchSource in its
    // deinit; only the block-based NotificationCenter observer needs
    // explicit release here. `removeObserver(_:)` is nonisolated so
    // calling it from the Swift 6 default nonisolated deinit is safe
    // — no `MainActor.assumeIsolated` hop, and therefore none of the
    // "last reference released off-main" crash risk that touching
    // MainActor-isolated properties from deinit would carry.
    if let token = settingsObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = operationsObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = modeStoreObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = liveScrollWillStartObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = liveScrollDidEndObserver {
      NotificationCenter.default.removeObserver(token)
    }
  }

  // MARK: - Setup

  private func setupTableView() {
    let nameCol = NSTableColumn(identifier: Self.nameColumn)
    nameCol.title = "Name"
    nameCol.width = 260
    nameCol.minWidth = 120
    nameCol.resizingMask = [.autoresizingMask, .userResizingMask]
    // Default directions match Finder list-view conventions: Name /
    // Kind ascending (A→Z), Date Modified / Size descending (newest
    // and largest first). The first click on a column header uses
    // this direction; a second click flips it. The key string must
    // round-trip through `SortKey(rawValue:)` in the delegate, so
    // both sides share the enum as the source of truth.
    nameCol.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.name.rawValue, ascending: true)

    let dateCol = NSTableColumn(identifier: Self.dateColumn)
    dateCol.title = "Date Modified"
    dateCol.width = 150
    dateCol.minWidth = 100
    dateCol.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.dateModified.rawValue, ascending: false)

    let sizeCol = NSTableColumn(identifier: Self.sizeColumn)
    sizeCol.title = "Size"
    sizeCol.width = 80
    sizeCol.minWidth = 60
    sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.size.rawValue, ascending: false)

    let kindCol = NSTableColumn(identifier: Self.kindColumn)
    kindCol.title = "Kind"
    kindCol.width = 120
    kindCol.minWidth = 80
    kindCol.sortDescriptorPrototype = NSSortDescriptor(key: SortKey.kind.rawValue, ascending: true)

    for col in [nameCol, dateCol, sizeCol, kindCol] {
      tableView.addTableColumn(col)
    }

    // Seed the active sort so the Name column renders its ▲ indicator
    // on first appearance and `sortItems` has a stable key to start
    // from, before the user clicks any header.
    tableView.sortDescriptors = [NSSortDescriptor(key: SortKey.name.rawValue, ascending: true)]

    tableView.rowHeight = 22
    tableView.intercellSpacing = NSSize(width: 8, height: 0)
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.allowsMultipleSelection = true
    tableView.style = .inset
    tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    tableView.doubleAction = #selector(doubleClickAction(_:))
    tableView.target = self
    tableView.focusRingType = .none

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
  }

  private func setupLayout() {
    statusBar.translatesAutoresizingMaskIntoConstraints = false

    // Both scroll views share the same area above the status bar;
    // `applyViewModeVisibility()` toggles `isHidden` so only the
    // active one renders. Keeping both mounted (rather than swapping
    // subviews on mode change) avoids tearing down NSCollectionView
    // / NSTableView state on every flip and keeps selection /
    // scroll position intact across switches.
    addSubview(scrollView)
    addSubview(iconScrollView)
    addSubview(statusBar)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

      iconScrollView.topAnchor.constraint(equalTo: topAnchor),
      iconScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      iconScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      iconScrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

      statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
      statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
      statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
      statusBar.heightAnchor.constraint(equalToConstant: Self.statusBarHeight),
    ])
  }
}
