import AppKit

/// Surface a Get Info inspector panel for the focused row.
/// Single-select only — Finder shows a separate inspector per
/// target on multi-select, but e05's 1-window discipline (and the
/// fact that aggregate metadata rarely answers a real question)
/// keeps this entry single-target. Multi-select right-clicks omit
/// the entry from the context menu instead of disabling it.
extension FinderPaneView {
  public func showInfoForSelection() {
    guard
      let row = tableView.selectedRowIndexes.first,
      row < items.count
    else { return }
    GetInfoPanel.present(for: items[row].url, near: window)
  }
}
