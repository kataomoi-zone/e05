import AppKit

extension PaneContainerViewController {
  // MARK: - Action Registry

  /// All user-facing actions, in menu display order. Both the menu bar
  /// and the command palette consume this same array. Static actions
  /// (keybindings) come first, followed by dynamic "Focus: <title>"
  /// entries generated from the current pane layout.
  public func actions() -> [Action] {
    var result: [Action] = [
      Action(
        id: "new_column",
        title: "New Column",
        keyEquivalent: "t",
        handler: { [weak self] in self?.addColumn() }
      ),
      Action(
        id: "undo_close",
        title: "Reopen Closed Pane",
        keyEquivalent: "t",
        modifierMask: [.command, .shift],
        handler: { [weak self] in self?.undoClosePane() },
        validate: { [weak self] in (self?.canUndoClosePane ?? false, nil) }
      ),
      Action(
        id: "close_pane",
        title: "Close Pane",
        keyEquivalent: "w",
        handler: { [weak self] in self?.removeCurrentPane() }
      ),
      Action(
        id: "split_vertical",
        title: "Split Vertical",
        keyEquivalent: "v",
        modifierMask: [.option, .control],
        handler: { [weak self] in self?.splitVertical() }
      ),
      Action(
        id: "focus_left",
        title: "Focus Left",
        keyEquivalent: "h",
        modifierMask: [.option, .control],
        handler: { [weak self] in self?.focusLeft() },
        separatorBefore: true
      ),
      Action(
        id: "focus_right",
        title: "Focus Right",
        keyEquivalent: "l",
        modifierMask: [.option, .control],
        handler: { [weak self] in self?.focusRight() }
      ),
      Action(
        id: "focus_down",
        title: "Focus Down",
        keyEquivalent: "j",
        modifierMask: [.option, .control],
        handler: { [weak self] in self?.focusDown() }
      ),
      Action(
        id: "focus_up",
        title: "Focus Up",
        keyEquivalent: "k",
        modifierMask: [.option, .control],
        handler: { [weak self] in self?.focusUp() }
      ),
      Action(
        id: "move_column_left",
        title: "Move Column Left",
        keyEquivalent: "h",
        modifierMask: [.option, .control, .shift],
        handler: { [weak self] in self?.moveColumnLeft() },
        separatorBefore: true
      ),
      Action(
        id: "move_column_right",
        title: "Move Column Right",
        keyEquivalent: "l",
        modifierMask: [.option, .control, .shift],
        handler: { [weak self] in self?.moveColumnRight() }
      ),
      Action(
        id: "move_pane_down",
        title: "Move Pane Down",
        keyEquivalent: "j",
        modifierMask: [.option, .control, .shift],
        handler: { [weak self] in self?.movePaneDown() }
      ),
      Action(
        id: "move_pane_up",
        title: "Move Pane Up",
        keyEquivalent: "k",
        modifierMask: [.option, .control, .shift],
        handler: { [weak self] in self?.movePaneUp() }
      ),
      Action(
        id: "cycle_width",
        title: "Cycle Width",
        keyEquivalent: "/",
        modifierMask: [.option, .control],
        handler: { [weak self] in self?.cycleWidthPreset(Self.defaultWidthCycle) },
        separatorBefore: true
      ),
      Action(
        id: "toggle_url_bar",
        title: "Toggle URL Bar",
        keyEquivalent: "l",
        modifierMask: [.command, .shift],
        handler: { [weak self] in self?.toggleURLBarVisibility() }
      ),
      Action(
        id: "focus_url_bar",
        title: "Focus URL Bar",
        keyEquivalent: "l",
        handler: { [weak self] in self?.focusURLBar() }
      ),
      Action(
        id: "toggle_fold",
        title: "Toggle Fold",
        keyEquivalent: "f",
        modifierMask: [.option, .control],
        handler: { [weak self] in self?.toggleFold() }
      ),
      Action(
        id: "toggle_bookmark",
        title: "Toggle Bookmark",
        keyEquivalent: "d",
        handler: { [weak self] in _ = self?.toggleBookmark() },
        validate: { [weak self] in
          let isBookmarked = self?.isFocusedPaneBookmarked ?? false
          let title = isBookmarked ? "Remove Bookmark" : "Add Bookmark"
          return (self?.isFocusedPaneBrowser ?? false, title)
        }
      ),
      Action(
        id: "toggle_inspector",
        title: "Toggle Web Inspector",
        keyEquivalent: "i",
        modifierMask: [.option, .command],
        handler: { [weak self] in self?.toggleInspector() },
        validate: { [weak self] in
          let isOpen = self?.isFocusedInspectorOpen ?? false
          let title = isOpen ? "Hide Web Inspector" : "Show Web Inspector"
          return (self?.isFocusedPaneBrowser ?? false, title)
        }
      ),
      Action(
        id: "browser_reload",
        title: "Reload Page",
        keyEquivalent: "r",
        handler: { [weak self] in self?.reloadFocusedBrowser() },
        validate: { [weak self] in (self?.isFocusedPaneBrowser ?? false, nil) },
        separatorBefore: true
      ),
      Action(
        id: "browser_hard_reload",
        title: "Reload Page (Bypass Cache)",
        keyEquivalent: "r",
        modifierMask: [.command, .shift],
        handler: { [weak self] in self?.reloadFocusedBrowserFromOrigin() },
        validate: { [weak self] in (self?.isFocusedPaneBrowser ?? false, nil) }
      ),
      Action(
        id: "browser_back",
        title: "Back",
        keyEquivalent: "[",
        handler: { [weak self] in self?.goBackFocusedBrowser() },
        validate: { [weak self] in
          let enabled =
            (self?.isFocusedPaneBrowser ?? false)
            && (self?.canFocusedBrowserGoBack ?? false)
          return (enabled, nil)
        }
      ),
      Action(
        id: "browser_forward",
        title: "Forward",
        keyEquivalent: "]",
        handler: { [weak self] in self?.goForwardFocusedBrowser() },
        validate: { [weak self] in
          let enabled =
            (self?.isFocusedPaneBrowser ?? false)
            && (self?.canFocusedBrowserGoForward ?? false)
          return (enabled, nil)
        }
      ),
      Action(
        id: "browser_zoom_in",
        title: "Zoom In",
        keyEquivalent: "+",
        handler: { [weak self] in self?.zoomInFocusedBrowser() },
        validate: { [weak self] in (self?.isFocusedPaneBrowser ?? false, nil) },
        separatorBefore: true
      ),
      Action(
        id: "browser_zoom_out",
        title: "Zoom Out",
        keyEquivalent: "-",
        handler: { [weak self] in self?.zoomOutFocusedBrowser() },
        validate: { [weak self] in (self?.isFocusedPaneBrowser ?? false, nil) }
      ),
      Action(
        id: "browser_zoom_reset",
        title: "Actual Size",
        keyEquivalent: "0",
        handler: { [weak self] in self?.resetFocusedBrowserZoom() },
        validate: { [weak self] in (self?.isFocusedPaneBrowser ?? false, nil) }
      ),
      Action(
        id: "pane_find",
        title: "Find in Page",
        keyEquivalent: "f",
        handler: { [weak self] in self?.openFindBar() },
        validate: { [weak self] in (self?.focusedPane?.findHelper != nil, nil) },
        separatorBefore: true
      ),
      Action(
        id: "pane_find_next",
        title: "Find Next",
        keyEquivalent: "g",
        handler: { [weak self] in self?.findNext() },
        validate: { [weak self] in (self?.focusedPane?.findHelper != nil, nil) }
      ),
      Action(
        id: "pane_find_prev",
        title: "Find Previous",
        keyEquivalent: "g",
        modifierMask: [.command, .shift],
        handler: { [weak self] in self?.findPrev() },
        validate: { [weak self] in (self?.focusedPane?.findHelper != nil, nil) }
      ),
      Action(
        id: "new_browser",
        title: "New Browser Column",
        keyEquivalent: "b",
        modifierMask: [.option, .control],
        handler: { [weak self] in self?.addColumn(address: .blankBrowser) }
      ),
      Action(
        id: "new_finder",
        title: "New Finder Column",
        // No keyboard shortcut: ⌥⌃F is taken by Toggle Fold and ⌘F by
        // Find in Page. The palette is the discovery surface for now;
        // a binding can be added once the customisation phase exposes
        // a way for users to claim a free chord.
        handler: { [weak self] in self?.addColumn(address: PaneAddress.finder(path: "")) }
      ),
      Action(
        id: "toggle_hidden_files",
        title: "Toggle Hidden Files",
        // Flip the global finder-pane "show hidden files" setting.
        // Static label mirrors the other `toggle_*` actions that
        // read the action by intent ("Toggle Fold", "Toggle URL
        // Bar") rather than by post-flip state; the effect is
        // visible in the finder pane itself immediately on trigger.
        handler: { FinderSettings.toggleShowHiddenFiles() }
      ),
      Action(
        id: "command_palette",
        title: "Command Palette",
        keyEquivalent: "p",
        modifierMask: [.command, .shift],
        handler: { [weak self] in self?.toggleCommandPalette() }
      ),
      Action(
        id: "toggle_sidebar_pin",
        title: "Toggle Sidebar Pin",
        keyEquivalent: "b",
        handler: { [weak self] in self?.sidebarVC?.togglePin() },
        validate: { [weak self] in
          let pinned = self?.sidebarVC?.currentState == .pinnedOpen
          return (true, pinned ? "Unpin Sidebar" : "Pin Sidebar")
        }
      ),
      Action(
        id: "open_bookmarks",
        title: "Open Bookmarks",
        handler: { [weak self] in self?.sidebarVC?.openMode(.bookmarks) }
      ),
      Action(
        id: "open_history",
        title: "Open History",
        handler: { [weak self] in self?.sidebarVC?.openMode(.history) }
      ),
      Action(
        id: "open_downloads",
        title: "Open Downloads",
        handler: { [weak self] in self?.sidebarVC?.openMode(.downloads) }
      ),
      Action(
        id: "workspace_new",
        title: "New Workspace",
        handler: { [weak self] in self?.createWorkspace() },
        validate: { [weak self] in (self?.canCreateWorkspace ?? false, nil) },
        separatorBefore: true
      ),
      Action(
        id: "workspace_close",
        title: "Close Current Workspace",
        handler: { [weak self] in self?.closeCurrentWorkspace() }
      ),
      Action(
        id: "workspace_next",
        title: "Next Workspace",
        keyEquivalent: "\t",
        modifierMask: [.control],
        handler: { [weak self] in self?.switchWorkspaceNext() },
        validate: { [weak self] in ((self?.workspaces.count ?? 0) > 1, nil) }
      ),
      Action(
        id: "workspace_prev",
        title: "Previous Workspace",
        keyEquivalent: "\t",
        modifierMask: [.control, .shift],
        handler: { [weak self] in self?.switchWorkspacePrevious() },
        validate: { [weak self] in ((self?.workspaces.count ?? 0) > 1, nil) }
      ),
    ]

    // Dynamic workspace actions: switch / move-pane, one entry per
    // non-current workspace. Capture the workspace id at registration
    // time so that deleting/reordering workspaces while the palette is
    // open can't misdirect the handler.
    for (i, ws) in workspaces.enumerated() where i != focusedWorkspaceIndex {
      let wsId = ws.id
      result.append(
        Action(
          id: "workspace_switch_\(wsId)",
          title: "Switch to Workspace \(i + 1)",
          handler: { [weak self] in self?.switchWorkspace(toId: wsId) }
        ))
    }
    for (i, ws) in workspaces.enumerated() where i != focusedWorkspaceIndex {
      let wsId = ws.id
      result.append(
        Action(
          id: "workspace_move_pane_\(wsId)",
          title: "Move Pane to Workspace \(i + 1)",
          handler: { [weak self] in self?.movePane(toWorkspaceId: wsId) }
        ))
    }

    // Dynamic actions: one "Focus: <title>" entry per pane across ALL
    // workspaces. `focusPane(id:)` switches workspace as needed, so the
    // command palette can jump anywhere by fuzzy-searching title. Labels
    // are prefixed with the workspace number for non-current workspaces
    // so users can disambiguate identical titles across workspaces.
    for (wsIdx, ws) in workspaces.enumerated() {
      for (colIdx, column) in ws.columns.enumerated() {
        for (paneIdx, pane) in column.panes.enumerated() {
          let base =
            pane.title.isEmpty
            ? "Pane \(colIdx + 1)-\(paneIdx + 1)"
            : pane.title
          let label =
            wsIdx == focusedWorkspaceIndex
            ? base
            : "WS \(wsIdx + 1) · \(base)"
          // Capture pane.id instead of positional indices. The handler
          // resolves the current position at execution time so that
          // pane close/reorder between palette show and selection
          // doesn't silently focus the wrong pane.
          let targetId = pane.id
          result.append(
            Action(
              id: "focus_pane_\(targetId)",
              title: "Focus: \(label)",
              handler: { [weak self] in
                self?.focusPane(id: targetId)
              }
            ))
        }
      }
    }

    return result
  }

  static let defaultWidthCycle: [PaneWidthPreset] = [
    .columns(80),
    .columns(120),
    .fraction(1.0 / 2.0),
    .fraction(1.0 / 3.0),
  ]
}
