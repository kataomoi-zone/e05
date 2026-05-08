import AppKit

/// Row-level actions and the internal surface `FinderTableView` /
/// `FinderIconCollectionView` use to forward key events. The members
/// here are `internal`, visible within the E05Lib module to the two
/// presentation views but not part of the pane's external contract.
///
/// Each navigation helper branches on `currentMode` so the same
/// keyDown call site (`h`/`l`/`g`/`G` / Return / Right / Left)
/// behaves identically whether the pane is showing the list or the
/// icon grid. Linear-index movement (`j`/`k` row stepping) intentionally
/// stays list-only — a 2D grid doesn't have a natural "next row"
/// without a column count, and AppKit's default arrow-key handling
/// already covers grid nav in icon mode.
extension FinderPaneView {
  @objc func doubleClickAction(_ sender: Any?) {
    let row = tableView.clickedRow
    guard row >= 0, row < items.count else { return }
    navigate(to: items[row].url)
  }

  func openSelectedRow() {
    guard let url = firstSelectedURL else { return }
    navigate(to: url)
  }

  /// Step the selection by `offset` in linear `items` order. List
  /// mode only — the icon grid's keyDown leaves arrow handling to
  /// AppKit so 2D nav (left/right between columns) works out of the
  /// box.
  func moveSelectionRelative(by offset: Int) {
    guard !items.isEmpty else { return }
    let current = tableView.selectedRow
    let next = max(0, min(items.count - 1, current + offset))
    tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
    tableView.scrollRowToVisible(next)
  }

  /// Jump selection to absolute index `row`. Routes through the
  /// URL-keyed selection helper so both presentations land on the
  /// same entry — vim `g` / `G` and `selectFirst` / `selectLast`
  /// share this surface.
  func selectAbsoluteRow(_ row: Int) {
    guard row >= 0, row < items.count else { return }
    selectAndScroll(toURL: items[row].url)
  }

  /// Alias used by the keyDown handlers for ↵ / ↵-numpad. Shares the
  /// public `beginRename()` surface — the variant name exists so the
  /// key-handler call site reads as "begin rename on current entry"
  /// rather than as a bare `beginRename`.
  func beginRenameEntry() { beginRename() }

  /// Used by the keyDown handlers for shift-G (jump to last row).
  var lastRowIndex: Int { max(0, items.count - 1) }
}
