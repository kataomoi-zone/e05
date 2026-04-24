import AppKit

/// Right-click / control-click context menu for finder panes. Surfaces
/// existing actions (Open / Move to Trash / Rename / Quick Look /
/// New Folder) — no new action lives here. The selection-adjustment
/// logic that decides which menu state to render lives in
/// `FinderTableView.menu(for:)`, which forwards the resolved
/// `clickedRow` to `buildContextMenu(clickedRow:)`.
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
      menu.addItem(makeContextMenuItem(
        title: "New Folder",
        symbolName: "folder.badge.plus",
        action: #selector(contextMenuNewFolder(_:))))
      return menu
    }

    let count = tableView.selectedRowIndexes.count
    if count == 1 {
      menu.addItem(makeContextMenuItem(
        title: "Open",
        symbolName: "arrow.up.forward.square",
        action: #selector(contextMenuOpen(_:))))
      menu.addItem(.separator())
      menu.addItem(makeContextMenuItem(
        title: "Move to Trash",
        symbolName: "trash",
        action: #selector(contextMenuTrash(_:))))
      menu.addItem(.separator())
      menu.addItem(makeContextMenuItem(
        title: "Rename",
        symbolName: "pencil",
        action: #selector(contextMenuRename(_:))))
      menu.addItem(makeContextMenuItem(
        title: "Quick Look",
        symbolName: "eye",
        action: #selector(contextMenuQuickLook(_:))))
    } else {
      // Multi-select: omit "Open" (mass-open across mixed folders/files
      // is unintuitive) and "Rename" (single-target only).
      menu.addItem(makeContextMenuItem(
        title: "Move to Trash",
        symbolName: "trash",
        action: #selector(contextMenuTrash(_:))))
      menu.addItem(.separator())
      menu.addItem(makeContextMenuItem(
        title: "Quick Look",
        symbolName: "eye",
        action: #selector(contextMenuQuickLook(_:))))
    }
    return menu
  }

  private func makeContextMenuItem(title: String, symbolName: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    return item
  }

  @objc func contextMenuOpen(_ sender: Any?) { openSelectedRow() }
  @objc func contextMenuTrash(_ sender: Any?) { trashSelection() }
  @objc func contextMenuRename(_ sender: Any?) { beginRename() }
  @objc func contextMenuQuickLook(_ sender: Any?) { toggleQuickLook() }
  @objc func contextMenuNewFolder(_ sender: Any?) { createNewFolder() }
}
