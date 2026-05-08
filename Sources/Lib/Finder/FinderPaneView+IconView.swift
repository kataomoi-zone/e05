import AppKit
import QuickLookThumbnailing
import QuickLookUI

/// Icon-grid presentation for `FinderPaneView`. The collection view
/// is a sibling to the list view's `tableView`, sharing the same
/// `items` array as data source so a directory load / sort / filter
/// runs once and both views render against the same snapshot. Mode
/// switching just flips `isHidden` on the two scroll views — no data
/// re-fetch, and the active view's `reloadData` picks up the current
/// `items` lazily.
///
/// Hidden-file dim, alias overlay, and in-flight greyed placeholder
/// rendering ride on `FinderIconItem`'s appearance state, written
/// from `applyAppearanceState(_:to:)` on every cell recycle so a
/// recycled cell starts from the correct state for its new file.
extension FinderPaneView: NSCollectionViewDataSource {
  public func collectionView(
    _ collectionView: NSCollectionView, numberOfItemsInSection section: Int
  ) -> Int {
    items.count
  }

  public func collectionView(
    _ collectionView: NSCollectionView,
    itemForRepresentedObjectAt indexPath: IndexPath
  ) -> NSCollectionViewItem {
    let cell = collectionView.makeItem(
      withIdentifier: FinderIconItem.identifier, for: indexPath)
    guard indexPath.item < items.count else { return cell }
    let fileItem = items[indexPath.item]
    cell.imageView?.image = displayImage(for: fileItem)
    cell.textField?.stringValue = fileItem.name
    if let iconCell = cell as? FinderIconItem {
      applyAppearanceState(fileItem, to: iconCell)
    }
    return cell
  }

  /// Image to display in the cell's image view. Combines the QuickLook
  /// thumbnail (when cached) with the alias overlay so a Finder alias
  /// to an image renders the source's preview with the corner badge —
  /// `iconForRow` already handles the badge for the icon-fallback
  /// path, but the cached thumbnail bypasses it.
  func displayImage(for item: FileItem) -> NSImage {
    let base = thumbnailForRow(item)
    if base === iconForRow(item) {
      return base
    }
    let isAlias = (try? item.url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true
    return isAlias ? Self.aliasBadgedIconExternal(base: base) : base
  }

  /// Push the current hidden / in-flight state onto a cell. Called
  /// from `itemForRepresentedObjectAt` on every recycle so a
  /// re-purposed cell starts from the correct visual state for its
  /// new file rather than carrying the previous occupant's flags.
  /// Tracker / settings notifications go through
  /// `refreshInFlightOverlay` → `reloadAllRows`, which routes back
  /// through the same data-source callback.
  ///
  /// Also strips a leftover rename-mode appearance from a recycled
  /// cell whose previous occupant was the rename target. The edit
  /// affordances (editable text field, border, background) would
  /// otherwise leak onto the new file's render until the next
  /// rename engagement reset them.
  func applyAppearanceState(_ item: FileItem, to cell: FinderIconItem) {
    cell.dimmed = item.isHidden
    cell.inFlight = inFlightURLs.contains(item.url)
    if cell.editing && renameSession?.url != item.url {
      cell.endRenameMode()
    }
  }
}

extension FinderPaneView: NSCollectionViewDelegate {
  public func collectionView(
    _ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>
  ) {
    handleIconSelectionChange()
  }

  public func collectionView(
    _ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>
  ) {
    handleIconSelectionChange()
  }

  /// Cancel the thumbnail fetch for a cell that has scrolled out of
  /// the viewport. Without this hook a fast scroll over a large
  /// directory leaves QuickLook chewing through stale fetches in
  /// dispatch order, so the cells visible at the new scroll
  /// position have to wait behind every cell briefly visible during
  /// the scroll.
  public func collectionView(
    _ collectionView: NSCollectionView,
    didEndDisplaying item: NSCollectionViewItem,
    forRepresentedObjectAt indexPath: IndexPath
  ) {
    guard indexPath.item < items.count else { return }
    cancelThumbnailFetch(for: items[indexPath.item].url)
  }

  /// Run the same status-bar / Quick Look refresh the list view's
  /// `tableViewSelectionDidChange` does. Internal rather than
  /// private so `+Selection.swift` can fire it after programmatic
  /// `selectItems(at:scrollPosition:)` calls — AppKit itself does
  /// **not** invoke `collectionView(_:didSelectItemsAt:)` for
  /// programmatic selection, so a paste / undo restore / in-flight
  /// overlay refresh would otherwise leave the status bar stuck on
  /// the pre-selection count.
  func handleIconSelectionChange() {
    updateStatusBar()
    if QLPreviewPanel.sharedPreviewPanelExists(),
      let panel = QLPreviewPanel.shared(), panel.isVisible
    {
      panel.reloadData()
    }
  }
}

extension FinderPaneView {
  /// In-flight bookkeeping for one thumbnail request. Keeps the
  /// QuickLook handle (for `cancel(_:)`) and an identity token in
  /// lockstep so a late completion can identify whether its slot
  /// has already been reissued for the same URL.
  struct ThumbnailFetchHandle {
    let token: UInt64
    let request: QLThumbnailGenerator.Request
  }

  // MARK: - Setup

  func setupIconView() {
    let layout = NSCollectionViewFlowLayout()
    layout.itemSize = FinderIconItem.itemSize
    layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    layout.minimumInteritemSpacing = 8
    layout.minimumLineSpacing = 8

    iconCollectionView.collectionViewLayout = layout
    iconCollectionView.dataSource = self
    iconCollectionView.delegate = self
    iconCollectionView.allowsMultipleSelection = true
    iconCollectionView.allowsEmptySelection = true
    iconCollectionView.isSelectable = true
    iconCollectionView.backgroundColors = [.clear]
    iconCollectionView.register(
      FinderIconItem.self,
      forItemWithIdentifier: FinderIconItem.identifier)

    // Drag-and-drop wiring mirrors the table view: accept file URLs
    // from any source, advertise both move and copy on out-going
    // drags so recipients (Finder, editors, sibling panes) can pick
    // whichever applies — Finder uses move within a volume, copy
    // across volumes, matching what the validate / accept core
    // returns.
    iconCollectionView.registerForDraggedTypes([.fileURL, .URL])
    iconCollectionView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
    iconCollectionView.setDraggingSourceOperationMask([.move, .copy], forLocal: false)

    iconCollectionView.onFocusChanged = { [weak self] in
      self?.onFocusChanged?()
    }
    iconCollectionView.onItemDoubleClick = { [weak self] indexPath in
      guard let self, indexPath.item < self.items.count else { return }
      self.navigate(to: self.items[indexPath.item].url)
    }

    iconScrollView.documentView = iconCollectionView
    iconScrollView.hasVerticalScroller = true
    iconScrollView.hasHorizontalScroller = false
    iconScrollView.autohidesScrollers = true
    iconScrollView.drawsBackground = false
    iconScrollView.translatesAutoresizingMaskIntoConstraints = false

    registerLiveScrollObservers()
  }

  /// Hook the icon scroll view's live-scroll notifications so the
  /// thumbnail-fetch path can defer scheduling while the user is
  /// scrolling and pick up only the final visible set after motion
  /// settles. `didEndLiveScrollNotification` is documented to fire
  /// after **all** animation finishes (drag release plus any
  /// momentum), so a single `isLiveScrolling` flag covers the full
  /// "user is moving" window without tracking momentum separately.
  private func registerLiveScrollObservers() {
    let center = NotificationCenter.default
    liveScrollWillStartObserver = center.addObserver(
      forName: NSScrollView.willStartLiveScrollNotification,
      object: iconScrollView,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.isLiveScrolling = true
        self.pendingThumbnailScheduling?.cancel()
        self.pendingThumbnailScheduling = nil
      }
    }
    liveScrollDidEndObserver = center.addObserver(
      forName: NSScrollView.didEndLiveScrollNotification,
      object: iconScrollView,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.isLiveScrolling = false
        self.scheduleVisibleThumbnailsAfterDebounce()
      }
    }
  }

  // MARK: - Mode switching

  /// Switch the active view mode and persist the choice for
  /// `currentURL`. Selection round-trips through `selectedURLs` so
  /// the user keeps the same files highlighted across the swap.
  /// Returns whether the mode actually changed — callers may still
  /// fire a confirmation toast on a no-op (matching the menu-action
  /// convention of always acknowledging the user's intent), but the
  /// store write and the visibility flip are skipped.
  @discardableResult
  public func setViewMode(_ mode: FinderViewMode) -> Bool {
    guard mode != currentMode else { return false }
    // Drop an in-flight rename: the field editor is bound to a cell
    // whose presentation is about to be hidden, and AppKit doesn't
    // post `controlTextDidEndEditing` reliably when the host view
    // becomes hidden out from under the editor.
    cancelRenameIfActive()
    let preserved = selectedURLs
    let wasFirstResponder = (window?.firstResponder as? NSView)
      .map { $0.isDescendant(of: self) } ?? false
    let leavingIconMode = (currentMode == .icon)

    currentMode = mode
    applyViewModeVisibility()
    // Drop pending QuickLook work when the icon view is no longer
    // visible. `cancel(_:)` doesn't preempt running fetches but it
    // clears the queue and stops any later completions from writing
    // into a cache the user has navigated past.
    if leavingIconMode {
      cancelAllThumbnailFetches()
    }
    reloadAllRows()
    selectRows(byURLs: preserved)
    FinderModeStore.shared.setMode(mode, for: currentURL)

    // Move first-responder onto the now-visible view so palette /
    // menu invocations don't leave keyboard focus on a hidden table
    // (or a hidden collection view going the other way). Only when
    // the focus was *already* inside this pane — switching mode on
    // a background pane shouldn't steal focus away from wherever the
    // user is actually working.
    if wasFirstResponder {
      window?.makeFirstResponder(keyboardFocusTarget)
    }
    return true
  }

  /// Re-read the persisted mode for `currentURL` and apply if
  /// different. Triggered by `FinderModeStore.didChangeNotification`
  /// so that toggling mode in pane A propagates to pane B that's
  /// showing the same directory. The notification is coarse (no
  /// `userInfo`), so every open finder pane runs this on every
  /// store mutation; the early-return on equal modes keeps the
  /// fan-out free of redundant reload churn.
  func resyncViewModeFromStore() {
    let stored = FinderModeStore.shared.mode(for: currentURL)
    guard stored != currentMode else { return }
    // Same rationale as `setViewMode`: a remote pane's view-mode
    // change is about to hide the cell the field editor is bound to.
    cancelRenameIfActive()
    let preserved = selectedURLs
    let leavingIconMode = (currentMode == .icon)
    currentMode = stored
    applyViewModeVisibility()
    if leavingIconMode {
      cancelAllThumbnailFetches()
    }
    reloadAllRows()
    selectRows(byURLs: preserved)
  }

  /// Reflect `currentMode` onto the two scroll views. Called from
  /// init, mode switch, navigation, and the cross-pane resync — the
  /// single source of truth so the visibility invariant
  /// (`scrollView.isHidden ⇔ currentMode == .icon`) is preserved
  /// without hand-rolled toggles at each call site.
  func applyViewModeVisibility() {
    scrollView.isHidden = (currentMode != .list)
    iconScrollView.isHidden = (currentMode != .icon)
  }

  // MARK: - Thumbnails

  /// Pixel size requested from QuickLook. Matches the 48pt icon
  /// cell exactly (×2 backing scale = 96 pixels), so QuickLook isn't
  /// asked for more pixels than `NSImageView` will draw. A future
  /// zoomable cell size can dial this up at the same time as the
  /// cell artwork.
  static let thumbnailSize = NSSize(width: 48, height: 48)

  /// Quiet window after a live scroll ends before a batch fetch
  /// fires. Long enough that a quick re-scroll cancels the pending
  /// work without firing wasted requests, short enough that a
  /// settled user sees thumbnails arrive promptly.
  static let thumbnailFetchDebounce: TimeInterval = 0.2

  /// Resolve the icon image for a row in icon mode. Directories
  /// (non-package) skip QuickLook entirely — Launch Services already
  /// returns the same folder icon, so the fetch would burn an XPC
  /// round-trip without changing the pixels. Files return the cached
  /// thumbnail when present, falling back to the Launch Services
  /// icon while a fetch is pending. New schedules are skipped while
  /// the scroll view is in live-scroll: a fast pass over a 4k-item
  /// directory would otherwise queue thousands of fetch + cancel
  /// pairs against `QLThumbnailGenerator`. The post-scroll debounce
  /// catches up by issuing fetches for the cells that are still
  /// visible once the scroll settles.
  func thumbnailForRow(_ item: FileItem) -> NSImage {
    if item.isDirectory && !item.isPackage {
      return iconForRow(item)
    }
    if let cached = thumbnailCache[item.url] { return cached }
    if !isLiveScrolling {
      scheduleThumbnailFetch(for: item.url)
    }
    return iconForRow(item)
  }

  /// Kick off an async thumbnail fetch for `url`. No-op when the
  /// thumbnail is already cached or a previous fetch for the same
  /// URL is still outstanding, so a cell that scrolls off and back
  /// during the fetch window doesn't trigger a duplicate request.
  /// Each attempt is stamped with a monotonic token so a late
  /// completion from a cancelled or superseded fetch can't clobber
  /// a newer fetch's bookkeeping.
  private func scheduleThumbnailFetch(for url: URL) {
    if thumbnailCache[url] != nil { return }
    if thumbnailFetchInFlight[url] != nil { return }

    thumbnailFetchTokenCounter &+= 1
    let token = thumbnailFetchTokenCounter
    let scale = window?.backingScaleFactor ?? 2.0
    // Ask only for the high-quality thumbnail. `.all` triggers
    // QuickLook to generate icon, low-quality, and high-quality
    // representations even though we only render one, paying the
    // per-cell cost for representations the cell never displays.
    let request = QLThumbnailGenerator.Request(
      fileAt: url,
      size: Self.thumbnailSize,
      scale: scale,
      representationTypes: .thumbnail
    )
    thumbnailFetchInFlight[url] = ThumbnailFetchHandle(token: token, request: request)

    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
      representation, _ in
      // QuickLook fires the completion on its own queue. Hop to
      // MainActor before touching any per-pane state.
      let image = representation?.nsImage
      Task { @MainActor [weak self] in
        self?.applyThumbnail(image, for: url, token: token)
      }
    }
  }

  /// Cancel the in-flight fetch for `url` and drop its bookkeeping.
  /// `didEndDisplaying` calls this for cells leaving the viewport
  /// so QuickLook doesn't keep grinding away on thumbnails the user
  /// won't see; `cancelAllThumbnailFetches` reaches the same path
  /// in bulk for navigation and mode-switch.
  func cancelThumbnailFetch(for url: URL) {
    guard let handle = thumbnailFetchInFlight.removeValue(forKey: url) else { return }
    QLThumbnailGenerator.shared.cancel(handle.request)
  }

  /// Cancel every outstanding fetch and clear the bookkeeping.
  /// Used when navigating to a new directory or leaving icon mode:
  /// any thumbnail still in flight is for a presentation the user
  /// has moved past and would only land in a cache they no longer
  /// look at.
  func cancelAllThumbnailFetches() {
    for handle in thumbnailFetchInFlight.values {
      QLThumbnailGenerator.shared.cancel(handle.request)
    }
    thumbnailFetchInFlight.removeAll(keepingCapacity: true)
  }

  /// Stash the freshly-generated thumbnail and refresh the visible
  /// icon cell. Bails on a stale URL (the user has navigated away
  /// or the entry was deleted) so the next directory's cache stays
  /// clean. Only refreshes the cell when icon mode is the active
  /// presentation; the next mode switch will re-read
  /// `thumbnailCache` through `thumbnailForRow`.
  ///
  /// The `token` parameter discriminates against a late callback
  /// from a cancelled or superseded fetch: only the completion
  /// whose token still matches the dict gets to mutate the cache
  /// or refresh the cell. Otherwise a stale completion arriving
  /// after a cell scrolled off and back would clear the new fetch's
  /// bookkeeping and leave its result orphaned.
  ///
  /// Cell refresh goes through `iconCollectionView.item(at:)?` with
  /// a direct `imageView.image` assignment instead of
  /// `reloadItems(at:)` — `reloadItems` triggers a recycle pass
  /// (`didEndDisplaying` → `willDisplay` → `itemForRepresentedObjectAt`)
  /// for the same cell, which on a freshly-completed fetch sends
  /// the URL through `cancelThumbnailFetch` (no-op, dict already
  /// clear) and re-runs `iconForRow` before resolving from the
  /// cache. Direct assignment skips that round-trip and the layout
  /// work it drags along.
  private func applyThumbnail(_ image: NSImage?, for url: URL, token: UInt64) {
    guard thumbnailFetchInFlight[url]?.token == token else { return }
    thumbnailFetchInFlight.removeValue(forKey: url)
    guard let image else { return }
    guard let idx = items.firstIndex(where: { $0.url == url }) else { return }
    thumbnailCache[url] = image
    guard currentMode == .icon else { return }
    let path = IndexPath(item: idx, section: 0)
    if let cell = iconCollectionView.item(at: path) {
      // Direct assignment skips the recycle round-trip but also
      // skips `displayImage` — re-derive the alias overlay here so
      // a freshly-fetched alias thumbnail gets the corner badge the
      // same way the cold-path data-source callback would.
      cell.imageView?.image = displayImage(for: items[idx])
    }
  }

  /// Arm a debounced job that will issue thumbnail fetches for
  /// every cell still visible once the user has been quiet for
  /// `thumbnailFetchDebounce`. Cancelled and re-armed on each
  /// new live scroll so a flurry of small scrolls only translates
  /// into one batch at the end.
  func scheduleVisibleThumbnailsAfterDebounce() {
    pendingThumbnailScheduling?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.scheduleVisibleThumbnails() }
    }
    pendingThumbnailScheduling = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.thumbnailFetchDebounce, execute: work)
  }

  /// Schedule fetches for every file cell currently in the icon
  /// view's viewport. Idempotent against `thumbnailCache` and
  /// `thumbnailFetchInFlight`, so calling it on a directory whose
  /// thumbnails already loaded is a cheap no-op walk.
  private func scheduleVisibleThumbnails() {
    for indexPath in iconCollectionView.indexPathsForVisibleItems() {
      guard indexPath.item < items.count else { continue }
      let item = items[indexPath.item]
      if item.isDirectory && !item.isPackage { continue }
      scheduleThumbnailFetch(for: item.url)
    }
  }

}
