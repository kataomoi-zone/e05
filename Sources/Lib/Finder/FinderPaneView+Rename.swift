import AppKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "FinderPane")

/// Write-side operations on filesystem entries: inline rename, new
/// folder creation, and Move-to-Trash. All three interact with the
/// field editor and with the directory monitor's debounced reload
/// loop, so their coordination lives together even though they're
/// invoked from distinct key / menu paths.
extension FinderPaneView {
  // MARK: - Inline rename

  /// Hand the selected row's Name column off to the field editor for
  /// inline rename. No-op when nothing is selected, when a rename is
  /// already in flight, or when the cell view can't be materialised
  /// (the row scrolled off-screen and the reuse pool is empty).
  ///
  /// Bound to Return / numpad-Enter on the table view so Finder's
  /// `↵ = rename` convention applies while double-click, Right arrow,
  /// and vim-`l` keep the open-entry affordances — mirroring Finder
  /// list-view key assignments.
  public func beginRename() {
    guard !isRenaming,
      let row = tableView.selectedRowIndexes.first,
      row < items.count
    else { return }
    guard let nameColumnIndex = tableView.tableColumns.firstIndex(where: { $0.identifier == Self.nameColumn })
    else { return }
    // `editColumn` silently no-ops unless the table is first responder
    // — invocations routed via the menu bar / command palette leave
    // first responder parked on the window (new folder's ⌘⇧N is the
    // visible symptom). Reclaim it explicitly so rename engages on
    // every trigger, not just the keyDown path where the table is
    // already focused.
    if let window = tableView.window, window.firstResponder !== tableView {
      window.makeFirstResponder(tableView)
    }
    tableView.scrollRowToVisible(row)
    // Flush the full layout tree up to the window root. The
    // pane-local + tableView-local passes alone miss the cascade
    // through scrollView / clipView that a fresh `reloadItems` kicks
    // off on a cold cell-view reuse pool — that cascade was the
    // extra async pass racing `editColumn` on the first rename
    // after `createNewFolder` (subsequent renames hit warm cells
    // and laid out in one pass, which is why the flash only
    // appeared once per session).
    tableView.window?.layoutIfNeeded()
    layoutSubtreeIfNeeded()
    tableView.layoutSubtreeIfNeeded()
    guard
      let cellView = tableView.view(atColumn: nameColumnIndex, row: row, makeIfNecessary: true)
        as? NSTableCellView,
      let textField = cellView.textField
    else { return }
    textField.delegate = self
    isRenaming = true
    renamingRow = row
    tableView.editColumn(nameColumnIndex, row: row, with: nil, select: true)
    // Force a synchronous redraw so the field editor renders in the
    // same run-loop tick it was attached. `editColumn` hides the
    // cell's own textField immediately but the field editor doesn't
    // paint until the next drawing pass — that 1-frame gap is the
    // dark rectangle that flashed under the new folder's row on the
    // first createNewFolder → beginRename path.
    tableView.window?.displayIfNeeded()
  }

  // MARK: - New folder

  /// Create `untitled folder` (or `untitled folder N` on collision) in
  /// the current cwd and drop straight into rename mode, matching
  /// Finder's ⌘⇧N flow. The directory-monitor reload-debounce picks
  /// up the write as a side effect, so the explicit reload here is
  /// primarily for the synchronous "select the row, start editing"
  /// path that needs the new item resolvable before `beginRename`.
  public func createNewFolder() {
    let fm = FileManager.default
    let base = "untitled folder"
    var name = base
    var suffix = 2
    while fm.fileExists(atPath: currentURL.appendingPathComponent(name).path(percentEncoded: false)) {
      name = "\(base) \(suffix)"
      suffix += 1
    }
    let target = currentURL.appendingPathComponent(name)
    do {
      try fm.createDirectory(at: target, withIntermediateDirectories: false)
    } catch {
      logger.error(
        "Failed to create new folder at \(target.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return
    }
    reloadItems(preservingSelection: false)
    // Match by `lastPathComponent` rather than by `URL` equality:
    // `appendingPathComponent(name)` and the URL that
    // `FileManager.enumerator` hands back can differ on trailing
    // slash, percent-encoding, or symlink resolution, so `==` would
    // silently miss the row and bail out before `beginRename` ever
    // ran. A directory's immediate children have unique names, so
    // last-component matching is safe and resilient.
    guard let row = items.firstIndex(where: { $0.url.lastPathComponent == name }) else { return }
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
    // Defer `beginRename` until after the menu bar / command palette
    // that triggered this action has finished closing. A plain
    // `DispatchQueue.main.async` fires on the next run-loop tick
    // which can still overlap with the closing view's final focus /
    // layout events, and the end-of-edit notification they emit can
    // collapse the rename session immediately after it starts. A
    // short delay gives AppKit time to settle before the field
    // editor attaches.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      MainActor.assumeIsolated { self?.beginRename() }
    }
  }

  // MARK: - Move to Trash

  /// Send every selected row to the Trash via
  /// `FileManager.trashItem(at:resultingItemURL:)`. No confirmation
  /// dialog — Finder doesn't show one for ⌘⌫ either, and the OS-level
  /// Undo stack (⌘Z inside Finder, or manually via Trash) is the
  /// recovery path. Failures log and continue so a permission error
  /// on one file doesn't block the rest of the batch.
  public func trashSelection() {
    let urls = tableView.selectedRowIndexes.compactMap { idx -> URL? in
      idx < items.count ? items[idx].url : nil
    }
    guard !urls.isEmpty else { return }
    for url in urls {
      do {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      } catch {
        logger.error(
          "Failed to trash \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    // The directory monitor event that follows will schedule a
    // debounced reload. An explicit reload here would race the
    // monitor and could flash a stale row set; let the debounce
    // layer do its job.
  }
}

// MARK: - NSTextFieldDelegate

extension FinderPaneView: NSTextFieldDelegate {
  /// Intercept the ESC key while the field editor is attached.
  /// AppKit's default `cancelOperation` path does **not** always
  /// fire `controlTextDidEndEditing` on macOS — the field editor
  /// tears down directly and our `isRenaming` flag would be left
  /// `true`, blocking the next `beginRename` via its `guard` check.
  /// Handling the selector explicitly lets us reset state and
  /// return first responder to the table so a subsequent ↵ engages
  /// rename again. `insertNewline:` falls through to AppKit so the
  /// normal end-editing path still posts `controlTextDidEndEditing`
  /// for the commit branch.
  public func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy commandSelector: Selector
  ) -> Bool {
    guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
      return false
    }
    isRenaming = false
    renamingRow = nil
    if let textField = control as? NSTextField {
      textField.delegate = nil
    }
    // Revert the display from the field editor's working copy to
    // whatever the items array says — matches ESC cancel semantics.
    reloadItems(preservingSelection: true)
    if let window = tableView.window {
      window.makeFirstResponder(tableView)
    }
    return true
  }

  /// Fires when the field editor detaches via the commit path (↵
  /// / focus loss). The ESC cancel path is routed through
  /// `control(_:textView:doCommandBy:)` above and never reaches
  /// here, so this handler only needs to cover commits.
  public func controlTextDidEndEditing(_ notification: Notification) {
    guard isRenaming, let textField = notification.object as? NSTextField else { return }
    let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let row = renamingRow ?? -1
    isRenaming = false
    renamingRow = nil
    // `isEditable` / `isSelectable` stay `true`: flipping them back to
    // `false` between edits leaves the cell's field-editor bindings in
    // an intermediate state that intermittently refuses the next
    // `editColumn`. `delegate` is safe to clear so a spurious
    // end-editing notification from a recycled cell's field editor
    // doesn't re-enter this handler.
    textField.delegate = nil

    defer {
      // After the field editor tears down, first responder can end up
      // parked on the window itself instead of cascading back to the
      // table — keyDown for ↵ / ⌘⌫ then never reaches
      // `FinderTableView.keyDown`. Explicitly re-installing the table
      // as first responder restores the keyboard navigation, matching
      // what Finder's list-view rename flow does on ESC / ↵.
      if let window = tableView.window {
        window.makeFirstResponder(tableView)
      }
    }

    guard row >= 0, row < items.count else {
      reloadItems(preservingSelection: true)
      return
    }
    let oldItem = items[row]
    guard !newName.isEmpty, newName != oldItem.name else {
      // No change or empty name — revert the display. The field
      // editor may have left the text field's stringValue in an
      // intermediate state, so a reload re-seeds every cell from
      // `items` and clears any lingering edit artifacts.
      reloadItems(preservingSelection: true)
      return
    }
    let target = currentURL.appendingPathComponent(newName)
    do {
      try FileManager.default.moveItem(at: oldItem.url, to: target)
    } catch {
      logger.error(
        "Rename failed \(oldItem.url.path, privacy: .public) → \(newName, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      reloadItems(preservingSelection: true)
      return
    }
    reloadItems(preservingSelection: false)
    if let newRow = items.firstIndex(where: { $0.url == target }) {
      tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
      tableView.scrollRowToVisible(newRow)
    }
  }
}
