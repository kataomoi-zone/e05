import AppKit

/// Drag source for finder panes. Returning an `NSURL` from
/// `pasteboardWriterForRow:` is the entire contract — AppKit
/// auto-handles the multi-row case (each selected row's writer is
/// collected into one pasteboard), the mouse-threshold gesture that
/// starts the drag, and the system drop animations. Recipients that
/// accept `.fileURL` (Finder, editors, Dock, other e05 panes) receive
/// the selection as file references.
///
/// Drops that target a finder pane are handled separately; this file
/// is intentionally source-only.
extension FinderPaneView {
  public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
    guard row >= 0, row < items.count else { return nil }
    return items[row].url as NSURL
  }
}
