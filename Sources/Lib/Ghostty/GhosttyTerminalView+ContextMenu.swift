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

    let size = ghostty_surface_size(surface)
    if let cell = cell(at: event.locationInWindow, size: size),
      let line = readRowText(row: cell.row, columns: Int(size.columns)),
      let token = TerminalTextScanner.token(at: cell.column, in: line)
    {
      addTokenItems(
        kind: token.kind, text: linkText(for: token, size: size), to: menu)
      menu.addItem(.separator())
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
  /// at column 0 may continue a previous row.
  private func linkText(for token: TerminalToken, size: ghostty_surface_size_s) -> String {
    let columns = Int(size.columns)
    guard token.end >= columns || token.start == 0 else { return token.text }
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

  // MARK: - Grid reading

  /// Grid cell under a window-space point, or nil when the click lands
  /// outside the addressable grid. Cell metrics are in pixels; the view
  /// works in points, so divide by the backing scale.
  private func cell(at locationInWindow: NSPoint, size: ghostty_surface_size_s) -> (
    column: Int, row: Int
  )? {
    guard let scale = window?.backingScaleFactor,
      size.columns > 0, size.rows > 0, size.cell_width_px > 0, size.cell_height_px > 0
    else { return nil }
    let cellWidth = Double(size.cell_width_px) / scale
    let cellHeight = Double(size.cell_height_px) / scale
    let local = convert(locationInWindow, from: nil)
    let xFromLeft = Double(local.x)
    let yFromTop = Double(bounds.height - local.y)
    guard xFromLeft >= 0, yFromTop >= 0 else { return nil }
    let column = Int(xFromLeft / cellWidth)
    let row = Int(yFromTop / cellHeight)
    guard column < Int(size.columns), row < Int(size.rows) else { return nil }
    return (column, row)
  }

  /// Text of one viewport row. A single-row read can carry a trailing
  /// newline; drop it so column offsets stay aligned to the grid.
  private func readRowText(row: Int, columns: Int) -> String? {
    guard
      let text = readText(
        topRow: row, topColumn: 0, bottomRow: row, bottomColumn: columns - 1)
    else { return nil }
    return text.hasSuffix("\n") ? String(text.dropLast()) : text
  }

  /// The whole viewport as one read, newlines intact so a soft-wrapped row
  /// stays joined onto one logical line and only hard breaks separate them.
  /// Lets `linkText` recover a URL clipped by a wrap.
  private func readViewportText(rows: Int, columns: Int) -> String? {
    readText(topRow: 0, topColumn: 0, bottomRow: rows - 1, bottomColumn: columns - 1)
  }

  /// Read a point range through libghostty's selection-text API. Returns
  /// "" for an empty range and nil on failure.
  private func readText(topRow: Int, topColumn: Int, bottomRow: Int, bottomColumn: Int) -> String? {
    guard let surface, bottomColumn >= 0, bottomRow >= 0 else { return nil }
    let selection = ghostty_selection_s(
      top_left: ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
        x: UInt32(topColumn), y: UInt32(topRow)),
      bottom_right: ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
        x: UInt32(bottomColumn), y: UInt32(bottomRow)),
      rectangle: false)
    var out = ghostty_text_s()
    guard ghostty_surface_read_text(surface, selection, &out) else { return nil }
    defer { ghostty_surface_free_text(surface, &out) }
    guard let ptr = out.text, out.text_len > 0 else { return "" }
    return ptr.withMemoryRebound(to: UInt8.self, capacity: Int(out.text_len)) {
      String(decoding: UnsafeBufferPointer(start: $0, count: Int(out.text_len)), as: UTF8.self)
    }
  }
}
