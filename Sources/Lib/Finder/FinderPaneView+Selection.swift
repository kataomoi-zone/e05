import AppKit

/// Selection / scroll / reload API exposed in URL-space rather than
/// row-index-space. Callers across the finder pane (rename, find,
/// undo restoration, copy-batch finish, drag-drop, …) operate on
/// "the entry whose URL is X" semantically; the table-row index is
/// an implementation detail of the current presentation. Funnelling
/// through these helpers makes the internals replaceable: when an
/// icon-grid view lands alongside the list view, the bodies here
/// branch on the active mode while every call site stays identical.
///
/// Today every body forwards to `NSTableView` — no behaviour change
/// against the previous direct calls. Their value at this point is
/// (1) the `URL`-keyed signature, which is what callers naturally
/// hold, and (2) consolidating the three-step `reloadData →
/// selectRowIndexes → scrollRowToVisible` sequence into a single
/// `selectAndScroll(toURL:)` so future maintenance touches one
/// surface. Vim-style row navigation (`j`/`k`/`g`/`G`) lives in
/// `+Actions.swift` because those handlers are bound at the table
/// view's keyDown layer and need direct row-index access — they'll
/// migrate once the icon-grid view introduces its own keyDown path.
extension FinderPaneView {
  // MARK: - Selection in URL space

  /// URLs of the rows the user currently has selected. Callers that
  /// previously read `tableView.selectedRowIndexes` and mapped to
  /// `items[idx].url` should reach for this instead — it skips the
  /// out-of-bounds guard the legacy callsites had to repeat.
  public var selectedURLs: [URL] {
    tableView.selectedRowIndexes.compactMap { idx in
      idx < items.count ? items[idx].url : nil
    }
  }

  /// First selected URL in row order, or `nil` when nothing is
  /// selected. Convenience for actions that operate on a single
  /// target (Rename, Get Info) without caring whether multi-select
  /// happened to be active.
  public var firstSelectedURL: URL? {
    tableView.selectedRowIndexes.first.flatMap { idx in
      idx < items.count ? items[idx].url : nil
    }
  }

  // MARK: - Selection mutation

  /// Select the rows whose URLs match `urls`. Out-of-`items` URLs
  /// are silently skipped — the invariant is "select what's there",
  /// matching the prior `restoreSelection(byURLs:)` helper this
  /// surface absorbed. Empty input is a no-op rather than a clear,
  /// also matching the prior helper, so a `reloadData` reload path
  /// that would otherwise pass a possibly-empty preserved set
  /// doesn't churn `tableViewSelectionDidChange` with empty→empty
  /// transitions. Callers that want to actively clear can call
  /// `tableView.deselectAll(nil)` directly; no current site needs
  /// that.
  public func selectRows(byURLs urls: [URL]) {
    guard !urls.isEmpty else { return }
    var rows = IndexSet()
    for url in urls {
      if let idx = items.firstIndex(where: { $0.url == url }) {
        rows.insert(idx)
      }
    }
    if !rows.isEmpty {
      tableView.selectRowIndexes(rows, byExtendingSelection: false)
    }
  }

  /// Select a single URL and scroll it into view. The `selectAndScroll`
  /// shape is what every new-folder / paste / duplicate / rename
  /// commit path needed individually — collapsing them into one call
  /// removes a row of bookkeeping per site.
  public func selectAndScroll(toURL url: URL) {
    guard let idx = items.firstIndex(where: { $0.url == url }) else { return }
    tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
    tableView.scrollRowToVisible(idx)
  }

  /// Scroll the row holding `url` into view without changing the
  /// selection. Used by `applyLoadedItems`'s `selectAfterLoad`
  /// branch, which calls `selectRows(byURLs:)` with N URLs and
  /// then scrolls to the first one — a single
  /// `selectAndScroll(toURL:)` doesn't fit because the call wants
  /// to select multiple rows but scroll to only one.
  public func scrollIntoView(url: URL) {
    guard let idx = items.firstIndex(where: { $0.url == url }) else { return }
    tableView.scrollRowToVisible(idx)
  }

  // MARK: - Reload

  /// Reload the entire row list. Wraps `tableView.reloadData()` so a
  /// future split (list reload vs icon-grid invalidate) can branch
  /// here without touching every caller.
  public func reloadAllRows() {
    tableView.reloadData()
  }
}
