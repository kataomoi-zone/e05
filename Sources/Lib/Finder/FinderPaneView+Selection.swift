import AppKit

/// Selection / scroll / reload API exposed in URL-space rather than
/// row-index-space. Callers across the finder pane (rename, find,
/// undo restoration, copy-batch finish, drag-drop, …) operate on
/// "the entry whose URL is X" semantically; the row / item index is
/// an implementation detail of the current presentation. Funnelling
/// through these helpers makes the internals replaceable: each body
/// branches on `currentMode` so a list-view caller and an icon-view
/// caller share the same surface.
///
/// Vim-style row navigation (`j`/`k`/`g`/`G`) lives in
/// `+Actions.swift` because those handlers are bound at the table
/// view's keyDown layer and need direct row-index access. The
/// icon-grid view relies on `NSCollectionView`'s default arrow-key
/// nav and would need its own keyDown path to reach feature parity.
extension FinderPaneView {
  // MARK: - Selection in URL space

  /// URLs of the rows the user currently has selected. Order in list
  /// mode follows row order; in icon mode the collection view's
  /// `selectionIndexPaths` is unordered, so the helper sorts by item
  /// index before resolving URLs to keep a stable iteration order
  /// for callers that batch-process (Trash, Copy, Compress, …).
  public var selectedURLs: [URL] {
    switch currentMode {
    case .list:
      return tableView.selectedRowIndexes.compactMap { idx in
        idx < items.count ? items[idx].url : nil
      }
    case .icon:
      return iconCollectionView.selectionIndexPaths
        .sorted { $0.item < $1.item }
        .compactMap { ip in
          ip.item < items.count ? items[ip.item].url : nil
        }
    }
  }

  /// First selected URL in row order, or `nil` when nothing is
  /// selected. Convenience for actions that operate on a single
  /// target (Rename, Get Info) without caring whether multi-select
  /// happened to be active.
  public var firstSelectedURL: URL? {
    selectedURLs.first
  }

  // MARK: - Selection mutation

  /// Select the rows whose URLs match `urls`. Out-of-`items` URLs
  /// are silently skipped — the invariant is "select what's there",
  /// matching the prior `restoreSelection(byURLs:)` helper this
  /// surface absorbed. Empty input is a no-op rather than a clear,
  /// also matching the prior helper, so a `reloadData` reload path
  /// that would otherwise pass a possibly-empty preserved set
  /// doesn't churn the selection delegate with empty→empty
  /// transitions. Callers that want to actively clear can call
  /// `deselectAll` on the relevant view directly; no current site
  /// needs that.
  public func selectRows(byURLs urls: [URL]) {
    guard !urls.isEmpty else { return }
    switch currentMode {
    case .list:
      var rows = IndexSet()
      for url in urls {
        if let idx = items.firstIndex(where: { $0.url == url }) {
          rows.insert(idx)
        }
      }
      if !rows.isEmpty {
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
      }
    case .icon:
      var indexPaths: Set<IndexPath> = []
      for url in urls {
        if let idx = items.firstIndex(where: { $0.url == url }) {
          indexPaths.insert(IndexPath(item: idx, section: 0))
        }
      }
      if !indexPaths.isEmpty {
        iconCollectionView.deselectAll(nil)
        iconCollectionView.selectItems(at: indexPaths, scrollPosition: [])
        // `selectItems(at:scrollPosition:)` doesn't fire
        // `collectionView(_:didSelectItemsAt:)`, so the delegate
        // path that normally refreshes the status bar / Quick Look
        // never runs. Hand-fire the same hook to keep parity with
        // the list view, where AppKit triggers
        // `tableViewSelectionDidChange` for programmatic selection.
        handleIconSelectionChange()
      }
    }
  }

  /// Select a single URL and scroll it into view. The `selectAndScroll`
  /// shape is what every new-folder / paste / duplicate / rename
  /// commit path needed individually — collapsing them into one call
  /// removes a row of bookkeeping per site.
  public func selectAndScroll(toURL url: URL) {
    guard let idx = items.firstIndex(where: { $0.url == url }) else { return }
    switch currentMode {
    case .list:
      tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
      tableView.scrollRowToVisible(idx)
    case .icon:
      let indexPaths: Set<IndexPath> = [IndexPath(item: idx, section: 0)]
      iconCollectionView.deselectAll(nil)
      iconCollectionView.selectItems(at: indexPaths, scrollPosition: [])
      iconCollectionView.scrollToItems(at: indexPaths, scrollPosition: .centeredVertically)
      handleIconSelectionChange()
    }
  }

  /// Scroll the row holding `url` into view without changing the
  /// selection. Used by `applyLoadedItems`'s `selectAfterLoad`
  /// branch, which calls `selectRows(byURLs:)` with N URLs and
  /// then scrolls to the first one — a single
  /// `selectAndScroll(toURL:)` doesn't fit because the call wants
  /// to select multiple rows but scroll to only one.
  public func scrollIntoView(url: URL) {
    guard let idx = items.firstIndex(where: { $0.url == url }) else { return }
    switch currentMode {
    case .list:
      tableView.scrollRowToVisible(idx)
    case .icon:
      iconCollectionView.scrollToItems(
        at: [IndexPath(item: idx, section: 0)],
        scrollPosition: .centeredVertically)
    }
  }

  // MARK: - Reload

  /// Reload the entire row list against the active presentation.
  /// The inactive view is left alone — its `numberOfItems` /
  /// `viewFor` is lazy, so the next mode switch's `reloadAllRows`
  /// picks up whatever `items` is at that moment.
  public func reloadAllRows() {
    switch currentMode {
    case .list: tableView.reloadData()
    case .icon: iconCollectionView.reloadData()
    }
  }
}
