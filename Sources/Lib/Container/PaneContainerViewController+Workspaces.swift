import AppKit

extension PaneContainerViewController {
    // MARK: - Limits

    /// Upper bound on concurrent workspaces. Fixed in Phase 8-1; will move
    /// to user config in Phase 11.
    public static let maxWorkspaces = 5

    public var canCreateWorkspace: Bool {
        workspaces.count < Self.maxWorkspaces
    }

    // MARK: - Accent color palette

    /// Fixed palette mapped positionally: `palette[i]` is the color for the
    /// workspace displayed as "Workspace \(i + 1)". Because it tracks array
    /// position — not an id baked into the workspace itself — number and
    /// color stay aligned when workspaces are added or removed.
    public static let accentColorPalette: [NSColor] = [
        .systemBlue,
        .systemGreen,
        .systemOrange,
        .systemPurple,
        .systemRed,
    ]

    /// Accent color for the workspace at `position`. Returns the first
    /// palette entry for out-of-range indices so callers (e.g. the focus
    /// border during a transient empty-state) stay total. Falls back all
    /// the way to `.systemBlue` if the palette itself is empty, keeping
    /// this function total even under that theoretically impossible state.
    public static func accentColor(forWorkspaceAt position: Int) -> NSColor {
        accentColorPalette[safe: position] ?? accentColorPalette.first ?? .systemBlue
    }

    // MARK: - Switching

    /// Switch to the workspace at `index`. Detaches the current workspace's
    /// column views from the shared stack view and rebuilds it from the
    /// target's columns. Terminal surfaces in the outgoing workspace stay
    /// alive across the detach, so switching back preserves scrollback and
    /// process state.
    public func switchWorkspace(to index: Int) {
        guard index != focusedWorkspaceIndex,
              workspaces.indices.contains(index) else { return }

        let outgoing = currentWorkspace
        outgoing.scrollX = scrollView.contentView.bounds.origin.x
        preserveSurfaces(in: outgoing)

        detachCurrentWorkspaceViews()
        focusedWorkspaceIndex = index
        rebuildStackView()
        view.layoutSubtreeIfNeeded()
        restoreFocusInCurrentWorkspace()
        restoreScroll(in: currentWorkspace)
    }

    public func switchWorkspace(toId id: ULID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
        switchWorkspace(to: idx)
    }

    // MARK: - Creation

    /// Create a new workspace with an auto-assigned accent color and an
    /// initial terminal column, then switch focus to it.
    public func createWorkspace() {
        guard canCreateWorkspace else { return }

        let outgoing = currentWorkspace
        outgoing.scrollX = scrollView.contentView.bounds.origin.x
        preserveSurfaces(in: outgoing)

        let newWorkspace = WorkspaceModel()

        detachCurrentWorkspaceViews()
        workspaces.append(newWorkspace)
        focusedWorkspaceIndex = workspaces.count - 1

        // Invariant: every workspace owns at least one column. `addColumn`
        // inserts into `currentWorkspace.columns` (now the new workspace)
        // and calls `rebuildStackView` + `setFocus` itself.
        addColumn(address: .terminal)
    }

    // MARK: - Closing

    /// Close the current workspace. Flushes the recently-closed stack (its
    /// stashed surfaces belong to the workspace we're discarding) and
    /// terminates the app when the last workspace is gone.
    public func closeCurrentWorkspace() {
        let closing = currentWorkspace

        for column in closing.columns {
            for pane in column.panes {
                // Let the normal surface-free path run when views are detached.
                pane.terminalView?.keepSurfaceAlive = false
                clearFocusBorder(pane)
            }
            column.containerView.removeFromSuperview()
        }

        flushRecentlyClosed(in: closing)

        workspaces.remove(at: focusedWorkspaceIndex)

        if workspaces.isEmpty {
            // Last workspace: close the window. viewDidUnload / applicationWill
            // Terminate handles final cleanup of the now-orphan workspace state.
            view.window?.close()
            return
        }

        focusedWorkspaceIndex = min(focusedWorkspaceIndex, workspaces.count - 1)
        rebuildStackView()
        view.layoutSubtreeIfNeeded()
        restoreFocusInCurrentWorkspace()
        restoreScroll(in: currentWorkspace)
    }

    // MARK: - Move pane across workspaces

    /// Move the focused pane into the target workspace as a new single-pane
    /// column at its right edge. The pane's surface is preserved across the
    /// move. If the source column/workspace is left empty, it collapses per
    /// the standard invariants.
    public func movePane(toWorkspaceId id: ULID) {
        guard let target = workspaces.firstIndex(where: { $0.id == id }),
              target != focusedWorkspaceIndex,
              let column = columns[safe: focusedColumnIndex],
              let pane = column.focusedPane else { return }
        let paneIndex = column.focusedPaneIndex
        let sourceIndex = focusedWorkspaceIndex
        let sourceWs = workspaces[sourceIndex]

        // Preserve surfaces on the outgoing side — both the pane being moved
        // and any other panes left behind in source-workspace columns that
        // will detach when we switch away.
        sourceWs.scrollX = scrollView.contentView.bounds.origin.x
        preserveSurfaces(in: sourceWs)

        // 1. Detach pane from source column.
        clearFocusBorder(pane)
        pane.containerView.removeFromSuperview()
        column.panes.remove(at: paneIndex)

        var adjustedTarget = target

        if column.panes.isEmpty {
            // Source column empty → remove it (propagate to workspace removal)
            column.containerView.removeFromSuperview()
            workspaces[sourceIndex].columns.removeAll { $0 === column }

            if workspaces[sourceIndex].columns.isEmpty {
                workspaces.remove(at: sourceIndex)
                if adjustedTarget > sourceIndex { adjustedTarget -= 1 }
            } else {
                let srcWs = workspaces[sourceIndex]
                srcWs.focusedColumnIndex = min(srcWs.focusedColumnIndex, srcWs.columns.count - 1)
            }
        } else {
            column.focusedPaneIndex = min(paneIndex, column.panes.count - 1)
            rebuildColumnView(column: column)
        }

        // 2. Detach whatever column views remain in the (still-extant) source
        //    workspace before rebuilding for the target. `sourceIndex !=
        //    adjustedTarget` would be redundant: the function-entry guard
        //    ensures `target != focusedWorkspaceIndex == sourceIndex`, and
        //    adjustedTarget only shifts when source is removed (in which
        //    case indices.contains rejects it).
        if workspaces.indices.contains(sourceIndex) {
            for col in workspaces[sourceIndex].columns {
                col.containerView.removeFromSuperview()
            }
        }

        // 3. Switch to target workspace and append a fresh single-pane column.
        focusedWorkspaceIndex = adjustedTarget

        let newColumn = ColumnModel(pane: pane)
        setupPaneCallbacks(pane: pane, column: newColumn)
        let cv = pane.containerView
        newColumn.containerView.addArrangedSubview(cv)
        NSLayoutConstraint.activate([
            cv.leadingAnchor.constraint(equalTo: newColumn.containerView.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: newColumn.containerView.trailingAnchor),
        ])
        attachFoldedLabel(to: newColumn)
        let wc = newColumn.containerView.widthAnchor.constraint(equalToConstant: defaultPaneWidth)
        wc.isActive = true
        newColumn.widthConstraint = wc

        let targetWs = currentWorkspace
        targetWs.columns.append(newColumn)
        let newIdx = targetWs.columns.count - 1
        targetWs.focusedColumnIndex = newIdx

        rebuildStackView()
        view.layoutSubtreeIfNeeded()
        setFocus(columnIndex: newIdx, paneIndex: 0)
    }

    // MARK: - Helpers

    /// Remove the current workspace's column container views from the shared
    /// stack view. `removeArrangedSubview` alone leaves them as subviews, so
    /// `removeFromSuperview` is required to clear them fully.
    func detachCurrentWorkspaceViews() {
        for column in currentWorkspace.columns {
            column.containerView.removeFromSuperview()
        }
    }

    /// Release stashed undo-close surfaces belonging to the given workspace.
    /// Called when that workspace is being torn down — their (colIdx, paneIdx)
    /// references would be meaningless once the workspace is gone. Stash
    /// entries owned by other workspaces are left alone so undo still works
    /// there after a switch.
    func flushRecentlyClosed(in workspace: WorkspaceModel) {
        recentlyClosed.removeAll { closed in
            guard closed.workspaceId == workspace.id else { return false }
            closed.timer.invalidate()
            closed.pane.terminalView?.releaseDetachedSurface()
            return true
        }
    }

    /// Restore focus to the current workspace's remembered pane position,
    /// clamping indices in case columns/panes were removed. Callers are
    /// expected to follow up with `restoreScroll(in:)` — scrolling is
    /// suppressed here so the workspace's saved offset isn't clobbered.
    func restoreFocusInCurrentWorkspace() {
        let ws = currentWorkspace
        guard !ws.columns.isEmpty else { return }
        let colIdx = min(max(ws.focusedColumnIndex, 0), ws.columns.count - 1)
        let column = ws.columns[colIdx]
        let paneIdx = min(max(column.focusedPaneIndex, 0), column.panes.count - 1)
        setFocus(columnIndex: colIdx, paneIndex: paneIdx, scroll: false)
    }

    /// Mark all terminal surfaces in the workspace as "keep alive" so that
    /// detaching their container views from the stack view doesn't free the
    /// underlying ghostty surface. The flag is left sticky across workspace
    /// switches — it's overwritten only by the next `preserveSurfaces`
    /// call, `removePane` (flips false on explicit close), or
    /// `closeCurrentWorkspace` (flips false before final detach). That lets
    /// surfaces survive repeated switch cycles without leaking.
    func preserveSurfaces(in workspace: WorkspaceModel) {
        for column in workspace.columns {
            for pane in column.panes {
                pane.terminalView?.keepSurfaceAlive = true
            }
        }
    }

    /// Restore the workspace's saved horizontal scroll position. Called
    /// after `restoreFocusInCurrentWorkspace` to override the default
    /// "scroll-to-focused-column" behavior — we want switching back to
    /// land the user exactly where they left off.
    func restoreScroll(in workspace: WorkspaceModel) {
        scrollView.contentView.setBoundsOrigin(NSPoint(x: workspace.scrollX, y: 0))
    }
}
