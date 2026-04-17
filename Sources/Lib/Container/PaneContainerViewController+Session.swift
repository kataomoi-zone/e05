import AppKit
import GhosttyKit

extension PaneContainerViewController {
    // MARK: - Session Save/Restore

    /// Capture the current layout as a serializable session state.
    public func captureSession() -> SessionState {
        // Snapshot the live scroll offset onto the current workspace so it's
        // included in the save. Other workspaces already have their scrollX
        // recorded when they were last switched away from.
        currentWorkspace.scrollX = scrollView.contentView.bounds.origin.x

        let workspaceStates = workspaces.map { ws -> SessionState.WorkspaceState in
            let columnStates = ws.columns.map { column -> SessionState.ColumnState in
                let paneStates = column.panes.map { pane -> SessionState.PaneState in
                    var state = SessionState.PaneState(address: pane.address.description)
                    if let webView = pane.browserView?.webView {
                        let backList = webView.backForwardList.backList.map(\.url.absoluteString)
                        let forwardList = webView.backForwardList.forwardList.map(\.url.absoluteString)
                        if !backList.isEmpty { state.backHistory = backList }
                        if !forwardList.isEmpty { state.forwardHistory = forwardList }
                    }
                    return state
                }
                let width = Double(column.widthConstraint?.constant ?? defaultPaneWidth)

                var heightRatios: [Double] = []
                if column.panes.count > 1, let firstHeight = column.panes.first?.containerView.frame.height, firstHeight > 0 {
                    heightRatios = column.panes.dropFirst().map { pane in
                        pane.containerView.frame.height / firstHeight
                    }
                }

                return SessionState.ColumnState(
                    panes: paneStates,
                    focusedPaneIndex: column.focusedPaneIndex,
                    width: width,
                    heightRatios: heightRatios
                )
            }
            return SessionState.WorkspaceState(
                columns: columnStates,
                focusedColumnIndex: ws.focusedColumnIndex,
                scrollX: Double(ws.scrollX)
            )
        }

        return SessionState(
            workspaces: workspaceStates,
            focusedWorkspaceIndex: focusedWorkspaceIndex,
            urlBarVisible: urlBarVisible
        )
    }

    /// Save current session to disk.
    public func saveSession() {
        captureSession().save()
    }

    /// Restore session from a saved state.
    func restoreSession(_ session: SessionState) {
        // Set first so that `setupPaneCallbacks`, run per-pane inside the
        // restore loop below, can push the right visibility state onto
        // each newly created URL bar.
        urlBarVisible = session.urlBarVisible
        guard !session.workspaces.isEmpty else { return }

        // Replace the default empty workspace with the persisted set.
        workspaces.removeAll()

        for wsState in session.workspaces {
            let ws = WorkspaceModel()
            ws.scrollX = CGFloat(wsState.scrollX)
            workspaces.append(ws)

            // Make this workspace current so addColumn/makePane target it.
            // addColumn will also rebuild the shared stackView — all the
            // column views accumulated across workspaces get detached below
            // before the final switch.
            focusedWorkspaceIndex = workspaces.count - 1

            for colState in wsState.columns {
                guard let firstPaneState = colState.panes.first else { continue }
                let firstAddress = PaneAddress(firstPaneState.address) ?? .terminal

                let column = addColumn(address: firstAddress)
                column.widthConstraint?.constant = CGFloat(colState.width)

                for paneState in colState.panes.dropFirst() {
                    let address = PaneAddress(paneState.address) ?? .terminal
                    let pane = makePane(address: address)
                    setupPaneCallbacks(pane: pane, column: column)
                    column.panes.append(pane)
                }

                // TODO: browser back/forward history restoration requires a
                // custom navigation stack (WKWebView.backForwardList is
                // read-only).

                if column.panes.count > 1 {
                    rebuildColumnView(column: column)

                    let expectedRatios = column.panes.count - 1
                    if colState.heightRatios.count == expectedRatios {
                        NSLayoutConstraint.deactivate(column.equalHeightConstraints)
                        column.equalHeightConstraints.removeAll()
                        let firstCV = column.panes[0].containerView
                        for (i, ratio) in colState.heightRatios.enumerated() {
                            let c = column.panes[i + 1].containerView.heightAnchor.constraint(
                                equalTo: firstCV.heightAnchor, multiplier: ratio
                            )
                            c.isActive = true
                            column.equalHeightConstraints.append(c)
                        }
                    }
                }

                if (0..<column.panes.count).contains(colState.focusedPaneIndex) {
                    column.focusedPaneIndex = colState.focusedPaneIndex
                }
            }

            if !ws.columns.isEmpty {
                ws.focusedColumnIndex = min(max(wsState.focusedColumnIndex, 0), ws.columns.count - 1)
            }
        }

        // Detach every workspace's column views from the stack view; mark
        // their terminals as preserve-on-detach so surfaces survive the
        // re-arrangement that follows.
        for ws in workspaces {
            preserveSurfaces(in: ws)
            for column in ws.columns {
                column.containerView.removeFromSuperview()
            }
        }

        // Drop workspaces that ended up empty (e.g. all addresses unparseable).
        // Invariant: no empty workspace, and at least one workspace must exist.
        workspaces.removeAll { $0.columns.isEmpty }
        if workspaces.isEmpty {
            workspaces.append(WorkspaceModel())
        }

        focusedWorkspaceIndex = min(max(session.focusedWorkspaceIndex, 0), workspaces.count - 1)
        rebuildStackView()
        view.layoutSubtreeIfNeeded()
        restoreFocusInCurrentWorkspace()
        restoreScroll(in: currentWorkspace)
    }
}
