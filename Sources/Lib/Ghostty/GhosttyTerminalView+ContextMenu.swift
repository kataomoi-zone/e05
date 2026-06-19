import AppKit
import GhosttyKit

/// Right-click context menu for a terminal surface. libghostty has no
/// context menu of its own and only highlights URLs under a held modifier,
/// so e05 reads the clicked row's text, finds any URL / path / hash there
/// (`TerminalTextScanner`), and offers Open / Copy for it alongside the
/// usual Copy / Paste / Select All. Selection-wide actions go through
/// libghostty binding actions; a single token is copied straight to the
/// pasteboard.
extension GhosttyTerminalView {
  public override func rightMouseDown(with event: NSEvent) {
    guard let surface else {
      super.rightMouseDown(with: event)
      return
    }
    // A click anywhere dismisses link hints instead of opening a menu.
    if hintsOverlay != nil {
      dismissLinkHints()
      return
    }
    // A full-screen TUI in mouse-reporting mode (an editor, a pager) owns
    // the right button itself, so forward it rather than stealing it for a
    // menu. mouse_captured tracks whether the program enabled mouse mode.
    if ghostty_surface_mouse_captured(surface) {
      ghostty_surface_mouse_button(
        surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT,
        GhosttyInput.ghosttyMods(event.modifierFlags))
      return
    }
    // Focus the clicked pane so Paste / Select All act here, matching the
    // way clicking a pane body focuses it.
    window?.makeFirstResponder(self)
    let menu = makeContextMenu(for: event)
    menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
  }

  public override func rightMouseUp(with event: NSEvent) {
    guard let surface, ghostty_surface_mouse_captured(surface) else { return }
    ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT,
      GhosttyInput.ghosttyMods(event.modifierFlags))
  }

  // MARK: - Menu construction

  private func makeContextMenu(for event: NSEvent) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    guard let surface else { return menu }

    if let metrics = gridMetrics(),
      let cell = cell(
        at: event.locationInWindow, size: metrics.size,
        cellWidth: metrics.cellWidth, cellHeight: metrics.cellHeight)
    {
      var addedContextItem = false

      // A URL / path / hash under the cursor.
      if let line = readRowText(row: cell.row, columns: Int(metrics.size.columns)),
        let token = TerminalTextScanner.token(at: cell.column, in: line)
      {
        addTokenItems(
          kind: token.kind, text: linkText(for: token, in: line, size: metrics.size), to: menu)
        addedContextItem = true
      }

      // The shell command whose region was clicked (OSC 133). `.command`
      // (the typed command alone) isn't surfaced: it needs the OSC 133 B
      // input mark, which dynamic prompts like starship don't emit, so it
      // would appear only sometimes — confusing rather than helpful.
      if let text = commandText(at: cell, scope: .commandAndOutput) {
        menu.addItem(
          item("Copy Command + Output", #selector(contextCopyString(_:)), represents: text))
        addedContextItem = true
      }
      if let text = commandText(at: cell, scope: .output) {
        menu.addItem(item("Copy Output", #selector(contextCopyString(_:)), represents: text))
        addedContextItem = true
      }

      if addedContextItem { menu.addItem(.separator()) }
    }

    let copy = item("Copy", #selector(contextCopySelection))
    copy.isEnabled = ghostty_surface_has_selection(surface)
    menu.addItem(copy)

    let paste = item("Paste", #selector(contextPaste))
    paste.isEnabled = NSPasteboard.general.canReadObject(forClasses: [NSString.self], options: nil)
    menu.addItem(paste)

    menu.addItem(item("Select All", #selector(contextSelectAll)))
    return menu
  }

  private func addTokenItems(kind: TerminalToken.Kind, text: String, to menu: NSMenu) {
    switch kind {
    case .url:
      let open = item("Open Link", #selector(contextOpenLink(_:)), represents: text)
      open.isEnabled = URL(string: text) != nil
      menu.addItem(open)
      menu.addItem(item("Copy Link", #selector(contextCopyString(_:)), represents: text))
    case .path:
      menu.addItem(item("Copy Path", #selector(contextCopyString(_:)), represents: text))
    case .hash:
      menu.addItem(item("Copy Hash", #selector(contextCopyString(_:)), represents: text))
    }
  }

  /// The token's text, reunited with any soft-wrapped continuation. Only
  /// worth a whole-viewport read when the token sits against an edge: one
  /// ending at the last column may continue on the next row, one starting
  /// at column 0 may continue a previous row. The edge test is in display
  /// cells, not character offsets, so a wide glyph earlier on the row
  /// doesn't hide a clipped token.
  private func linkText(for token: TerminalToken, in line: String, size: ghostty_surface_size_s)
    -> String
  {
    let columns = Int(size.columns)
    let startIndex = line.index(line.startIndex, offsetBy: token.start)
    let endIndex = line.index(line.startIndex, offsetBy: token.end)
    let cellStart = TerminalDisplayWidth.width(of: line[..<startIndex])
    let cellEnd = cellStart + TerminalDisplayWidth.width(of: line[startIndex..<endIndex])
    guard cellEnd >= columns || cellStart == 0 else { return token.text }
    guard let joined = readViewportText(rows: Int(size.rows), columns: columns) else {
      return token.text
    }
    return TerminalTextScanner.expandedText(of: token.text, kind: token.kind, inJoined: joined)
  }

  private func item(_ title: String, _ action: Selector, represents: String? = nil) -> NSMenuItem {
    let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
    menuItem.target = self
    menuItem.representedObject = represents
    return menuItem
  }

  // MARK: - Actions

  @objc private func contextOpenLink(_ sender: NSMenuItem) {
    guard let text = sender.representedObject as? String, let url = URL(string: text) else {
      return
    }
    onOpenURL?(url)
  }

  @objc private func contextCopyString(_ sender: NSMenuItem) {
    guard let text = sender.representedObject as? String else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  @objc private func contextCopySelection() { performBindingAction("copy_to_clipboard") }
  @objc private func contextPaste() { performBindingAction("paste_from_clipboard") }
  @objc private func contextSelectAll() { performBindingAction("select_all") }

  @discardableResult
  private func performBindingAction(_ action: String) -> Bool {
    guard let surface else { return false }
    return action.withCString { ptr in
      ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
    }
  }

}
