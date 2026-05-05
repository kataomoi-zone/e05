import AppKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "FinderPane")

/// Pasteboard interop for the finder pane. Each selected entry is
/// written as `NSURL`, which the AppKit pasteboard machinery
/// promises in both the file-URL and string-URL flavours — that's
/// what makes a paste interoperate with Finder (⌘V / ⌘⌥V), with
/// drop targets that bind to `kPasteboardTypeFileURL`, and with
/// terminal panes that consume the path as text. The Paste side
/// reverses the flow: it reads file URLs from the same pasteboard
/// and copies them into the current cwd, escalating to
/// `<name> copy[.ext]` on collision so a same-cwd paste mirrors
/// Duplicate's outcome rather than refusing.
extension FinderPaneView {
  // MARK: - Copy

  public func copySelectionToPasteboard() {
    let urls = tableView.selectedRowIndexes.compactMap { idx -> URL? in
      idx < items.count ? items[idx].url : nil
    }
    guard !urls.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects(urls as [NSURL])
  }

  // MARK: - Paste

  /// Number of file URLs currently on the general pasteboard. The
  /// context menu uses this for the `Paste Item` / `Paste N Items`
  /// label and to grey the entry out when nothing pasteable is
  /// available.
  func pasteableFileURLCount() -> Int {
    let pb = NSPasteboard.general
    let urls = pb.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]) as? [URL]
    return urls?.count ?? 0
  }

  /// Copy each file URL on the general pasteboard into the current
  /// cwd. The preferred target keeps the source name; collisions
  /// escalate to `<stem> copy[.ext]` via the shared
  /// `availableCopyURL` helper — that mirrors Finder's "Keep Both"
  /// outcome rather than its modal Replace dialog. Failures log and
  /// continue per-item, matching `trashSelection` /
  /// `duplicateSelection` conventions.
  ///
  /// Newly pasted entries are selected after the reload so the user
  /// can immediately Rename / Trash / duplicate-again. The actual
  /// copies run off-main via `runCopyBatch` so a multi-GB or
  /// cross-volume paste doesn't freeze the pane.
  public func pasteFromPasteboard() {
    let pb = NSPasteboard.general
    guard
      let sources = pb.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]) as? [URL],
      !sources.isEmpty
    else { return }
    let plans: [(source: URL, target: URL)] = sources.map { source in
      (source, pasteTargetURL(for: source))
    }
    runCopyBatch(plans: plans, label: "Paste")
  }

  /// Try `currentURL/<source-name>` first; on collision escalate
  /// to the `<stem> copy[.ext]` slot. Pasting into the source's
  /// own directory therefore behaves like Duplicate, which is what
  /// Finder does when the user pastes a same-cwd clipboard entry.
  private func pasteTargetURL(for source: URL) -> URL {
    let primary = currentURL.appendingPathComponent(source.lastPathComponent)
    if !FileManager.default.fileExists(atPath: primary.path(percentEncoded: false)) {
      return primary
    }
    return availableCopyURL(
      in: currentURL,
      stem: source.deletingPathExtension().lastPathComponent,
      ext: source.pathExtension)
  }
}
