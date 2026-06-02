import AppKit

/// Right-click / control-click context menu for finder panes.
/// Surfaces row-level actions (Open / Open With / Move to Trash /
/// Get Info / Rename / Compress / Duplicate / Make Alias /
/// Quick Look / Copy / Share) and directory-level actions
/// (New Folder / New Folder with Selection on multi-select).
/// The selection-adjustment logic that decides which menu state to
/// render lives in `FinderTableView.menu(for:)`, which forwards the
/// resolved `clickedRow` to `buildContextMenu(clickedRow:)`.
///
/// Each item carries an SF Symbol leading icon to echo Finder's
/// list-view context menu. Key-equivalent glyphs are intentionally
/// suppressed to match the Finder visual baseline (the underlying
/// actions still respond to their existing keyboard shortcuts via
/// `FinderTableView.keyDown` and the palette).
extension FinderPaneView {
  func buildContextMenu(clickedRow: Int) -> NSMenu {
    let menu = NSMenu()

    if clickedRow < 0 {
      // Empty-area click: keep the current selection untouched (Finder
      // behaviour) and surface only directory-level actions.
      let pasteCount = pasteableFileURLCount()
      let pasteTitle = pasteCount > 1 ? "Paste \(pasteCount) Items" : "Paste Item"
      menu.addItem(
        makeContextMenuItem(
          title: pasteTitle,
          symbolName: "doc.on.clipboard",
          action: pasteCount > 0 ? #selector(contextMenuPaste(_:)) : nil))
      menu.addItem(
        makeContextMenuItem(
          title: "New Folder",
          symbolName: "folder.badge.plus",
          action: #selector(contextMenuNewFolder(_:))))
      menu.addItem(.separator())
      menu.addItem(
        makeContextMenuItem(
          title: "Show in Finder",
          symbolName: "finder",
          action: #selector(contextMenuShowInFinder(_:))))
      return menu
    }

    let urls = selectedURLs
    let count = urls.count
    if count == 1 {
      let name = urls[0].lastPathComponent
      menu.addItem(
        makeContextMenuItem(
          title: "Open",
          symbolName: "arrow.up.forward.square",
          action: #selector(contextMenuOpen(_:))))
      menu.addItem(
        makeContextMenuItem(
          title: "Open With...",
          symbolName: "arrow.up.forward.app",
          action: #selector(contextMenuOpenWith(_:))))
      menu.addItem(
        makeContextMenuItem(
          title: "Show in Finder",
          symbolName: "finder",
          action: #selector(contextMenuShowInFinder(_:))))
      menu.addItem(.separator())
      menu.addItem(
        makeContextMenuItem(
          title: "Move to Trash",
          symbolName: "trash",
          action: #selector(contextMenuTrash(_:))))
      menu.addItem(.separator())
      menu.addItem(
        makeContextMenuItem(
          title: "Get Info",
          symbolName: "info.circle",
          action: #selector(contextMenuGetInfo(_:))))
      menu.addItem(
        makeContextMenuItem(
          title: "Rename",
          symbolName: "pencil",
          action: #selector(contextMenuRename(_:))))
      menu.addItem(
        makeContextMenuItem(
          title: "Compress \"\(name)\"",
          symbolName: "archivebox",
          action: #selector(contextMenuCompress(_:))))
      menu.addItem(
        makeContextMenuItem(
          title: "Duplicate",
          symbolName: "plus.square.on.square",
          action: #selector(contextMenuDuplicate(_:))))
      menu.addItem(
        makeContextMenuItem(
          title: "Make Alias",
          symbolName: "arrow.up.right.square",
          action: #selector(contextMenuMakeAlias(_:))))
      menu.addItem(
        makeContextMenuItem(
          title: "Quick Look",
          symbolName: "eye",
          action: #selector(contextMenuQuickLook(_:))))
      menu.addItem(.separator())
      menu.addItem(
        makeContextMenuItem(
          title: "Copy \"\(name)\"",
          symbolName: "doc.on.doc",
          action: #selector(contextMenuCopy(_:))))
      menu.addItem(
        makeContextMenuItem(
          title: "Copy \"\(name)\" as Pathname",
          symbolName: "text.alignleft",
          action: #selector(contextMenuCopyPathname(_:))))
      menu.addItem(
        makeContextMenuItem(
          title: "Share...",
          symbolName: "square.and.arrow.up",
          action: #selector(contextMenuShare(_:))))
    } else {
      // Multi-select: omit "Open" (mass-open via the default app
      // across mixed folders/files is unintuitive) and "Rename"
      // (single-target only). "Open With..." is kept — picking one
      // app for several files is a real workflow (five images in
      // Pixelmator, three logs in BBEdit) and Launch Services
      // batches them into a single launch.
      menu.addItem(
        makeContextMenuItem(
          title: "New Folder with Selection (\(count) Items)",
          symbolName: "folder.badge.plus",
          action: #selector(contextMenuNewFolderWithSelection(_:))))
      menu.addItem(.separator())
      menu.addItem(
        makeContextMenuItem(
          title: "Open With...",
          symbolName: "arrow.up.forward.app",
          action: #selector(contextMenuOpenWith(_:))))
      menu.addItem(
        makeContextMenuItem(
          title: "Show in Finder",
          symbolName: "finder",
          action: #selector(contextMenuShowInFinder(_:))))
      menu.addItem(.separator())
      menu.addItem(
        makeContextMenuItem(
          title: "Move to Trash",
          symbolName: "trash",
          action: #selector(contextMenuTrash(_:))))
      menu.addItem(.separator())
      menu.addItem(
        makeContextMenuItem(
          title: "Compress \(count) Items",
          symbolName: "archivebox",
          action: #selector(contextMenuCompress(_:))))
      menu.addItem(
        makeContextMenuItem(
          title: "Duplicate",
          symbolName: "plus.square.on.square",
          action: #selector(contextMenuDuplicate(_:))))
      menu.addItem(
        makeContextMenuItem(
          title: "Make Alias",
          symbolName: "arrow.up.right.square",
          action: #selector(contextMenuMakeAlias(_:))))
      menu.addItem(
        makeContextMenuItem(
          title: "Quick Look",
          symbolName: "eye",
          action: #selector(contextMenuQuickLook(_:))))
      menu.addItem(.separator())
      menu.addItem(
        makeContextMenuItem(
          title: "Copy \(count) Items",
          symbolName: "doc.on.doc",
          action: #selector(contextMenuCopy(_:))))
      menu.addItem(
        makeContextMenuItem(
          title: "Copy \(count) Items as Pathnames",
          symbolName: "text.alignleft",
          action: #selector(contextMenuCopyPathname(_:))))
      menu.addItem(
        makeContextMenuItem(
          title: "Share...",
          symbolName: "square.and.arrow.up",
          action: #selector(contextMenuShare(_:))))
    }
    return menu
  }

  private func makeContextMenuItem(title: String, symbolName: String, action: Selector?)
    -> NSMenuItem
  {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    return item
  }

  @objc func contextMenuOpen(_ sender: Any?) { openSelectedRow() }
  @objc func contextMenuOpenWith(_ sender: Any?) { openSelectionWithChosenApplication() }
  @objc func contextMenuTrash(_ sender: Any?) { trashSelection() }
  @objc func contextMenuGetInfo(_ sender: Any?) { showInfoForSelection() }
  @objc func contextMenuRename(_ sender: Any?) { beginRename() }
  @objc func contextMenuCompress(_ sender: Any?) { compressSelection() }
  @objc func contextMenuDuplicate(_ sender: Any?) { duplicateSelection() }
  @objc func contextMenuMakeAlias(_ sender: Any?) { makeAliasForSelection() }
  @objc func contextMenuQuickLook(_ sender: Any?) { toggleQuickLook() }
  @objc func contextMenuCopy(_ sender: Any?) { copySelectionToPasteboard() }
  @objc func contextMenuCopyPathname(_ sender: Any?) { copyPathnamesToPasteboard() }
  @objc func contextMenuPaste(_ sender: Any?) { pasteFromPasteboard() }
  @objc func contextMenuShare(_ sender: Any?) { shareSelection() }
  @objc func contextMenuNewFolder(_ sender: Any?) { createNewFolder() }
  @objc func contextMenuNewFolderWithSelection(_ sender: Any?) { newFolderWithSelection() }

  /// Hand the current selection (or, on empty-area click, the
  /// directory the pane is showing) to the native Finder app and
  /// bring Finder forward with the entries highlighted. Multi-select
  /// is supported in one call — `activateFileViewerSelecting` opens
  /// a single Finder window with all entries selected, mirroring
  /// the native ⌘⇧F4 / right-click "Show in Enclosing Folder" flow.
  ///
  /// The `finder` SF Symbol that decorates this menu item is one of
  /// Apple's restricted glyphs: per the SF Symbols license it may
  /// only be used in contexts that refer to the macOS Finder app.
  /// Driving Finder via `activateFileViewerSelecting` is exactly that
  /// use, so the glyph is permitted here and would not be elsewhere
  /// (e.g. as a generic "files" icon).
  @objc func contextMenuShowInFinder(_ sender: Any?) {
    let urls = selectedURLs
    let targets = urls.isEmpty ? [currentURL] : urls
    NSWorkspace.shared.activateFileViewerSelecting(targets)
  }
}
