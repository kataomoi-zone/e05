import AppKit

/// System share-sheet integration for the finder pane. The
/// selection's file URLs are handed to `NSSharingServicePicker` —
/// the same controller Finder uses for AirDrop / Mail / Messages
/// / Notes / Reminders / etc. — so the popover that pops up matches
/// what the user already gets in Finder, including any third-party
/// share extensions they've enabled in System Settings.
extension FinderPaneView {
  /// Present the share-sheet popover anchored at the first selected
  /// row. Multi-select hands every URL to the picker; the chosen
  /// service then decides whether to bundle them (Mail attaches all
  /// in one draft) or treat them per-item (Notes creates separate
  /// cards) — the same dispatch Finder shows.
  public func shareSelection() {
    let urls = selectedURLs
    guard !urls.isEmpty else { return }
    // The picker is intentionally a local: `show(relativeTo:…)`
    // installs it inside the popover's retain graph, so the popover
    // keeps it alive without us holding a stored reference. If we
    // ever set `delegate` on this picker we'll need to promote it
    // to a stored property — `NSSharingServicePicker.delegate` is
    // weak and the local would dangle once this method returns.
    let picker = NSSharingServicePicker(items: urls)
    let (rect, view) = sharePickerAnchor()
    // `.maxY` mirrors Finder (popover below the row, arrow up) and
    // sidesteps the narrow-pane case where `.maxX` would bump the
    // popover into a fallback edge that overlaps the file list.
    picker.show(relativeTo: rect, of: view, preferredEdge: .maxY)
  }

  /// Resolve the popover anchor: the first selected row's rect when
  /// it's laid out, otherwise the whole table. Falling back to the
  /// table keeps the popover visible even if a right-click hit a
  /// row that scrolled off-screen between the menu opening and the
  /// service being chosen.
  private func sharePickerAnchor() -> (rect: NSRect, view: NSView) {
    guard let row = tableView.selectedRowIndexes.first else {
      return (tableView.bounds, tableView)
    }
    let rect = tableView.rect(ofRow: row)
    if rect.isEmpty {
      return (tableView.bounds, tableView)
    }
    return (rect, tableView)
  }
}
