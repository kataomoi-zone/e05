import AppKit

extension PaneContainerViewController {
  // MARK: - Action Registry

  /// Look up an action by its stable id and run its handler. Returns
  /// `false` when the id is unknown so the IPC layer can surface a
  /// `{"ok":false,"error":"..."}` reply rather than silently drop the
  /// request. The handler runs synchronously on the main actor; long
  /// operations should already be wrapping their own `Task`.
  @discardableResult
  public func dispatchAction(id: String) -> Bool {
    guard let action = actions().first(where: { $0.id == id }) else {
      return false
    }
    action.handler()
    return true
  }

  /// All user-facing actions, in menu display order. Both the menu bar
  /// and the command palette consume this same array. Static actions
  /// (keybindings) come first, followed by dynamic "Focus: <title>"
  /// entries generated from the current pane layout.
  public func actions() -> [Action] {
    var result: [Action] = [
      Action(
        id: "new_terminal_pane",
        title: "New Terminal Pane",
        // No keyboard shortcut: ⌘T is now claimed by
        // `new_browser_pane` because a browser pane is the more
        // common new-tab gesture. Terminal panes are still
        // creatable from the palette and can be re-bound during
        // the customisation phase.
        handler: { [weak self] in
          self?.addColumn()
          self?.showToast("New Terminal Pane")
        }
      ),
      Action(
        id: "undo_close",
        title: "Reopen Closed Pane",
        keyEquivalent: "t",
        modifierMask: [.command, .shift],
        // Stay always-enabled so the handler is reachable from ⌘⇧T
        // even when the stash is empty or the workspace is private —
        // the toast in `undoClosePane` explains the no-op so the user
        // gets a reason instead of silent absorption of the keystroke.
        handler: { [weak self] in self?.undoClosePane() }
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
        id: "next_pane",
        title: "Next Pane",
        keyEquivalent: "\t",
        modifierMask: [.control],
        handler: { [weak self] in self?.focusNextPane() }
      ),
      Action(
        id: "prev_pane",
        title: "Previous Pane",
        keyEquivalent: "\t",
        modifierMask: [.control, .shift],
        handler: { [weak self] in self?.focusPreviousPane() }
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
        handler: { [weak self] in
          self?.toggleURLBarVisibility()
          // Read post-state and surface the verb-phrase that
          // *produced* it: the URL bar being visible after the
          // toggle means the user just performed "Show URL Bar".
          // The menu title (`validate` further down) shows the
          // *next* action instead, which is why the strings flip
          // between toast and menu.
          self?.showToast(self?.urlBarVisible == true ? "Show URL Bar" : "Hide URL Bar")
        }
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
        handler: { [weak self] in
          guard let self,
            let column = self.columns[safe: self.focusedColumnIndex]
          else { return }
          self.toggleFold()
          // Post-state: `toggleFold` flips `isFolded` synchronously,
          // so reading after the call gives the user-visible state.
          self.showToast(column.isFolded ? "Fold Column" : "Unfold Column")
        }
      ),
      Action(
        id: "toggle_bookmark",
        title: "Toggle Bookmark",
        keyEquivalent: "d",
        handler: { [weak self] in
          if let added = self?.toggleBookmark() {
            self?.showToast(added ? "Add Bookmark" : "Remove Bookmark")
          }
        },
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
        handler: { [weak self] in
          guard let self, self.isFocusedPaneBrowser else { return }
          self.toggleInspector()
          self.showToast(self.isFocusedInspectorOpen ? "Show Web Inspector" : "Hide Web Inspector")
        },
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
        handler: { [weak self] in
          guard let self, self.isFocusedPaneBrowser else { return }
          self.reloadFocusedBrowser()
          self.showToast("Reload Page")
        },
        validate: { [weak self] in (self?.isFocusedPaneBrowser ?? false, nil) },
        separatorBefore: true
      ),
      Action(
        id: "browser_hard_reload",
        title: "Reload Page (Bypass Cache)",
        keyEquivalent: "r",
        modifierMask: [.command, .shift],
        handler: { [weak self] in
          guard let self, self.isFocusedPaneBrowser else { return }
          self.reloadFocusedBrowserFromOrigin()
          self.showToast("Reload Page (Bypass Cache)")
        },
        validate: { [weak self] in (self?.isFocusedPaneBrowser ?? false, nil) }
      ),
      Action(
        id: "browser_back",
        title: "Back",
        keyEquivalent: "[",
        handler: { [weak self] in
          guard let self, self.isFocusedPaneBrowser else { return }
          if self.canFocusedBrowserGoBack {
            self.goBackFocusedBrowser()
            self.showToast("Back")
          } else {
            self.showToast("No more history", style: .error)
          }
        },
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
        handler: { [weak self] in
          guard let self, self.isFocusedPaneBrowser else { return }
          if self.canFocusedBrowserGoForward {
            self.goForwardFocusedBrowser()
            self.showToast("Forward")
          } else {
            self.showToast("No more history", style: .error)
          }
        },
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
        handler: { [weak self] in
          guard let self, self.isFocusedPaneBrowser else { return }
          self.zoomInFocusedBrowser()
          self.showZoomToast()
        },
        validate: { [weak self] in (self?.isFocusedPaneBrowser ?? false, nil) },
        separatorBefore: true
      ),
      Action(
        id: "browser_zoom_out",
        title: "Zoom Out",
        keyEquivalent: "-",
        handler: { [weak self] in
          guard let self, self.isFocusedPaneBrowser else { return }
          self.zoomOutFocusedBrowser()
          self.showZoomToast()
        },
        validate: { [weak self] in (self?.isFocusedPaneBrowser ?? false, nil) }
      ),
      Action(
        id: "browser_zoom_reset",
        title: "Actual Size",
        keyEquivalent: "0",
        handler: { [weak self] in
          guard let self, self.isFocusedPaneBrowser else { return }
          self.resetFocusedBrowserZoom()
          self.showToast("Zoom 100%")
        },
        validate: { [weak self] in (self?.isFocusedPaneBrowser ?? false, nil) }
      ),
      Action(
        id: "browser_suspend",
        title: "Suspend Pane",
        // No default keyEquivalent: the memory-saver path is usually
        // invoked automatically (idle threshold / pressure event)
        // and the manual trigger is meant for IPC and palette users
        // who want to reclaim a specific tab on demand. A binding
        // can land later through the customisation phase.
        handler: { [weak self] in
          guard let self, self.canSuspendFocusedBrowser else { return }
          self.suspendFocusedBrowser()
          self.showToast("Suspend Pane")
        },
        validate: { [weak self] in
          (self?.canSuspendFocusedBrowser ?? false, nil)
        }
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
        id: "new_browser_pane",
        title: "New Browser Pane",
        keyEquivalent: "t",
        handler: { [weak self] in
          self?.addColumn(address: .blankBrowser)
          self?.showToast("New Browser Pane")
        }
      ),
      Action(
        id: "new_finder_pane",
        title: "New Finder Pane",
        // No keyboard shortcut: ⌥⌃F is taken by Toggle Fold and ⌘F by
        // Find in Page. The palette is the discovery surface for now;
        // a binding can be added once the customisation phase exposes
        // a way for users to claim a free chord.
        handler: { [weak self] in
          self?.addColumn(address: PaneAddress.finder(path: ""))
          self?.showToast("New Finder Pane")
        }
      ),
      Action(
        id: "toggle_hidden_files",
        title: "Toggle Hidden Files",
        // Flip the global finder-pane "show hidden files" setting.
        // Static label mirrors the other `toggle_*` actions that
        // read the action by intent ("Toggle Fold", "Toggle URL
        // Bar") rather than by post-flip state; the effect is
        // visible in the finder pane itself immediately on trigger.
        handler: { [weak self] in
          FinderSettings.toggleShowHiddenFiles()
          self?.showToast(FinderSettings.showHiddenFiles ? "Show Hidden Files" : "Hide Hidden Files")
        }
      ),
      Action(
        id: "finder_view_as_icons",
        title: "View as Icons",
        // No keyboard shortcut: deliberately matches Finder's
        // `View > as Icons / as List` muscle memory and stays
        // palette-discoverable.
        handler: { [weak self] in
          guard let finderView = self?.focusedPane?.finderView else { return }
          finderView.setViewMode(.icon)
          self?.showToast("View as Icons")
        },
        validate: { [weak self] in (self?.focusedPane?.finderView != nil, nil) }
      ),
      Action(
        id: "finder_view_as_list",
        title: "View as List",
        handler: { [weak self] in
          guard let finderView = self?.focusedPane?.finderView else { return }
          finderView.setViewMode(.list)
          self?.showToast("View as List")
        },
        validate: { [weak self] in (self?.focusedPane?.finderView != nil, nil) }
      ),
      Action(
        id: "new_folder",
        title: "New Folder",
        keyEquivalent: "n",
        modifierMask: [.command, .shift],
        handler: { [weak self] in
          guard let finderView = self?.focusedPane?.finderView else { return }
          finderView.createNewFolder()
          self?.showToast("New Folder")
        },
        validate: { [weak self] in (self?.focusedPane?.finderView != nil, nil) }
      ),
      Action(
        id: "move_to_trash",
        title: "Move to Trash",
        // `"\u{8}"` (`NSBackspaceCharacter`) is the macOS standard for
        // ⌘⌫ menu shortcuts — Finder.app and Xcode's "Move to Trash"
        // items use the same character. NSMenu renders it as the ⌫
        // glyph and `performKeyEquivalent` claims Command+Backspace.
        // `"\u{7F}"` (`NSDeleteCharacter`) renders as ⌦ instead and
        // binds forward-delete, which isn't what users expect.
        keyEquivalent: "\u{8}",
        modifierMask: [.command],
        handler: { [weak self] in
          guard let finderView = self?.focusedPane?.finderView,
            finderView.hasSelection
          else { return }
          finderView.trashSelection()
          self?.showToast("Move to Trash")
        },
        validate: { [weak self] in
          ((self?.focusedPane?.finderView?.hasSelection) ?? false, nil)
        }
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
        handler: { [weak self] in
          self?.sidebarVC?.togglePin()
          let pinned = self?.sidebarVC?.currentState == .pinnedOpen
          self?.showToast(pinned ? "Pin Sidebar" : "Unpin Sidebar")
        },
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
        keyEquivalent: "n",
        handler: { [weak self] in self?.createWorkspace() },
        separatorBefore: true
      ),
      Action(
        id: "workspace_new_private",
        title: "New Private Workspace",
        keyEquivalent: "n",
        modifierMask: [.command, .shift],
        handler: { [weak self] in self?.createWorkspace(isPrivate: true) }
      ),
      Action(
        id: "workspace_close",
        title: "Close Current Workspace",
        keyEquivalent: "w",
        modifierMask: [.command, .shift],
        handler: { [weak self] in self?.closeCurrentWorkspace() }
      ),
      Action(
        id: "workspace_next",
        title: "Next Workspace",
        keyEquivalent: "]",
        modifierMask: [.command, .shift],
        handler: { [weak self] in self?.switchWorkspaceNext() },
        validate: { [weak self] in ((self?.workspaces.count ?? 0) > 1, nil) }
      ),
      Action(
        id: "workspace_prev",
        title: "Previous Workspace",
        keyEquivalent: "[",
        modifierMask: [.command, .shift],
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
