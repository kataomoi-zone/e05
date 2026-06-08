import AppKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "Actions")

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
        menuTitle: "New Terminal Pane Here",
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
        handler: { [weak self] in
          // Auxiliary panels (Settings, Get Info, Quick Look,
          // OperationsProgressPanel, ...) take over key focus
          // without becoming main, so the same chord doubles as
          // their rescue close path. NSApplication walks both the
          // key and main responder chains, so this action stays
          // reachable from the menu while a panel is frontmost —
          // the validator further keeps `close_pane` enabled in
          // both states (see `PaneContainerViewController+MenuDispatch`).
          if let key = NSApp.keyWindow, key !== self?.view.window {
            key.performClose(nil)
            return
          }
          self?.removeCurrentPane()
        }
      ),
      Action(
        id: "close_other_panes_in_column",
        title: "Close Other Panes in Column",
        menuTitle: "Close Other Panes",
        // No default chord: discoverable through palette / worklane
        // context menu. Adding a binding would risk collision with
        // close_pane (⌘W) variants and the column-close path uses
        // the worklane row × instead.
        handler: { [weak self] in
          guard let self, let pane = self.focusedPane else { return }
          self.closeOtherPanesInColumn(keepPaneId: pane.id)
        },
        validate: { [weak self] in
          guard let self,
            let column = self.columns[safe: self.focusedColumnIndex]
          else { return (false, nil) }
          return (column.panes.count > 1, nil)
        }
      ),
      Action(
        id: "split_vertical",
        title: "Split Vertical",
        menuTitle: "Split Vertically",
        keyEquivalent: "d",
        modifierMask: [.command, .shift],
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
        menuTitle: "Cycle Width Preset",
        keyEquivalent: "/",
        modifierMask: [.option, .control],
        handler: { [weak self] in
          guard let self else { return }
          self.cycleWidthPreset(Self.resolvedWidthCycle())
        },
        separatorBefore: true
      ),
      Action(
        id: "column_align_left",
        title: "Align Column Left",
        handler: { [weak self] in self?.scrollFocusedColumn(.alignLeft) },
        separatorBefore: true
      ),
      Action(
        id: "column_align_right",
        title: "Align Column Right",
        handler: { [weak self] in self?.scrollFocusedColumn(.alignRight) }
      ),
      Action(
        id: "column_center",
        title: "Center Column",
        handler: { [weak self] in self?.scrollFocusedColumn(.center) }
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
        menuTitle: "Add to Bookmarks",
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
        menuTitle: "Web Inspector",
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
        menuTitle: "Reload",
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
        menuTitle: "Hard Reload",
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
        id: "browser_stop",
        title: "Stop Loading",
        menuTitle: "Stop",
        // ⌘. is the macOS cancel idiom. Disabled-at-rest lets the
        // keystroke fall through to `cancelOperation:` instead of
        // firing a no-op through the menu/key path.
        keyEquivalent: ".",
        handler: { [weak self] in
          guard let self, self.isFocusedPaneBrowser else { return }
          // Re-check inside the handler too: the palette dispatch
          // path (`+Panes.swift:625`) ignores `validate`, so without
          // this guard an idle-time palette selection would emit a
          // misleading "Stop Loading" toast for a no-op stopLoading().
          if self.isFocusedBrowserLoading {
            self.stopFocusedBrowser()
            self.showToast("Stop Loading")
          } else {
            self.showToast("Nothing to stop", style: .error)
          }
        },
        validate: { [weak self] in
          let enabled =
            (self?.isFocusedPaneBrowser ?? false)
            && (self?.isFocusedBrowserLoading ?? false)
          return (enabled, nil)
        }
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
        menuTitle: "Reset Zoom",
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
        // No default keyEquivalent: suspend is usually invoked
        // automatically (idle threshold / pressure event) and the
        // manual trigger is meant for IPC and palette users who
        // want to reclaim a specific pane on demand. A binding can
        // land later through the customisation phase.
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
        id: "browser_keep_active",
        title: "Keep Pane Active",
        // Toggles `PaneModel.isSuspendExempt` on the focused pane.
        // The validator flips both the enable state and the title so
        // the menu / palette label reflects what the next invocation
        // will do — same pattern as a soft toggle without a separate
        // "allow_suspension" action. Palette / menu bar / toast /
        // worklane all share the "Keep Pane Active" ↔ "Allow
        // Suspension" pair so a user looking at any of the four
        // surfaces reads the same wording.
        handler: { [weak self] in
          guard let self, let pane = self.focusedPane,
            pane.browserView != nil
          else { return }
          pane.isSuspendExempt.toggle()
          self.showToast(
            pane.isSuspendExempt ? "Keep Pane Active" : "Allow Suspension")
        },
        validate: { [weak self] in
          guard let self, let pane = self.focusedPane,
            pane.browserView != nil
          else { return (false, nil) }
          return (
            true,
            pane.isSuspendExempt ? "Allow Suspension" : "Keep Pane Active"
          )
        }
      ),
      Action(
        id: "open_settings",
        title: "Settings…",
        keyEquivalent: ",",
        handler: { [weak self] in
          SettingsWindowController.shared.paneContainer = self
          SettingsWindowController.shared.show()
        },
        separatorBefore: true
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
        title: "New Pane",
        menuTitle: "New Pane Here",
        keyEquivalent: "t",
        handler: { [weak self] in
          self?.addColumn(address: .newPaneHome)
          self?.showToast("New Pane")
        }
      ),
      Action(
        id: "new_finder_pane",
        title: "New Finder Pane",
        menuTitle: "New Finder Pane Here",
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
        id: "duplicate_pane",
        title: "Duplicate Pane",
        menuTitle: "Duplicate Pane",
        // Palette-only: browsers ship no standard duplicate-tab chord,
        // and claiming one here would risk a collision.
        handler: { [weak self] in self?.duplicateFocusedBrowserPane() },
        validate: { [weak self] in
          (self?.focusedPane?.browserView != nil, nil)
        }
      ),
      Action(
        id: "toggle_hidden_files",
        title: "Toggle Hidden Files",
        keyEquivalent: ".",
        modifierMask: [.command, .shift],
        // Flip the global finder-pane "show hidden files" setting.
        // Static label mirrors the other `toggle_*` actions that
        // read the action by intent ("Toggle Fold", "Toggle URL
        // Bar") rather than by post-flip state; the effect is
        // visible in the finder pane itself immediately on trigger.
        handler: { [weak self] in
          FinderSettings.toggleShowHiddenFiles()
          self?.showToast(
            FinderSettings.showHiddenFiles ? "Show Hidden Files" : "Hide Hidden Files")
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
        id: "open_tabs",
        title: "Open Tabs",
        keyEquivalent: "t",
        modifierMask: [.command, .option],
        handler: { [weak self] in self?.sidebarVC?.openMode(.tabs) }
      ),
      Action(
        id: "open_bookmarks",
        title: "Open Bookmarks",
        keyEquivalent: "b",
        modifierMask: [.command, .option],
        handler: { [weak self] in self?.sidebarVC?.openMode(.bookmarks) }
      ),
      Action(
        id: "open_history",
        title: "Open History",
        keyEquivalent: "y",
        handler: { [weak self] in self?.sidebarVC?.openMode(.history) }
      ),
      Action(
        id: "open_downloads",
        title: "Open Downloads",
        keyEquivalent: "l",
        modifierMask: [.command, .option],
        handler: { [weak self] in self?.sidebarVC?.openMode(.downloads) }
      ),
      Action(
        id: "open_extensions",
        title: "Open Extensions",
        keyEquivalent: "e",
        modifierMask: [.command, .option],
        handler: { [weak self] in self?.sidebarVC?.openMode(.extensions) }
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
          title: "Switch to \(ws.displayName(at: i))",
          handler: { [weak self] in self?.switchWorkspace(toId: wsId) }
        ))
    }
    for (i, ws) in workspaces.enumerated() where i != focusedWorkspaceIndex {
      let wsId = ws.id
      result.append(
        Action(
          id: "workspace_move_pane_\(wsId)",
          title: "Move Pane to \(ws.displayName(at: i))",
          handler: { [weak self] in self?.movePane(toWorkspaceId: wsId) }
        ))
    }

    // Dynamic actions: one "Focus: <title>" entry per pane across ALL
    // workspaces. `focusPane(id:)` switches workspace as needed, so the
    // command palette can jump anywhere by fuzzy-searching title. Labels
    // are prefixed with the workspace's display name for non-current
    // workspaces so users can disambiguate identical titles across
    // workspaces.
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
            : "\(ws.displayName(at: wsIdx)) · \(base)"
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

    let overrides = PreferencesStore.shared.preferences.keyboardShortcuts ?? [:]
    return result.map { $0.applyingOverride(overrides[$0.id]) }
  }

  static let defaultWidthCycle: [PaneWidthPreset] = [
    .points(640),
    .fraction(0.5),
    .fraction(0.33),
  ]

  /// Pick the cycle list the user is bound to: their explicit
  /// `widthCyclePresets` when present and non-empty, otherwise the
  /// built-in default. An empty user list falls through with a warning
  /// rather than disabling the action — the Settings UI prevents
  /// emptying via the delete button, but a hand-edited
  /// preferences.json can still arrive in that state.
  static func resolvedWidthCycle() -> [PaneWidthPreset] {
    let user = PreferencesStore.shared.preferences.widthCyclePresets
    if let user, !user.isEmpty { return user }
    if user != nil {
      logger.warning(
        "[settings/widthCycle] preset list empty, falling back to default")
    }
    return defaultWidthCycle
  }
}
