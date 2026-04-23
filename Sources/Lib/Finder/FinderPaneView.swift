import AppKit
import QuickLookUI
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "FinderPane")

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
@MainActor
public final class FinderPaneView: NSView {
  public var onPathChange: ((URL) -> Void)?
  public var onTitleChange: ((String) -> Void)?
  public var onFocusChanged: (() -> Void)?
  public var onNavigationStateChange: ((Bool, Bool) -> Void)?

  public private(set) var currentURL: URL
  private var items: [FileItem] = []

  private var backStack: [URL] = []
  private var forwardStack: [URL] = []

  public var canGoBack: Bool { !backStack.isEmpty }
  public var canGoForward: Bool { !forwardStack.isEmpty }

  /// `NSView` to receive keyboard focus when the pane is activated.
  /// Always the inner table view so arrow / vim keys, Return, Space
  /// (Quick Look) reach the navigation handlers without the pane root
  /// view stealing first responder.
  public var keyboardFocusTarget: NSView { tableView }

  private let tableView: FinderTableView
  private let scrollView = NSScrollView()
  private let statusBar = FinderStatusBar()
  private let directoryMonitor = DirectoryMonitor()

  /// Pending filesystem-event reload, debounced so that a burst of
  /// writes (`git checkout`, `cp -R`, `npm install`, …) coalesces into
  /// a single table reload. Without this, every individual `.write`
  /// event from `DispatchSource` triggers a full enumerator + sort +
  /// `reloadData`, which thrashes the table during high-churn
  /// operations and reads stale intermediate states.
  private var pendingReload: DispatchWorkItem?
  private static let reloadDebounceInterval: TimeInterval = 0.1

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
  private var iconCache: [URL: NSImage] = [:]

  private static let nameColumn = NSUserInterfaceItemIdentifier("finder.column.name")
  private static let dateColumn = NSUserInterfaceItemIdentifier("finder.column.date")
  private static let sizeColumn = NSUserInterfaceItemIdentifier("finder.column.size")
  private static let kindColumn = NSUserInterfaceItemIdentifier("finder.column.kind")

  private static let statusBarHeight: CGFloat = 22

  public init(initialURL: URL) {
    self.currentURL = initialURL
    self.tableView = FinderTableView()
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    setupTableView()
    setupLayout()

    directoryMonitor.onChange = { [weak self] in
      self?.scheduleDebouncedReload()
    }

    tableView.dataSource = self
    tableView.delegate = self
    tableView.onFocusChanged = { [weak self] in
      self?.onFocusChanged?()
    }

    loadDirectory(url: initialURL, pushHistory: false, announce: false)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  // No `deinit` needed: `DirectoryMonitor`'s own `deinit` cancels the
  // DispatchSource. Calling `MainActor.assumeIsolated` from this
  // class's deinit would crash if the last reference were ever
  // dropped on a non-main thread (autorelease pool drains, Combine
  // chains, etc.) — Swift 6 deinit is nonisolated by default.

  // MARK: - Setup

  private func setupTableView() {
    let nameCol = NSTableColumn(identifier: Self.nameColumn)
    nameCol.title = "Name"
    nameCol.width = 260
    nameCol.minWidth = 120
    nameCol.resizingMask = [.autoresizingMask, .userResizingMask]

    let dateCol = NSTableColumn(identifier: Self.dateColumn)
    dateCol.title = "Date Modified"
    dateCol.width = 150
    dateCol.minWidth = 100

    let sizeCol = NSTableColumn(identifier: Self.sizeColumn)
    sizeCol.title = "Size"
    sizeCol.width = 80
    sizeCol.minWidth = 60

    let kindCol = NSTableColumn(identifier: Self.kindColumn)
    kindCol.title = "Kind"
    kindCol.width = 120
    kindCol.minWidth = 80

    for col in [nameCol, dateCol, sizeCol, kindCol] {
      tableView.addTableColumn(col)
    }

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

    addSubview(scrollView)
    addSubview(statusBar)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

      statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
      statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
      statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
      statusBar.heightAnchor.constraint(equalToConstant: Self.statusBarHeight),
    ])
  }

  // MARK: - Navigation

  /// Navigate to `url`. Non-directories are dispatched to
  /// `NSWorkspace.shared.open(_:)` so clicking a file in the list opens
  /// it in the system-default application, matching Finder.
  public func navigate(to url: URL) {
    let resolved = url.resolvingSymlinksInPath()
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved.path(percentEncoded: false), isDirectory: &isDir) else {
      logger.warning("navigate(to:) target does not exist: \(resolved.path, privacy: .public)")
      return
    }
    if isDir.boolValue {
      loadDirectory(url: resolved, pushHistory: true, announce: true)
    } else {
      NSWorkspace.shared.open(resolved)
    }
  }

  public func goBack() {
    guard let prev = backStack.popLast() else { return }
    forwardStack.append(currentURL)
    loadDirectory(url: prev, pushHistory: false, announce: true)
  }

  public func goForward() {
    guard let next = forwardStack.popLast() else { return }
    backStack.append(currentURL)
    loadDirectory(url: next, pushHistory: false, announce: true)
  }

  public func goUp() {
    let parent = currentURL.deletingLastPathComponent()
    guard parent != currentURL else { return }
    loadDirectory(url: parent, pushHistory: true, announce: true)
  }

  /// Force a contents re-read. The directory monitor already triggers
  /// this on filesystem events; this public entry lets the URL bar's
  /// reload button (or a future ⌘R action) fire it manually.
  public func reload() {
    reloadItems(preservingSelection: true)
    onNavigationStateChange?(canGoBack, canGoForward)
  }

  private func loadDirectory(url: URL, pushHistory: Bool, announce: Bool) {
    if pushHistory && url != currentURL {
      backStack.append(currentURL)
      forwardStack.removeAll()
    }

    currentURL = url
    // Drop icons from the previous directory — they'd waste memory
    // proportional to navigation depth otherwise. Reloads within the
    // same cwd (directory-monitor events) keep the cache: same URL =
    // same icon, no I/O needed.
    iconCache.removeAll(keepingCapacity: true)
    reloadItems(preservingSelection: false)
    directoryMonitor.start(at: url)

    if announce {
      onPathChange?(url)
      onTitleChange?(url.lastPathComponent.isEmpty ? "Finder" : url.lastPathComponent)
    }
    onNavigationStateChange?(canGoBack, canGoForward)
  }

  private func scheduleDebouncedReload() {
    pendingReload?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.reloadItems(preservingSelection: true)
    }
    pendingReload = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.reloadDebounceInterval, execute: work)
  }

  private func reloadItems(preservingSelection: Bool) {
    let previouslySelectedURLs: [URL] =
      preservingSelection
      ? tableView.selectedRowIndexes.compactMap { idx in
        idx < items.count ? items[idx].url : nil
      }
      : []

    var loaded: [FileItem] = []
    if let enumerator = FileManager.default.enumerator(
      at: currentURL,
      includingPropertiesForKeys: Array(FileItem.resourceKeys),
      options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles, .skipsPackageDescendants]
    ) {
      for case let url as URL in enumerator {
        loaded.append(FileItem(url: url))
      }
    }

    // Directories first, then alphabetical by localized name — the
    // Finder default. Packages (`.app`, `.bundle`) sort with files
    // because Finder treats them as single-click openable units.
    loaded.sort { a, b in
      let aIsDir = a.isDirectory && !a.isPackage
      let bIsDir = b.isDirectory && !b.isPackage
      if aIsDir != bIsDir { return aIsDir }
      return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    items = loaded
    tableView.reloadData()
    updateStatusBar()

    if preservingSelection && !previouslySelectedURLs.isEmpty {
      var restored = IndexSet()
      for url in previouslySelectedURLs {
        if let idx = items.firstIndex(where: { $0.url == url }) {
          restored.insert(idx)
        }
      }
      if !restored.isEmpty {
        tableView.selectRowIndexes(restored, byExtendingSelection: false)
      }
    }
  }

  /// Resolve the icon for `item`, consulting the visible-row cache
  /// first. `URLResourceKey.effectiveIcon` returns whatever Finder
  /// would draw for the file (package icons, alias glyphs, custom
  /// icons set via Get Info); `NSWorkspace.icon(forFile:)` is the
  /// fallback when the resource-values read fails (broken symlinks,
  /// permission errors). Both return shared `NSImage` instances that
  /// must not have their `size` mutated — the image view handles
  /// display sizing via `.scaleProportionallyDown` plus a 16pt frame
  /// constraint.
  private func iconForRow(_ item: FileItem) -> NSImage {
    if let cached = iconCache[item.url] { return cached }
    let values = try? item.url.resourceValues(forKeys: [.effectiveIconKey])
    let image =
      (values?.effectiveIcon as? NSImage)
      ?? NSWorkspace.shared.icon(forFile: item.url.path(percentEncoded: false))
    iconCache[item.url] = image
    return image
  }

  // MARK: - Status Bar

  private func updateStatusBar() {
    let selected = tableView.selectedRowIndexes
    var available: Int64?
    if let values = try? currentURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
      let bytes = values.volumeAvailableCapacityForImportantUsage
    {
      available = bytes
    }
    statusBar.update(totalCount: items.count, selectedCount: selected.count, availableBytes: available)
  }

  // MARK: - Actions

  @objc private func doubleClickAction(_ sender: Any?) {
    let row = tableView.clickedRow
    guard row >= 0, row < items.count else { return }
    navigate(to: items[row].url)
  }

  private func openSelected() {
    guard let row = tableView.selectedRowIndexes.first, row < items.count else { return }
    navigate(to: items[row].url)
  }

  private func moveSelection(by offset: Int) {
    guard !items.isEmpty else { return }
    let current = tableView.selectedRow
    let next = max(0, min(items.count - 1, current + offset))
    tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
    tableView.scrollRowToVisible(next)
  }

  private func selectRow(_ row: Int) {
    guard row >= 0, row < items.count else { return }
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
  }

  // MARK: - Quick Look

  fileprivate func toggleQuickLook() {
    guard let panel = QLPreviewPanel.shared() else { return }
    if panel.isVisible {
      panel.orderOut(nil)
    } else {
      panel.makeKeyAndOrderFront(nil)
    }
  }

  public override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
    true
  }

  // The QuickLook responder methods come from `NSResponder` which is
  // not MainActor-isolated, but `QLPreviewPanel` only ever invokes them
  // on the main thread. `MainActor.assumeIsolated` records that
  // contract and lets us touch the panel's MainActor-isolated
  // properties without a thread hop.
  public override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    MainActor.assumeIsolated {
      panel.dataSource = self
      panel.delegate = self
    }
  }

  public override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    MainActor.assumeIsolated {
      panel.dataSource = nil
      panel.delegate = nil
    }
  }
}

// MARK: - NSTableViewDataSource

extension FinderPaneView: NSTableViewDataSource {
  public func numberOfRows(in tableView: NSTableView) -> Int {
    items.count
  }
}

// MARK: - NSTableViewDelegate

extension FinderPaneView: NSTableViewDelegate {
  public func tableView(
    _ tableView: NSTableView,
    viewFor tableColumn: NSTableColumn?,
    row: Int
  ) -> NSView? {
    guard let column = tableColumn, row < items.count else { return nil }
    let item = items[row]
    let identifier = column.identifier

    if identifier == Self.nameColumn {
      let cell =
        tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
        ?? Self.makeNameCell(identifier: identifier)
      cell.textField?.stringValue = item.name
      cell.imageView?.image = iconForRow(item)
      return cell
    }

    let cell =
      tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
      ?? Self.makeTextCell(identifier: identifier)

    switch identifier {
    case Self.dateColumn:
      cell.textField?.stringValue = item.displayDate
    case Self.sizeColumn:
      cell.textField?.stringValue = item.displaySize
      cell.textField?.alignment = .right
    case Self.kindColumn:
      cell.textField?.stringValue = item.displayKind
    default:
      cell.textField?.stringValue = ""
    }
    cell.textField?.textColor = .secondaryLabelColor
    return cell
  }

  public func tableViewSelectionDidChange(_ notification: Notification) {
    updateStatusBar()
    if QLPreviewPanel.sharedPreviewPanelExists(),
      let panel = QLPreviewPanel.shared(), panel.isVisible
    {
      panel.reloadData()
    }
  }

  private static func makeNameCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier

    let imageView = NSImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.imageScaling = .scaleProportionallyDown

    let textField = NSTextField(labelWithString: "")
    textField.font = .systemFont(ofSize: 13)
    textField.lineBreakMode = .byTruncatingTail
    textField.translatesAutoresizingMaskIntoConstraints = false

    cell.addSubview(imageView)
    cell.addSubview(textField)
    cell.imageView = imageView
    cell.textField = textField

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
      imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      imageView.widthAnchor.constraint(equalToConstant: 16),
      imageView.heightAnchor.constraint(equalToConstant: 16),
      textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
      textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
      textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  private static func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier

    let textField = NSTextField(labelWithString: "")
    textField.font = .systemFont(ofSize: 12)
    textField.lineBreakMode = .byTruncatingTail
    textField.translatesAutoresizingMaskIntoConstraints = false

    cell.addSubview(textField)
    cell.textField = textField

    NSLayoutConstraint.activate([
      textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
      textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
      textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }
}

// MARK: - QLPreviewPanelDataSource / Delegate

// `QLPreviewPanelDataSource` is a pre-concurrency Objective-C protocol;
// `@preconcurrency` lets the MainActor-isolated `FinderPaneView` satisfy
// its nonisolated requirements. At runtime QLPreviewPanel only ever invokes
// these on the main thread, so the isolation crossing the compiler warns
// about doesn't actually occur. `QLPreviewPanelDelegate` has no required
// methods we currently implement, so its conformance has no isolation gap
// to bridge.
extension FinderPaneView: @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    tableView.selectedRowIndexes.count
  }

  public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
    let selected = Array(tableView.selectedRowIndexes)
    guard index >= 0, index < selected.count else { return nil }
    let row = selected[index]
    guard row < items.count else { return nil }
    return items[row].url as NSURL
  }
}

// MARK: - Key Handling

/// `NSTableView` subclass that forwards key events we want to intercept
/// (Space for Quick Look, Return / Right / Left / Backspace for
/// navigation, h/j/k/l for vim-style movement) to the owning
/// `FinderPaneView`, while letting the table's own handling cover
/// arrow-key row movement and native shortcuts.
@MainActor
private final class FinderTableView: NSTableView {
  var onFocusChanged: (() -> Void)?

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result { onFocusChanged?() }
    return result
  }

  override func keyDown(with event: NSEvent) {
    guard let pane = enclosingFinderPane else {
      super.keyDown(with: event)
      return
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    switch event.keyCode {
    case 49:  // Space
      if flags.isEmpty {
        pane.toggleQuickLook()
        return
      }
    case 36, 76:  // Return / numpad enter
      if flags.isEmpty {
        pane.openSelectedRow()
        return
      }
    case 51:  // Delete / Backspace — go up, matches Finder
      if flags.isEmpty {
        pane.goUp()
        return
      }
    case 124:  // Right arrow — enter selected
      if flags.isEmpty {
        pane.openSelectedRow()
        return
      }
    case 123:  // Left arrow — go up
      if flags.isEmpty {
        pane.goUp()
        return
      }
    default:
      break
    }

    if flags.isEmpty, let chars = event.characters {
      switch chars {
      case "h":
        pane.goUp()
        return
      case "j":
        pane.moveSelectionRelative(by: 1)
        return
      case "k":
        pane.moveSelectionRelative(by: -1)
        return
      case "l":
        pane.openSelectedRow()
        return
      case "g":
        pane.selectAbsoluteRow(0)
        return
      default:
        break
      }
    }

    // `G` always arrives with the shift modifier set (it's the
    // shift-applied form of `g`), so it can't share the
    // `flags.isEmpty` branch above. Match exactly `.shift` so plain
    // shift+G triggers but ⌘⇧G / ⌃⇧G stay free for other handlers.
    if flags == .shift, event.characters == "G" {
      pane.selectAbsoluteRow(pane.lastRowIndex)
      return
    }

    super.keyDown(with: event)
  }

  private var enclosingFinderPane: FinderPaneView? {
    var view: NSView? = self
    while let v = view {
      if let pane = v as? FinderPaneView { return pane }
      view = v.superview
    }
    return nil
  }
}

extension FinderPaneView {
  fileprivate func openSelectedRow() { openSelected() }
  fileprivate func moveSelectionRelative(by offset: Int) { moveSelection(by: offset) }
  fileprivate func selectAbsoluteRow(_ row: Int) { selectRow(row) }
  fileprivate var lastRowIndex: Int { max(0, items.count - 1) }
}

// MARK: - Status Bar View

/// 22pt strip along the bottom of a finder pane. Matches Finder's
/// status bar: item count on quiescent selection, selection count when
/// rows are highlighted, and volume free space on the trailing side.
@MainActor
private final class FinderStatusBar: NSView {
  private let label = NSTextField(labelWithString: "")
  private let freeSpaceLabel = NSTextField(labelWithString: "")

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor(white: 0.08, alpha: 1.0).cgColor

    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false

    freeSpaceLabel.font = .systemFont(ofSize: 11)
    freeSpaceLabel.textColor = .tertiaryLabelColor
    freeSpaceLabel.alignment = .right
    freeSpaceLabel.translatesAutoresizingMaskIntoConstraints = false

    addSubview(label)
    addSubview(freeSpaceLabel)

    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),

      freeSpaceLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      freeSpaceLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  func update(totalCount: Int, selectedCount: Int, availableBytes: Int64?) {
    if selectedCount > 0 {
      label.stringValue = "\(selectedCount) of \(totalCount) selected"
    } else {
      label.stringValue = "\(totalCount) item\(totalCount == 1 ? "" : "s")"
    }
    if let bytes = availableBytes {
      freeSpaceLabel.stringValue = "\(Self.byteFormatter.string(fromByteCount: bytes)) available"
    } else {
      freeSpaceLabel.stringValue = ""
    }
  }

  // FinderStatusBar is MainActor-isolated, so the static formatter
  // inherits the same isolation; no `nonisolated` needed.
  private static let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    // Match Finder: zero free space (rare but possible on a full
    // volume) renders as "0 bytes" / "0 バイト" rather than "Zero KB".
    f.allowsNonnumericFormatting = false
    return f
  }()
}
