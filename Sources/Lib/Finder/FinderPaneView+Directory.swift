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
    reloadItems(preservingSelection: false, selectAfterLoad: targetURLs)
  }

  // MARK: - Directory load + reload

  func loadDirectory(url: URL, pushHistory: Bool, announce: Bool) {
    if pushHistory && url != currentURL {
      backStack.append(currentURL)
      forwardStack.removeAll()
    }
    // Discard any in-flight rename whose target lives in the soon-
    // to-be-replaced cwd. The clear-only variant is preferred over
    // `cancelRenameIfActive` here because the surrounding load is
    // about to issue its own `reloadItems` walk; calling cancel
    // would queue a redundant reload against the new cwd.
    renameSession = nil

    currentURL = url
    // View mode is per-directory: navigating into a folder picks up
    // whatever the user last left it in, falling back to `.list`
    // for unseen entries. The visibility flip happens before the
    // empty-state reload below so the active view is the one being
    // populated, not the one about to be hidden.
    let storedMode = FinderModeStore.shared.mode(for: url)
    if storedMode != currentMode {
      currentMode = storedMode
      applyViewModeVisibility()
    }
    // Drop icons from the previous directory — they'd waste memory
    // proportional to navigation depth otherwise. Reloads within the
    // same cwd (directory-monitor events) keep the cache: same URL =
    // same icon, no I/O needed. The thumbnail cache and the in-flight
    // tracker follow the same lifecycle so a stale fetch landing
    // mid-navigation can't pollute the new directory's cells.
    iconCache.removeAll(keepingCapacity: true)
    thumbnailCache.removeAll(keepingCapacity: true)
    cancelAllThumbnailFetches()
    // Show empty state immediately so navigating from a small dir
    // into a 50k-entry one doesn't display the previous dir's items
    // alongside an already-updated URL bar while the off-main walk
    // runs. Reload paths (monitor / manual) keep items visible until
    // the new walk completes — there the cwd is unchanged.
    items = []
    lastLoadedItems = []
    inFlightURLs = []
    // Filter is bound to the cwd it was opened in — carrying the
    // needle across navigate would silently filter the new dir and
    // surprise the user with an empty pane. The find bar itself
    // stays open so a follow-up needle in the new cwd starts
    // immediately, but its session is reset by the
    // `findHelper?.endFind()` that the container's reload path
    // already routes through. Clearing here covers the cases where
    // navigate isn't invoked through that path.
    filterNeedle = nil
    reloadAllRows()
    updateStatusBar()
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

  /// Kick off an off-main enumeration of `currentURL` and apply the
  /// result back on MainActor when it completes. The walk runs in a
  /// `Task.detached` so a 50k-entry tree (`node_modules`, `~/Library`)
  /// doesn't freeze the main thread; cancellation lands on the next
  /// `nextObject()` boundary so abandoning a slow walk (new reload
  /// fired before the old one finished) reclaims the worker promptly.
  ///
  /// `preservingSelection` keeps the current row selection across
  /// the reload (used by manual reload + monitor-driven reloads).
  /// `selectAfterLoad`, when non-nil, takes precedence and selects
  /// the matching `lastPathComponent` rows after the apply (used by
  /// `reloadItemsAndSelect` for undo/redo restoration and by callers
  /// that need to highlight a freshly-created entry).
  /// `completion` runs on MainActor immediately after the apply
  /// (items / selection set), letting callers chain follow-up work
  /// that depends on the reload — e.g. `createNewFolder` schedules
  /// `beginRename` once the new row is selectable. The completion
  /// does **not** fire when the task is cancelled (e.g. the user
  /// navigates away mid-walk); callers must tolerate that path.
  func reloadItems(
    preservingSelection: Bool,
    selectAfterLoad: [URL]? = nil,
    completion: (@Sendable @MainActor () -> Void)? = nil
  ) {
    pendingLoadTask?.cancel()

    let snapshotURL = currentURL
    let key = currentSortKey
    let ascending = sortAscending

    let preserved: [URL] =
      (preservingSelection && selectAfterLoad == nil) ? selectedURLs : []

    // Honour the global hidden-files toggle every reload: the setting
    // can flip between a cwd's first load and a directory-monitor
    // burst reload, so baking the options once at init would leave
    // open panes out of sync with the current preference.
    var options: FileManager.DirectoryEnumerationOptions =
      [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
    if !FinderSettings.showHiddenFiles {
      options.insert(.skipsHiddenFiles)
    }
    let capturedOptions = options
    let toSelect = selectAfterLoad

    pendingLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
      let loaded = Self.enumerate(url: snapshotURL, options: capturedOptions)
      if Task.isCancelled { return }
      let sorted = Self.sortItems(loaded, key: key, ascending: ascending)
      if Task.isCancelled { return }
      await MainActor.run {
        guard let self else { return }
        // Stale-result guard: by the time we hop back, the user may
        // have navigated away. Apply only when the cwd still matches
        // the snapshot we walked, so old enumerations never overwrite
        // newer dirs.
        guard self.currentURL == snapshotURL else { return }
        self.applyLoadedItems(
          sorted, preservedSelection: preserved, selectAfterLoad: toSelect)
        completion?()
      }
    }
  }

  @MainActor
  private func applyLoadedItems(
    _ loaded: [FileItem],
    preservedSelection: [URL],
    selectAfterLoad: [URL]?
  ) {
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

    lastLoadedItems = loaded
    items = applyFilterIfActive(mergeWithInFlightOverlay(loaded))
    reloadAllRows()
    updateStatusBar()

    if let selectAfterLoad, !selectAfterLoad.isEmpty {
      // `selectAfterLoad` URLs are composed via `appendingPathComponent`
      // at the call site; the URLs the enumerator hands back may
      // differ on trailing slash / percent-encoding. Match by
      // `lastPathComponent` instead — directory children are
      // unique by name.
      let names = Set(selectAfterLoad.map { $0.lastPathComponent })
      let matched = items.filter { names.contains($0.url.lastPathComponent) }.map { $0.url }
      if let first = matched.first {
        selectRows(byURLs: matched)
        scrollIntoView(url: first)
      }
    } else if !preservedSelection.isEmpty {
      selectRows(byURLs: preservedSelection)
    }
  }

  /// Merge `loaded` (raw enumerator output) with synthetic
  /// placeholder `FileItem`s for in-flight `FinderOperationTracker`
  /// targets that fall inside `currentURL`. Updates `inFlightURLs`
  /// in lockstep so cell-view / row-view callbacks can render the
  /// dimmed alpha + spinner against the same set used to compose
  /// the rows. Synthetics whose target already appears in `loaded`
  /// (the file finished landing between `register` and the next
  /// reload) are dropped — the real row replaces the placeholder
  /// without any flicker.
  ///
  /// Caller is responsible for keeping `loaded` sorted under the
  /// current `currentSortKey` / `sortAscending` — the no-synthetics
  /// fast path returns it unchanged. `applyLoadedItems` always
  /// passes the off-main task's already-sorted output;
  /// `sortDescriptorsDidChange` keeps `lastLoadedItems` re-sorted
  /// on every header click. The synthetic-merge slow path always
  /// re-sorts from scratch since insertion-into-sorted is O(N) per
  /// item and the typical synthetic count (1-3) makes a full sort
  /// equivalent in practice.
  func mergeWithInFlightOverlay(_ loaded: [FileItem]) -> [FileItem] {
    let cwdTargets = FinderOperationTracker.shared.targetURLs(in: currentURL)
    inFlightURLs = cwdTargets
    guard !cwdTargets.isEmpty else {
      return loaded
    }
    let knownURLs = Set(loaded.map { $0.url })
    let synthetics = cwdTargets.subtracting(knownURLs).map { FileItem(placeholder: $0) }
    if synthetics.isEmpty {
      return loaded
    }
    return Self.sortItems(
      loaded + synthetics, key: currentSortKey, ascending: sortAscending)
  }

  /// Re-render the in-flight overlay against the cached
  /// `lastLoadedItems` snapshot. Triggered by
  /// `FinderOperationTracker.didChangeNotification` so a freshly-
  /// registered op makes its greyed placeholder appear without
  /// re-walking the directory, and a freshly-unregistered op clears
  /// its placeholder the same way.
  func refreshInFlightOverlay() {
    let previouslySelectedURLs = selectedURLs
    items = applyFilterIfActive(mergeWithInFlightOverlay(lastLoadedItems))
    reloadAllRows()
    updateStatusBar()
    selectRows(byURLs: previouslySelectedURLs)
  }

  /// Narrow `merged` to the entries whose names match the active
  /// filter needle (`localizedStandardContains`, locale-aware
  /// case/diacritic-insensitive). Returns `merged` unchanged when
  /// no filter is active so the no-op fast path stays free of
  /// allocations. The filter applies on top of the in-flight
  /// merge, so a synthetic placeholder row whose name matches the
  /// needle stays visible during a filter session — that's the
  /// "I'm filtering and a paste lands" case where seeing the
  /// in-flight target is what the user expected.
  func applyFilterIfActive(_ merged: [FileItem]) -> [FileItem] {
    guard let needle = filterNeedle, !needle.isEmpty else { return merged }
    return merged.filter { $0.name.localizedStandardContains(needle) }
  }

  /// Walk `url` synchronously and return the resulting items. Runs
  /// off the main actor (called from `reloadItems`'s `Task.detached`).
  /// The `nextObject()` manual loop is preferred over
  /// `for case let url as URL in enumerator` so each iteration can
  /// honour `Task.isCancelled` — `for case` would still consume the
  /// next object before the cancel check runs.
  nonisolated static func enumerate(
    url: URL,
    options: FileManager.DirectoryEnumerationOptions
  ) -> [FileItem] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: Array(FileItem.resourceKeys),
        options: options)
    else { return [] }
    var loaded: [FileItem] = []
    while let obj = enumerator.nextObject() {
      if Task.isCancelled { return [] }
      guard let entry = obj as? URL else { continue }
      loaded.append(FileItem(url: entry))
    }
    return loaded
  }

  // MARK: - Sort

  /// Order items for display. Finder's list view sorts purely by the
  /// active key with no directory grouping — a folder named `bin`
  /// appears between `bash` and `cat` under a Name ascending sort,
  /// not pulled to the top. Mirror that behaviour: delegate entirely
  /// to `compare`, with no separate directory tier.
  ///
  /// Nonisolated so the off-main walk in `reloadItems` can sort the
  /// loaded items before hopping back to MainActor; the call site
  /// passes the captured `currentSortKey` / `sortAscending` snapshot.
  nonisolated static func sortItems(
    _ items: [FileItem], key: SortKey, ascending: Bool
  ) -> [FileItem] {
    items.sorted { compare($0, $1, key: key, ascending: ascending) }
  }

  /// Return `true` iff `a` should precede `b` under the given sort
  /// key and direction. `NSSortDescriptor` itself can't drive this
  /// comparison because `FileItem` is a plain Swift class without
  /// `@objc` keypath bindings; the delegate callback reads the
  /// descriptor's `key` string, maps it back to `SortKey`, and
  /// dispatches here so the comparison logic lives fully in Swift.
  nonisolated static func compare(
    _ a: FileItem, _ b: FileItem, key: SortKey, ascending: Bool
  ) -> Bool {
    switch key {
    case .name:
      let result = a.name.localizedStandardCompare(b.name)
      return ascending ? result == .orderedAscending : result == .orderedDescending
    case .dateModified:
      // `.distantPast` is the smallest representable Date, so rows
      // without a modification date (broken metadata, permission
      // errors) surface at the **top** of an ascending sort (oldest
      // first) and at the **bottom** of a descending one. Treating
      // nil as "very old" is how Finder handles missing timestamps.
      let da = a.dateModified ?? .distantPast
      let db = b.dateModified ?? .distantPast
      return ascending ? da < db : da > db
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
        return ascending ? sa < sb : sa > sb
      }
      return a.name.localizedStandardCompare(b.name) == .orderedAscending
    case .kind:
      let result = a.kind.localizedStandardCompare(b.kind)
      return ascending ? result == .orderedAscending : result == .orderedDescending
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
  ///
  /// Internal so the icon-view path (`FinderPaneView+IconView`) can
  /// reuse the same composite for QuickLook-derived thumbnails of
  /// alias files — `iconForRow` only runs for the icon-fallback
  /// path, so a cached thumbnail would otherwise lose the badge.
  static func aliasBadgedIconExternal(base: NSImage) -> NSImage {
    aliasBadgedIcon(base: base)
  }

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
    var available: Int64?
    if let values = try? currentURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
      let bytes = values.volumeAvailableCapacityForImportantUsage
    {
      available = bytes
    }
    statusBar.update(
      totalCount: items.count, selectedCount: selectedURLs.count,
      availableBytes: available)
  }
}
