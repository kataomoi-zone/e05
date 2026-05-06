import AppKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "FinderPane")

/// Directory model concerns: navigation (back / forward / up),
/// filesystem enumeration with the global hidden-files filter, the
/// debounced reload loop driven by `DirectoryMonitor`, sort state,
/// icon caching, and status-bar refresh. Every mutation of `items`,
/// `currentURL`, and the navigation stacks lives here so the data
/// source / delegate / rename extensions can treat them as read-only
/// snapshots at the moment they query them.
extension FinderPaneView {
  // MARK: - Navigation

  /// Navigate to `url`. Non-directories are dispatched to
  /// `NSWorkspace.shared.open(_:)` so clicking a file in the list opens
  /// it in the system-default application, matching Finder.
  ///
  /// Finder aliases (bookmark files written via `writeBookmarkData`
  /// with `.suitableForBookmarkFile`) are resolved before the
  /// directory check: `resolvingSymlinksInPath` leaves them alone
  /// because they're not symlinks, and `NSWorkspace.open` would
  /// otherwise hand directory aliases to the system Finder instead
  /// of jumping inside the pane. `URLResourceKey.isAliasFileKey` is
  /// the modern way to detect them; `URL(resolvingAliasFileAt:options:)`
  /// follows the bookmark to the live target.
  public func navigate(to url: URL) {
    var target = url
    if let values = try? url.resourceValues(forKeys: [.isAliasFileKey]),
      values.isAliasFile == true,
      let aliasTarget = try? URL(resolvingAliasFileAt: url, options: [])
    {
      target = aliasTarget
    }
    let resolved = target.resolvingSymlinksInPath()
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

  /// Reload and select every row whose `lastPathComponent` matches
  /// one of `targetURLs`. Used by undo/redo handlers so a multi-
  /// select restoration (5 trashed entries brought back) lights
  /// up all 5 rows the same way the forward action did. An empty
  /// array reloads without any selection — useful when the undo
  /// action's targets aren't in the cwd (e.g. trashing dropped
  /// them outside the visible tree).
  public func reloadItemsAndSelect(at targetURLs: [URL]) {
    reloadItems(preservingSelection: false)
    guard !targetURLs.isEmpty else { return }
    let names = Set(targetURLs.map { $0.lastPathComponent })
    var rows = IndexSet()
    for (idx, item) in items.enumerated()
    where names.contains(item.url.lastPathComponent) {
      rows.insert(idx)
    }
    if let first = rows.first {
      tableView.selectRowIndexes(rows, byExtendingSelection: false)
      tableView.scrollRowToVisible(first)
    }
  }

  // MARK: - Directory load + reload

  func loadDirectory(url: URL, pushHistory: Bool, announce: Bool) {
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

  func scheduleDebouncedReload() {
    // Suppress monitor-driven reloads while the Name column's text
    // field is the field editor's client. A reload would drop the
    // cell view mid-keystroke, ending the edit session and losing
    // unsaved input. The post-rename explicit `reloadItems` call
    // inside `controlTextDidEndEditing` picks up the `moveItem`'s
    // directory-monitor event idempotently.
    guard !isRenaming else { return }
    pendingReload?.cancel()
    let work = DispatchWorkItem { [weak self] in
      // Re-check at execution time: rename can start inside the
      // debounce window (createNewFolder's inotify event is scheduled
      // first, then `beginRename` fires 50ms later via asyncAfter, so
      // the work block wakes up 100ms in with `isRenaming = true` and
      // would otherwise blow the field editor off the cell).
      guard let self, !self.isRenaming else { return }
      self.reloadItems(preservingSelection: true)
    }
    pendingReload = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.reloadDebounceInterval, execute: work)
  }

  func reloadItems(preservingSelection: Bool) {
    // Evict alias entries from the icon cache: a Finder alias is
    // designed to track its source through renames and moves, so
    // the source's icon may have changed since we last resolved it.
    // Non-alias rows keep their cached icons — Launch Services
    // resolves the same icon from the same path until the row is
    // replaced wholesale.
    iconCache = iconCache.filter { url, _ in
      let isAlias = (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true
      return !isAlias
    }

    let previouslySelectedURLs: [URL] =
      preservingSelection
      ? tableView.selectedRowIndexes.compactMap { idx in
        idx < items.count ? items[idx].url : nil
      }
      : []

    // Honour the global hidden-files toggle every reload: the setting
    // can flip between a cwd's first load and a directory-monitor
    // burst reload, so baking the options once at init would leave
    // open panes out of sync with the current preference.
    var options: FileManager.DirectoryEnumerationOptions =
      [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
    if !FinderSettings.showHiddenFiles {
      options.insert(.skipsHiddenFiles)
    }
    var loaded: [FileItem] = []
    if let enumerator = FileManager.default.enumerator(
      at: currentURL,
      includingPropertiesForKeys: Array(FileItem.resourceKeys),
      options: options
    ) {
      for case let url as URL in enumerator {
        loaded.append(FileItem(url: url))
      }
    }

    items = sortItems(loaded)
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

  // MARK: - Sort

  /// Order items for display. Finder's list view sorts purely by the
  /// active key with no directory grouping — a folder named `bin`
  /// appears between `bash` and `cat` under a Name ascending sort,
  /// not pulled to the top. Mirror that behaviour: delegate entirely
  /// to `compareByCurrentKey`, with no separate directory tier.
  func sortItems(_ items: [FileItem]) -> [FileItem] {
    items.sorted(by: compareByCurrentKey)
  }

  /// Return `true` iff `a` should precede `b` under the active sort.
  /// `NSSortDescriptor` itself can't drive this comparison because
  /// `FileItem` is a plain Swift class without `@objc` keypath
  /// bindings; the delegate callback reads the descriptor's `key`
  /// string, maps it back to `SortKey`, and dispatches here so the
  /// comparison logic lives fully in Swift.
  func compareByCurrentKey(_ a: FileItem, _ b: FileItem) -> Bool {
    switch currentSortKey {
    case .name:
      let result = a.name.localizedStandardCompare(b.name)
      return sortAscending ? result == .orderedAscending : result == .orderedDescending
    case .dateModified:
      // `.distantPast` is the smallest representable Date, so rows
      // without a modification date (broken metadata, permission
      // errors) surface at the **top** of an ascending sort (oldest
      // first) and at the **bottom** of a descending one. Treating
      // nil as "very old" is how Finder handles missing timestamps.
      let da = a.dateModified ?? .distantPast
      let db = b.dateModified ?? .distantPast
      return sortAscending ? da < db : da > db
    case .size:
      // Finder's Size column groups folders together: the column
      // renders "--" for directories since their byte size isn't
      // meaningful, and both sort directions keep the folder cluster
      // intact. Ascending puts the cluster at the top, descending at
      // the bottom — folders always sit at whichever end an
      // "unknown size" maps to. Modelling non-package directory size
      // as `Int64.min` makes folders the smallest value in the key
      // space; a name-ascending tiebreaker keeps the cluster's
      // internal alphabetical order (`bin → deno → …`) identical
      // regardless of the direction applied to the surrounding files.
      // The same tiebreaker applies to any pair with equal effective
      // size (e.g. multiple 0-byte files) — Finder breaks same-size
      // ties the same way.
      let aIsDir = a.isDirectory && !a.isPackage
      let bIsDir = b.isDirectory && !b.isPackage
      let sa = aIsDir ? Int64.min : a.size
      let sb = bIsDir ? Int64.min : b.size
      if sa != sb {
        return sortAscending ? sa < sb : sa > sb
      }
      return a.name.localizedStandardCompare(b.name) == .orderedAscending
    case .kind:
      let result = a.kind.localizedStandardCompare(b.kind)
      return sortAscending ? result == .orderedAscending : result == .orderedDescending
    }
  }

  // MARK: - Icon cache

  /// Resolve the icon for `item`, consulting the visible-row cache
  /// first. `NSWorkspace.shared.icon(forFile:)` goes through Launch
  /// Services — the same resolution path Finder uses for package
  /// icons and custom icons set via Get Info.
  ///
  /// Finder aliases need a manual hop: on macOS 26 both
  /// `effectiveIcon` and `NSWorkspace.icon(forFile:)` return the
  /// generic alias-file document icon for the bookmark file itself,
  /// rather than the source's icon. Resolving the alias and asking
  /// Launch Services about the source path puts the right icon back
  /// on the row (folder alias → folder icon, markdown alias →
  /// markdown icon). On top of the resolved icon we composite a
  /// small SF Symbol arrow badge in the bottom-left quadrant — Finder
  /// uses a private system resource for its alias overlay that
  /// AppKit doesn't expose, so a SF Symbol approximation is the
  /// closest public-API match. Without it, an alias and its source
  /// would render with byte-identical icons. The cached `NSImage`
  /// is a fresh composite for aliases (a bare Launch Services icon
  /// for everything else); never mutate its `.size`, the image view
  /// handles sizing via `.scaleProportionallyDown` and a 16pt frame.
  func iconForRow(_ item: FileItem) -> NSImage {
    if let cached = iconCache[item.url] { return cached }
    let isAlias = (try? item.url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true
    let iconSource: URL
    if isAlias,
      let resolved = try? URL(
        resolvingAliasFileAt: item.url,
        options: [.withoutMounting, .withoutUI])
    {
      iconSource = resolved
    } else {
      iconSource = item.url
    }
    let base = NSWorkspace.shared.icon(forFile: iconSource.path(percentEncoded: false))
    let image = isAlias ? Self.aliasBadgedIcon(base: base) : base
    iconCache[item.url] = image
    return image
  }

  /// Draw a Finder-style alias arrow in the bottom-left quadrant of
  /// `base`. The badge is an `arrow.up.right.circle.fill` SF Symbol
  /// rendered with a palette image style — white circle behind a
  /// dark arrow — so it stays legible against folder, document, and
  /// app icons alike. The composite is sized to match `base` so the
  /// table-cell image view can `.scaleProportionallyDown` it without
  /// recomputing geometry per row.
  private static func aliasBadgedIcon(base: NSImage) -> NSImage {
    let size = base.size
    guard size.width > 0, size.height > 0 else { return base }
    let composite = NSImage(size: size)
    composite.lockFocus()
    base.draw(
      at: .zero, from: NSRect(origin: .zero, size: size),
      operation: .copy, fraction: 1.0)
    let badge = NSImage(
      systemSymbolName: "arrow.up.right.circle.fill",
      accessibilityDescription: "Alias"
    )?.withSymbolConfiguration(
      NSImage.SymbolConfiguration(paletteColors: [.black, .white]))
    badge?.draw(
      in: NSRect(x: 0, y: 0, width: size.width * 0.5, height: size.height * 0.5),
      from: .zero, operation: .sourceOver, fraction: 1.0)
    composite.unlockFocus()
    return composite
  }

  // MARK: - Status bar

  func updateStatusBar() {
    let selected = tableView.selectedRowIndexes
    var available: Int64?
    if let values = try? currentURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
      let bytes = values.volumeAvailableCapacityForImportantUsage
    {
      available = bytes
    }
    statusBar.update(totalCount: items.count, selectedCount: selected.count, availableBytes: available)
  }
}
