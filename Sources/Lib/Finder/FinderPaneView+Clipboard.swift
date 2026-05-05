import AppKit

/// Pasteboard interop for the finder pane. Each selected entry is
/// written as `NSURL`, which the AppKit pasteboard machinery
/// promises in both the file-URL and string-URL flavours — that's
/// what makes a paste interoperate with Finder (⌘V / ⌘⌥V), with
/// drop targets that bind to `kPasteboardTypeFileURL`, and with
/// terminal panes that consume the path as text.
extension FinderPaneView {
  public func copySelectionToPasteboard() {
    let urls = tableView.selectedRowIndexes.compactMap { idx -> URL? in
      idx < items.count ? items[idx].url : nil
    }
    guard !urls.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects(urls as [NSURL])
  }
}
