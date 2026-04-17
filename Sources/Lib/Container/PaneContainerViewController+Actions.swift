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
                id: "new_browser",
                title: "New Browser Column",
                keyEquivalent: "b",
                modifierMask: [.option, .control],
                handler: { [weak self] in self?.addColumn(address: .blankBrowser) }
            ),
            Action(
                id: "open_history",
                title: "Open History",
                handler: { [weak self] in self?.addColumn(address: .history) }
            ),
            Action(
                id: "open_bookmarks",
                title: "Open Bookmarks",
                handler: { [weak self] in self?.addColumn(address: .bookmarks) }
            ),
            Action(
                id: "open_downloads",
                title: "Open Downloads",
                handler: { [weak self] in self?.addColumn(address: .downloads) }
            ),
            Action(
                id: "command_palette",
                title: "Command Palette",
                keyEquivalent: "p",
                modifierMask: [.command, .shift],
                handler: { [weak self] in self?.toggleCommandPalette() }
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
        ]

        // Dynamic workspace actions: switch / move-pane, one entry per
        // non-current workspace. Capture the workspace id at registration
        // time so that deleting/reordering workspaces while the palette is
        // open can't misdirect the handler.
        for (i, ws) in workspaces.enumerated() where i != focusedWorkspaceIndex {
            let wsId = ws.id
            result.append(Action(
                id: "workspace_switch_\(wsId)",
                title: "Switch to Workspace \(i + 1)",
                handler: { [weak self] in self?.switchWorkspace(toId: wsId) }
            ))
        }
        for (i, ws) in workspaces.enumerated() where i != focusedWorkspaceIndex {
            let wsId = ws.id
            result.append(Action(
                id: "workspace_move_pane_\(wsId)",
                title: "Move Pane to Workspace \(i + 1)",
                handler: { [weak self] in self?.movePane(toWorkspaceId: wsId) }
            ))
        }

        // Dynamic actions: one "Focus: <title>" entry per pane. Generated
        // from the current pane layout so the command palette can jump to
        // any pane by fuzzy-searching its title.
        for (colIdx, column) in columns.enumerated() {
            for (paneIdx, pane) in column.panes.enumerated() {
                let label = pane.title.isEmpty
                    ? "Pane \(colIdx + 1)-\(paneIdx + 1)"
                    : pane.title
                // Capture pane.id instead of positional indices. The handler
                // resolves the current position at execution time so that
                // pane close/reorder between palette show and selection
                // doesn't silently focus the wrong pane.
                let targetId = pane.id
                result.append(Action(
                    id: "focus_pane_\(targetId)",
                    title: "Focus: \(label)",
                    handler: { [weak self] in
                        guard let self,
                              let colIdx = self.columns.firstIndex(where: {
                                  $0.panes.contains(where: { $0.id == targetId })
                              }),
                              let paneIdx = self.columns[colIdx].panes.firstIndex(where: {
                                  $0.id == targetId
                              })
                        else { return }
                        self.setFocus(columnIndex: colIdx, paneIndex: paneIdx)
                    }
                ))
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
