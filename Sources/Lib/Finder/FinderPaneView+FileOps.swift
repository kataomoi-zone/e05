import AppKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "FinderPane")

/// Filesystem operations triggered from the right-click context
/// menu and the command palette beyond rename / new-folder / trash:
/// Duplicate (this file) and forthcoming Make Alias / Compress /
/// New Folder with Selection. Each operation logs per-item failures
/// and continues so a permission error on one entry doesn't abort
/// the rest of the batch — same convention as `trashSelection`.
extension FinderPaneView {
  // MARK: - Duplicate

  /// Copy every selected entry alongside the original under a
  /// `<name> copy[.ext]` suffix, matching Finder's ⌘D. Subsequent
  /// duplicates of the same source escalate to `<name> copy 2.ext`,
  /// `<name> copy 3.ext`, … until a free slot opens. The new entries
  /// are selected after the reload so the user can immediately
  /// Rename / Trash / duplicate-again without hunting through the
  /// table. Directories duplicate recursively via `copyItem(at:to:)`.
  public func duplicateSelection() {
    let urls = tableView.selectedRowIndexes.compactMap { idx -> URL? in
      idx < items.count ? items[idx].url : nil
    }
    guard !urls.isEmpty else { return }
    let plans: [(source: URL, target: URL)] = urls.map { source in
      (source, duplicateTargetURL(for: source))
    }
    runCopyBatch(plans: plans, label: "Duplicate")
  }

  /// Resolve the next available `<name> copy[.ext]` slot in `source`'s
  /// parent directory. Almost always collides — Duplicate's source
  /// nearly by definition already exists — so this routes straight
  /// to `availableCopyURL`.
  private func duplicateTargetURL(for source: URL) -> URL {
    availableCopyURL(
      in: source.deletingLastPathComponent(),
      stem: source.deletingPathExtension().lastPathComponent,
      ext: source.pathExtension)
  }

  // MARK: - Shared helpers

  /// Run a batch of `(source → target)` filesystem copies off the
  /// main actor, then return to MainActor to refresh the table and
  /// select the new entries. Both Duplicate and Paste route through
  /// here so the threading model and post-copy UI flow stay in one
  /// place.
  ///
  /// `Task.detached` is what keeps the pane responsive during a
  /// multi-GB or cross-volume copy. APFS same-volume copies
  /// short-circuit to `clonefile(2)` inside `FileManager` and finish
  /// instantly, but cross-volume / HFS+ paths block until the bytes
  /// are actually written — and `FinderPaneView` is `@MainActor`,
  /// so a synchronous `copyItem` would freeze every other pane on
  /// the same window. A per-`Task` `FileManager()` keeps Sendable
  /// strictness happy and avoids sharing the global default's
  /// delegate slot across tasks.
  func runCopyBatch(plans: [(source: URL, target: URL)], label: String) {
    Task.detached(priority: .userInitiated) {
      let fm = FileManager()
      var done: [URL] = []
      for plan in plans {
        do {
          try fm.copyItem(at: plan.source, to: plan.target)
          done.append(plan.target)
        } catch {
          logger.error(
            "\(label, privacy: .public) failed \(plan.source.path, privacy: .public) → \(plan.target.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      }
      guard !done.isEmpty else { return }
      await MainActor.run { [weak self] in
        self?.finishCopyBatch(targets: done)
      }
    }
  }

  /// Reload the table and select every newly produced entry.
  /// Selection lookup matches by `lastPathComponent` rather than the
  /// full URL because the directory monitor re-enumerates entries
  /// via `FileManager.enumerator`, whose trailing-slash and
  /// percent-encoding choices may not round-trip with the URLs the
  /// copy plan composed via `appendingPathComponent` — `Rename.swift`
  /// ducks the same drift the same way after `createNewFolder`.
  /// A directory's immediate children have unique names, so
  /// last-component matching is unambiguous.
  private func finishCopyBatch(targets: [URL]) {
    reloadItems(preservingSelection: false)
    var rows = IndexSet()
    for url in targets {
      let name = url.lastPathComponent
      if let idx = items.firstIndex(where: { $0.url.lastPathComponent == name }) {
        rows.insert(idx)
      }
    }
    if let first = rows.first {
      tableView.selectRowIndexes(rows, byExtendingSelection: false)
      tableView.scrollRowToVisible(first)
    }
  }

  /// Resolve the next free `<stem> copy[.ext]` slot inside `dir`,
  /// escalating to `<stem> copy 2.ext`, `<stem> copy 3.ext`, … on
  /// collision. Shared by Duplicate (which always collides) and
  /// Paste (which falls through here only when its preferred
  /// `<source-name>` target is taken). `URL.pathExtension` returns
  /// `""` for dotfiles like `.zshrc` (Foundation treats the leading
  /// dot as the stem), so the extensionless branch handles both
  /// extensionless and dotfile inputs without a separate guard.
  func availableCopyURL(in dir: URL, stem: String, ext: String) -> URL {
    let fm = FileManager.default

    func candidate(_ baseStem: String) -> URL {
      ext.isEmpty
        ? dir.appendingPathComponent(baseStem)
        : dir.appendingPathComponent("\(baseStem).\(ext)")
    }

    var url = candidate("\(stem) copy")
    if !fm.fileExists(atPath: url.path(percentEncoded: false)) { return url }
    var n = 2
    while true {
      url = candidate("\(stem) copy \(n)")
      if !fm.fileExists(atPath: url.path(percentEncoded: false)) { return url }
      n += 1
    }
  }
}
