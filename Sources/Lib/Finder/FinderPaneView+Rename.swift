import AppKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "FinderPane")

/// Captured state for an in-flight inline rename. The URL identifies
/// the file under edit; `originalName` retains the on-disk name so
/// the commit path can short-circuit a no-op rename (user types
/// nothing or types back the original) without re-deriving the name
/// from `items` — the latter would race a filesystem event that
/// drops the entry between begin and end editing. `mode` records the
/// presentation the rename was started under so the end-edit path
/// restores the right cell even if the user flipped modes mid-edit
/// (defensive — `setViewMode` already cancels the rename, but the
/// extra grounding makes the appearance restore robust against
/// future mode-change paths).
struct RenameSession {
  let url: URL
  let originalName: String
  let mode: FinderViewMode
}

/// Write-side operations on filesystem entries: inline rename, new
/// folder creation, and Move-to-Trash. All three interact with the
/// field editor and with the directory monitor's debounced reload
/// loop, so their coordination lives together even though they're
/// invoked from distinct key / menu paths.
extension FinderPaneView {
  // MARK: - Inline rename

  /// Hand the selected entry's name off to the field editor for
  /// inline rename. No-op when nothing is selected, when a rename is
  /// already in flight, or when the cell view can't be materialised
  /// (the entry scrolled off-screen and the reuse pool is empty).
  ///
  /// Bound to Return / numpad-Enter on both presentation views so
  /// Finder's `↵ = rename` convention applies while double-click,
  /// Right arrow, and vim-`l` keep the open-entry affordances —
  /// mirroring Finder list-view key assignments.
  public func beginRename() {
    guard !isRenaming, let url = firstSelectedURL,
      let item = items.first(where: { $0.url == url })
    else { return }
    switch currentMode {
    case .list:
      beginListRename(at: item)
    case .icon:
      beginIconRename(at: item)
    }
  }

  /// Exit an in-flight rename session as if the user pressed ESC: the
  /// field editor's edited value is discarded, the cell reloads from
  /// `items`, and the originating presentation reclaims first
  /// responder. No-op when no rename is in flight.
  ///
  /// Clearing `renameSession` before `reloadItems` is what makes this
  /// safe: the cell replacement detaches the field editor and posts
  /// `controlTextDidEndEditing`, but its commit branch bails on the
  /// `guard isRenaming` so the edited text never reaches `moveItem`.
  /// Mirrors the ESC path in `control(_:textView:doCommandBy:)` below;
  /// used by `FinderTableView.menu(for:)` /
  /// `FinderIconCollectionView.rightMouseDown` so right-clicking
  /// during rename cancels the edit (matching Finder's behaviour)
  /// before the context menu is built.
  public func cancelRenameIfActive() {
    guard let session = renameSession else { return }
    renameSession = nil
    if session.mode == .icon {
      restoreIconCellAppearance(for: session.url)
    }
    reloadItems(preservingSelection: true)
    if let window = window {
      window.makeFirstResponder(keyboardFocusTarget)
    }
  }

  // MARK: - List-mode rename

  private func beginListRename(at item: FileItem) {
    guard let row = items.firstIndex(where: { $0.url == item.url }) else { return }
    guard
      let nameColumnIndex = tableView.tableColumns.firstIndex(where: {
        $0.identifier == Self.nameColumn
      })
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
    renameSession = RenameSession(url: item.url, originalName: item.name, mode: .list)
    tableView.editColumn(nameColumnIndex, row: row, with: nil, select: true)
    // Force a synchronous redraw so the field editor renders in the
    // same run-loop tick it was attached. `editColumn` hides the
    // cell's own textField immediately but the field editor doesn't
    // paint until the next drawing pass — that 1-frame gap is the
    // dark rectangle that flashed under the new folder's row on the
    // first createNewFolder → beginRename path.
    tableView.window?.displayIfNeeded()
  }

  // MARK: - Icon-mode rename

  /// Engage the icon-view cell's name label as the rename field.
  /// The label was created via `NSTextField(labelWithString:)` for
  /// display, so it starts non-editable and non-selectable; this
  /// helper flips it into a usable single-line editor and hands
  /// first responder over so the field editor binds to the cell.
  private func beginIconRename(at item: FileItem) {
    guard let idx = items.firstIndex(where: { $0.url == item.url }) else { return }
    let path = IndexPath(item: idx, section: 0)
    iconCollectionView.scrollToItems(at: [path], scrollPosition: .centeredVertically)
    // Same layout-flush rationale as the list-view path: a cold
    // recycle pool can defer the cell's first paint past the
    // `makeFirstResponder` below, leaving the field editor binding
    // to a not-yet-laid-out text field.
    iconCollectionView.window?.layoutIfNeeded()
    layoutSubtreeIfNeeded()
    iconCollectionView.layoutSubtreeIfNeeded()
    guard let cell = iconCollectionView.item(at: path) as? FinderIconItem,
      let textField = cell.textField
    else { return }
    cell.beginRenameMode(initialName: item.name, delegate: self)
    renameSession = RenameSession(url: item.url, originalName: item.name, mode: .icon)
    guard let window = textField.window,
      window.makeFirstResponder(textField)
    else {
      // First-responder transition refused (cell layout incomplete
      // or another responder claimed the chain). Roll back the
      // appearance flip and the session capture so the next
      // `beginRename` invocation isn't blocked by a stale
      // `renameSession` and the cell doesn't sit in editing visuals
      // without an attached field editor.
      cell.endRenameMode()
      renameSession = nil
      return
    }
    // Pre-select the stem (everything before the last extension)
    // so the user can type a replacement immediately — Finder uses
    // the same selection on rename engage.
    if let editor = textField.currentEditor() as? NSTextView {
      let name = item.name
      let stemEnd = (name as NSString).range(of: ".", options: .backwards).location
      if stemEnd == NSNotFound || stemEnd == 0 {
        editor.selectAll(nil)
      } else {
        editor.selectedRange = NSRange(location: 0, length: stemEnd)
      }
    }
  }

  /// Tear down the icon cell's edit-mode appearance for the URL the
  /// session was attached to. Looks the cell up via `iconCollectionView.item(at:)`
  /// — the cell may have been recycled if the user scrolled it off-
  /// screen during the edit, in which case the next `reloadAllRows`
  /// in the cancel/commit path lands a fresh non-editing cell anyway.
  func restoreIconCellAppearance(for url: URL) {
    guard let idx = items.firstIndex(where: { $0.url == url }) else { return }
    let path = IndexPath(item: idx, section: 0)
    if let cell = iconCollectionView.item(at: path) as? FinderIconItem {
      cell.endRenameMode()
    }
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
    while fm.fileExists(atPath: currentURL.appendingPathComponent(name).path(percentEncoded: false))
    {
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
    FinderUndoCenter.registerNewFolder(at: target, in: self)
    // `selectAfterLoad` matches by `lastPathComponent` rather than by
    // `URL` equality: `appendingPathComponent(name)` and the URL that
    // `FileManager.enumerator` hands back can differ on trailing
    // slash, percent-encoding, or symlink resolution. A directory's
    // immediate children have unique names, so last-component
    // matching is safe and resilient.
    //
    // The completion runs after the off-main reload's apply, so by
    // the time `beginRename` fires the new row is already selected.
    // Defer the rename itself by 50 ms so the menu bar / command
    // palette that triggered this action has finished closing — a
    // plain run-loop tick can still overlap with their final focus /
    // layout events and the end-of-edit notification they emit can
    // collapse the rename session immediately after it starts.
    reloadItems(preservingSelection: false, selectAfterLoad: [target]) { [weak self] in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        MainActor.assumeIsolated { self?.beginRename() }
      }
    }
  }

  // MARK: - New Folder with Selection

  /// Create `untitled folder` (or `untitled folder N` on collision)
  /// in the current cwd, move every selected entry into it, then
  /// drop straight into rename mode on the new folder — matching
  /// Finder's "New Folder with Selection (N Items)". Per-item move
  /// failures log and continue; the user gets back a partially
  /// populated folder rather than nothing.
  ///
  /// Move is `FileManager.moveItem(at:to:)`, which preserves inode
  /// and metadata when source and destination share the same
  /// volume. The selected entries' parent is `currentURL`, so the
  /// new folder is on the same filesystem and the move is the
  /// same instant rename it would be inside Finder.
  public func newFolderWithSelection() {
    let urls = selectedURLs
    guard !urls.isEmpty else { return }
    let fm = FileManager.default
    let base = "untitled folder"
    var name = base
    var suffix = 2
    while fm.fileExists(atPath: currentURL.appendingPathComponent(name).path(percentEncoded: false))
    {
      name = "\(base) \(suffix)"
      suffix += 1
    }
    let target = currentURL.appendingPathComponent(name)
    do {
      // `withIntermediateDirectories: false` makes a TOCTOU collision
      // (some other writer raced us to `name` between the walk and
      // here) throw rather than silently merge into an existing
      // directory; the collision walk above almost always avoids it.
      try fm.createDirectory(at: target, withIntermediateDirectories: false)
    } catch {
      logger.error(
        "Failed to create new folder at \(target.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return
    }
    var moves: [(origin: URL, destination: URL)] = []
    for source in urls {
      let dest = target.appendingPathComponent(source.lastPathComponent)
      do {
        try fm.moveItem(at: source, to: dest)
        moves.append((source, dest))
      } catch {
        logger.error(
          "Move into new folder \(source.path, privacy: .public) → \(dest.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    reportOperationFailure(
      succeeded: moves.count, total: urls.count, verbPhrase: "moved into folder")
    FinderUndoCenter.registerNewFolderWithSelection(
      folder: target, moves: moves, in: self)
    // Same `selectAfterLoad` + delayed `beginRename` chain as
    // `createNewFolder` — see its comment for the rationale on the
    // last-component match and the menu-close vs field-editor race.
    reloadItems(preservingSelection: false, selectAfterLoad: [target]) { [weak self] in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        MainActor.assumeIsolated { self?.beginRename() }
      }
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
    let urls = selectedURLs
    guard !urls.isEmpty else { return }
    var pairs: [(origin: URL, trashed: URL)] = []
    // Count successes independently of `pairs`: `trashItem` can
    // succeed yet leave `resultingItemURL` nil, which keeps the entry
    // out of `pairs` (no undo URL) but it's still a successful trash,
    // so the failure toast mustn't report it as a casualty.
    var succeeded = 0
    for url in urls {
      var resulting: NSURL?
      do {
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        succeeded += 1
        if let resulting = resulting as URL? {
          pairs.append((url, resulting))
        }
      } catch {
        logger.error(
          "Failed to trash \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    if !pairs.isEmpty {
      FinderUndoCenter.registerTrash(pairs: pairs, in: self)
    }
    reportOperationFailure(
      succeeded: succeeded, total: urls.count, verbPhrase: "moved to Trash")
    // The directory monitor event that follows will schedule a
    // debounced reload. An explicit reload here would race the
    // monitor and could flash a stale row set; let the debounce
    // layer do its job.
  }

  // MARK: - Failure feedback

  /// Post an `.error` toast summarising a partial / full failure of a
  /// live filesystem op. No-op on full success. The phrasing comes from
  /// the same `partialFailureMessage` helper the undo path uses, with
  /// `actionName: nil` — live ops have no companion success toast to
  /// name. Resolves the container up the responder chain and logs,
  /// never silently drops, when it can't (per-item causes are already
  /// logged at the call site; this keeps a teardown state from hiding
  /// the failure entirely).
  func reportOperationFailure(succeeded: Int, total: Int, verbPhrase: String) {
    guard succeeded < total else { return }
    let message = FinderUndoCenter.partialFailureMessage(
      actionName: nil, succeeded: succeeded, total: total, verbPhrase: verbPhrase)
    guard let container = window?.contentViewController as? PaneContainerViewController else {
      logger.error(
        "Operation-failure toast dropped: container unresolved (\(message, privacy: .public))")
      return
    }
    container.showToast(message, style: .error)
  }
}

// MARK: - NSTextFieldDelegate

extension FinderPaneView: NSTextFieldDelegate {
  /// Intercept the ESC key while the field editor is attached.
  /// AppKit's default `cancelOperation` path does **not** always
  /// fire `controlTextDidEndEditing` on macOS — the field editor
  /// tears down directly and the rename session would be left
  /// non-nil, blocking the next `beginRename` via its `guard` check.
  /// Handling the selector explicitly lets us reset state and
  /// return first responder to the active presentation so a
  /// subsequent ↵ engages rename again. `insertNewline:` is also
  /// intercepted because the icon-mode rename text field uses
  /// `wraps = true` for multi-line display, which makes AppKit's
  /// default `insertNewline:` insert a literal newline rather than
  /// commit.
  public func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy commandSelector: Selector
  ) -> Bool {
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      // Icon mode's rename text field uses `wraps = true` /
      // `usesSingleLineMode = false` so long filenames flow across
      // multiple lines while editing. AppKit's default `insertNewline:`
      // for that configuration inserts a literal newline rather than
      // committing — move first responder onto the active
      // presentation directly. The field editor resigns, the
      // textField commits, `controlTextDidEndEditing` fires, and the
      // collection / table view picks up keyboard focus in one
      // synchronous step.
      //
      // Routing via `makeFirstResponder(nil)` first instead races the
      // commit sequence: the outer `makeFirstResponder(nil)` finishes
      // *after* `controlTextDidEndEditing`'s `defer` re-points focus
      // at the icon view, leaving first responder pinned at `nil`
      // and the menu-bar Edit > Undo item disabled (visible as "⌘Z
      // does nothing right after a rename, works after clicking the
      // empty area").
      control.window?.makeFirstResponder(keyboardFocusTarget)
      return true
    }
    guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
      return false
    }
    let session = renameSession
    renameSession = nil
    if let textField = control as? NSTextField {
      textField.delegate = nil
    }
    if let session, session.mode == .icon {
      restoreIconCellAppearance(for: session.url)
    }
    // Revert the display from the field editor's working copy to
    // whatever the items array says — matches ESC cancel semantics.
    reloadItems(preservingSelection: true)
    if let window = window {
      window.makeFirstResponder(keyboardFocusTarget)
    }
    return true
  }

  /// Fires when the field editor detaches via the commit path (↵
  /// / focus loss). The ESC cancel path is routed through
  /// `control(_:textView:doCommandBy:)` above and never reaches
  /// here, so this handler only needs to cover commits.
  public func controlTextDidEndEditing(_ notification: Notification) {
    guard let session = renameSession,
      let textField = notification.object as? NSTextField
    else { return }
    let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    renameSession = nil
    // `isEditable` / `isSelectable` stay `true` on the list cell:
    // flipping them back to `false` between edits leaves the cell's
    // field-editor bindings in an intermediate state that intermittently
    // refuses the next `editColumn`. `delegate` is safe to clear so
    // a spurious end-editing notification from a recycled cell's
    // field editor doesn't re-enter this handler.
    textField.delegate = nil
    if session.mode == .icon {
      restoreIconCellAppearance(for: session.url)
    }

    defer {
      // After the field editor tears down, first responder can end up
      // parked on the window itself instead of cascading back to the
      // active presentation — keyDown for ↵ / ⌘⌫ then never reaches
      // the keyboard handler. Explicitly re-installing the active
      // view as first responder restores the keyboard navigation,
      // matching what Finder's rename flow does on ESC / ↵.
      if let window = window {
        window.makeFirstResponder(keyboardFocusTarget)
      }
    }

    let oldURL = session.url
    guard !newName.isEmpty, newName != session.originalName else {
      // No change or empty name — revert the display. The field
      // editor may have left the text field's stringValue in an
      // intermediate state, so a reload re-seeds every cell from
      // `items` and clears any lingering edit artifacts.
      //
      // Comparing against `session.originalName` (captured at begin)
      // rather than the current `items` row is robust to a
      // filesystem event that drops the entry between begin and
      // end editing — the no-op short-circuit still fires for
      // identical input, and a real rename hits `moveItem` which
      // will surface a meaningful error if the source is gone.
      reloadItems(preservingSelection: true)
      return
    }
    let target = currentURL.appendingPathComponent(newName)
    do {
      try FileManager.default.moveItem(at: oldURL, to: target)
    } catch {
      logger.error(
        "Rename failed \(oldURL.path, privacy: .public) → \(newName, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      // A forward rename that collides (target name reoccupied) or
      // hits a permission error would otherwise be silent — the name
      // just snaps back with no explanation.
      reportOperationFailure(succeeded: 0, total: 1, verbPhrase: "renamed")
      reloadItems(preservingSelection: true)
      return
    }
    FinderUndoCenter.registerRename(from: oldURL, to: target, in: self)
    // `selectAfterLoad` highlights the renamed row once the off-main
    // reload's apply lands; matching by `lastPathComponent` is
    // equivalent to URL equality here because the rename target
    // lives in `currentURL` and has a unique name in that dir.
    reloadItems(preservingSelection: false, selectAfterLoad: [target])
  }
}
