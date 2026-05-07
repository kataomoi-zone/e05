import AppKit

/// Find-bar adapter for finder panes. Conforms to the same
/// `FindHelper` protocol as browser / terminal panes so the shared
/// `FindBarView` controller doesn't need to branch on pane kind, but
/// the semantics are different: browser / terminal find highlights
/// glyphs in place and walks next/previous matches, finder find
/// narrows the visible row list to the entries whose names match
/// the needle. Local to the current cwd — system-wide Spotlight is
/// out of scope.
extension FinderPaneView: FindHelper {
  public var supportsStepping: Bool { false }

  public func performFind(
    _ needle: String,
    forward _: Bool,
    completion: @escaping @MainActor ((total: Int, current: Int)) -> Void
  ) {
    guard !needle.isEmpty else {
      endFind()
      completion((total: 0, current: 0))
      return
    }
    filterNeedle = needle
    items = applyFilterIfActive(mergeWithInFlightOverlay(lastLoadedItems))
    tableView.reloadData()
    updateStatusBar()
    // Highlight the first match so arrow-key navigation continues
    // from the visible result set, mirroring how Finder's filter
    // mode lands focus on the first hit.
    if !items.isEmpty {
      tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      tableView.scrollRowToVisible(0)
    }
    // The find bar's `forward` axis carries no meaning for a row
    // filter — there's no "next match" to step through, the result
    // *is* the visible list. Report `current = 1` whenever there's
    // at least one hit so the bar's "1 of N" indicator reflects
    // what the user is looking at.
    let total = items.count
    completion((total: total, current: total > 0 ? 1 : 0))
  }

  public func endFind() {
    // Already inactive — `items` already reflects the unfiltered
    // merged list, so skip the redundant rebuild + `reloadData`.
    guard filterNeedle != nil else { return }
    filterNeedle = nil
    items = applyFilterIfActive(mergeWithInFlightOverlay(lastLoadedItems))
    tableView.reloadData()
    updateStatusBar()
  }
}
