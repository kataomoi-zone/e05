import AppKit
import GhosttyKit

extension PaneContainerViewController {
    // MARK: - Session Save/Restore

    /// Capture the current layout as a serializable session state.
    public func captureSession() -> SessionState {
        let columnStates = columns.map { column -> SessionState.ColumnState in
            let paneStates = column.panes.map { pane -> SessionState.PaneState in
                var state = SessionState.PaneState(address: pane.address.description)
                // Save browser navigation history
                if let webView = pane.browserView?.webView {
                    let backList = webView.backForwardList.backList.map(\.url.absoluteString)
                    let forwardList = webView.backForwardList.forwardList.map(\.url.absoluteString)
                    if !backList.isEmpty { state.backHistory = backList }
                    if !forwardList.isEmpty { state.forwardHistory = forwardList }
                }
                return state
            }
            let width = Double(column.widthConstraint?.constant ?? defaultPaneWidth)

            // Capture height ratios from current frame sizes
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
        return SessionState(
            columns: columnStates,
            focusedColumnIndex: focusedColumnIndex,
            urlBarVisible: urlBarVisible
        )
    }

    /// Save current session to disk.
    public func saveSession() {
        captureSession().save()
    }

    /// Restore session from a saved state.
    func restoreSession(_ session: SessionState) {
        urlBarVisible = session.urlBarVisible

        for colState in session.columns {
            guard let firstPaneState = colState.panes.first else { continue }
            // Fall back to terminal for invalid addresses
            let firstAddress = PaneAddress(firstPaneState.address) ?? .terminal

            let column = addColumn(address: firstAddress)
            column.widthConstraint?.constant = CGFloat(colState.width)

            // Add remaining panes in the column
            for paneState in colState.panes.dropFirst() {
                let address = PaneAddress(paneState.address) ?? .terminal
                let pane = makePane(address: address)
                setupPaneCallbacks(pane: pane, column: column)
                column.panes.append(pane)
            }

            // TODO: browser back/forward history restoration requires custom
            // navigation stack (WKWebView.backForwardList is read-only). Phase 5.

            if column.panes.count > 1 {
                rebuildColumnView(column: column)

                // Apply height ratios (fall back to equal heights if mismatch)
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
                // else: keep default equal height constraints from rebuildColumnView
            }

            // Restore focused pane within column
            if colState.focusedPaneIndex < column.panes.count {
                column.focusedPaneIndex = colState.focusedPaneIndex
            }
        }

        view.layoutSubtreeIfNeeded()

        // Restore focused column
        let targetCol = min(session.focusedColumnIndex, columns.count - 1)
        if targetCol >= 0 {
            let targetPane = columns[targetCol].focusedPaneIndex
            setFocus(columnIndex: targetCol, paneIndex: targetPane)
        }
    }
}
