import AppKit

/// Recursive size measurement for package rows (.app, .bundle) in the list
/// view's Size column. A package reports no `fileSize` of its own —
/// `fileSizeKey` is 0 for the bundle directory — so without this every app
/// in a folder like /Applications renders as "0 bytes". Sizes are walked
/// off the main actor (`totalSize`, shared with the copy progress bar)
/// and cached by URL; each row's Size cell refreshes as its size lands, the
/// way Finder fills the column in after a brief "--".
extension FinderPaneView {
  /// Size-column text. A package shows its recursively-measured size once
  /// the off-main pass has it and "--" until then — never the inode's 0
  /// bytes. Plain files and folders defer to `FileItem.displaySize`.
  func sizeDisplay(for item: FileItem) -> String {
    guard item.isPackage else { return item.displaySize }
    guard let size = packageSizes[item.url] else { return "--" }
    return FileItem.formattedSize(size)
  }

  /// Walk every not-yet-measured package's recursive size off the main
  /// actor and fill `packageSizes`, refreshing each row's Size cell as its
  /// size lands. A no-op outside list view (the Size column isn't shown in
  /// icon view) and for directories with no packages. Cancels any prior
  /// walk so a rapid reload / navigation abandons it; the per-result
  /// `currentURL` guard drops writes once the pane has navigated away.
  func computePackageSizes() {
    packageSizeTask?.cancel()
    guard currentMode == .list else { return }
    let pending = items.filter { $0.isPackage && packageSizes[$0.url] == nil }
      .map { $0.url }
    guard !pending.isEmpty else { return }

    let snapshotURL = currentURL
    packageSizeTask = Task.detached(priority: .utility) {
      for url in pending {
        if Task.isCancelled { return }
        let size = FinderPaneView.totalSize(of: url)
        // A real package always tallies > 0 (its bundle directory alone has
        // a non-zero size); a 0 means the package became unreadable —
        // deleted or permission-denied mid-walk. Leave it "--" rather than
        // caching a misleading "0 bytes" (a same-directory reload won't
        // re-measure a cached entry, so a wrong 0 would otherwise stick).
        guard size > 0 else { continue }
        await MainActor.run { [weak self] in
          guard let self, self.currentURL == snapshotURL else { return }
          self.packageSizes[url] = size
          self.refreshSizeCell(forURL: url)
        }
      }
    }
  }

  /// Repaint a single row's Size cell after its package size is measured,
  /// leaving the rest of the table untouched. No-op in icon view or when
  /// the row has scrolled out of `items` (e.g. a concurrent reload).
  private func refreshSizeCell(forURL url: URL) {
    guard currentMode == .list,
      let row = items.firstIndex(where: { $0.url == url })
    else { return }
    let sizeColumn = tableView.column(withIdentifier: Self.sizeColumn)
    guard sizeColumn >= 0 else { return }
    tableView.reloadData(
      forRowIndexes: IndexSet(integer: row),
      columnIndexes: IndexSet(integer: sizeColumn))
  }
}
