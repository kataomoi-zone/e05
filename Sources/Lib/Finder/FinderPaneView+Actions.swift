import AppKit

/// Row-level actions and the internal surface `FinderTableView` uses
/// to forward key events. The members here are `internal`, visible
/// within the E05Lib module (to `FinderTableView` specifically) but
/// not part of the pane's external contract.
extension FinderPaneView {
  @objc func doubleClickAction(_ sender: Any?) {
    let row = tableView.clickedRow
    guard row >= 0, row < items.count else { return }
    navigate(to: items[row].url)
  }

  func openSelectedRow() {
    guard let row = tableView.selectedRowIndexes.first, row < items.count else { return }
    navigate(to: items[row].url)
  }

  func moveSelectionRelative(by offset: Int) {
    guard !items.isEmpty else { return }
    let current = tableView.selectedRow
    let next = max(0, min(items.count - 1, current + offset))
    tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
    tableView.scrollRowToVisible(next)
  }

  func selectAbsoluteRow(_ row: Int) {
    guard row >= 0, row < items.count else { return }
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
  }

  /// Alias used by `FinderTableView.keyDown` for ↵ / ↵-numpad. Shares
  /// the public `beginRename()` surface — the variant name exists so
  /// the key-handler call site reads as "begin rename on current
  /// entry" rather than as a bare `beginRename`.
  func beginRenameEntry() { beginRename() }

  /// Used by `FinderTableView.keyDown` for shift-G (jump to last row).
  var lastRowIndex: Int { max(0, items.count - 1) }
}
