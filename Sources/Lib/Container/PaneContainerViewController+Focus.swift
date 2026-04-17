import AppKit
import GhosttyKit

extension PaneContainerViewController {
    // MARK: - Focus

    public func setFocus(columnIndex: Int, paneIndex: Int) {
        guard columns.indices.contains(columnIndex) else { return }
        guard let column = columns[safe: columnIndex],
              column.panes.indices.contains(paneIndex) else { return }

        if let previousPane = focusedPane {
            clearFocusBorder(previousPane)
            hideHeaderForPane(previousPane)
        }

        focusedColumnIndex = columnIndex
        column.focusedPaneIndex = paneIndex

        let pane = column.panes[paneIndex]
        applyFocusBorder(pane)
        if pane.isBlankBrowser {
            if !pane.isURLBarVisible {
                pane.setURLBarVisible(true)
            }
            pane.urlBar.focusURLField()
        } else {
            view.window?.makeFirstResponder(pane.preferredFirstResponder)
        }
        updateHandleActiveStates()
        showHeaderForFocusedPane()
        scrollToColumn(at: columnIndex)
    }

    public func focusLeft() {
        guard focusedColumnIndex > 0 else { return }
        let newColIndex = focusedColumnIndex - 1
        let paneIndex = columns[newColIndex].focusedPaneIndex
        setFocus(columnIndex: newColIndex, paneIndex: paneIndex)
    }

    public func focusRight() {
        guard focusedColumnIndex < columns.count - 1 else { return }
        let newColIndex = focusedColumnIndex + 1
        let paneIndex = columns[newColIndex].focusedPaneIndex
        setFocus(columnIndex: newColIndex, paneIndex: paneIndex)
    }

    public func focusUp() {
        guard let column = columns[safe: focusedColumnIndex],
              column.focusedPaneIndex > 0 else { return }
        setFocus(columnIndex: focusedColumnIndex, paneIndex: column.focusedPaneIndex - 1)
    }

    public func focusDown() {
        guard let column = columns[safe: focusedColumnIndex],
              column.focusedPaneIndex < column.panes.count - 1 else { return }
        setFocus(columnIndex: focusedColumnIndex, paneIndex: column.focusedPaneIndex + 1)
    }

    // MARK: - Width Preset Cycle

    /// Cycle the focused column's width through the given preset list.
    public func cycleWidthPreset(_ cycle: [PaneWidthPreset]) {
        guard !cycle.isEmpty, let column = columns[safe: focusedColumnIndex] else { return }

        let nextIndex: Int
        if let current = column.currentPreset,
           let idx = cycle.firstIndex(of: current)
        {
            nextIndex = (idx + 1) % cycle.count
        } else {
            nextIndex = 0
        }

        let preset = cycle[nextIndex]
        column.currentPreset = preset
        applyPreset(preset, to: column)
        view.layoutSubtreeIfNeeded()
        scrollToColumn(at: focusedColumnIndex)
    }

    private func applyPreset(_ preset: PaneWidthPreset, to column: ColumnModel) {
        guard let constraint = column.widthConstraint else { return }
        switch preset {
        case .columns(let n):
            guard let pane = column.focusedPane,
                  let surface = pane.terminalView?.surface,
                  let scale = pane.terminalView?.window?.backingScaleFactor
            else { return }
            let size = ghostty_surface_size(surface)
            guard size.cell_width_px > 0 else { return }
            constraint.constant = CGFloat(n) * CGFloat(size.cell_width_px) / scale
        case .fraction(let f):
            let visibleWidth = scrollView.contentView.bounds.width
            guard visibleWidth > 0 else { return }
            constraint.constant = visibleWidth * f
        }
    }

    // MARK: - Column Reorder

    public func moveColumnLeft() {
        guard focusedColumnIndex > 0 else { return }
        columns.swapAt(focusedColumnIndex, focusedColumnIndex - 1)
        focusedColumnIndex -= 1
        rebuildStackView()
        view.layoutSubtreeIfNeeded()
        setFocus(columnIndex: focusedColumnIndex, paneIndex: columns[focusedColumnIndex].focusedPaneIndex)
    }

    public func moveColumnRight() {
        guard focusedColumnIndex < columns.count - 1 else { return }
        columns.swapAt(focusedColumnIndex, focusedColumnIndex + 1)
        focusedColumnIndex += 1
        rebuildStackView()
        view.layoutSubtreeIfNeeded()
        setFocus(columnIndex: focusedColumnIndex, paneIndex: columns[focusedColumnIndex].focusedPaneIndex)
    }

    // MARK: - Pane Reorder within Column

    public func movePaneUp() {
        guard let column = columns[safe: focusedColumnIndex],
              column.focusedPaneIndex > 0 else { return }
        let idx = column.focusedPaneIndex
        column.panes.swapAt(idx, idx - 1)
        column.focusedPaneIndex = idx - 1
        rebuildColumnView(column: column)
        view.layoutSubtreeIfNeeded()
        setFocus(columnIndex: focusedColumnIndex, paneIndex: column.focusedPaneIndex)
    }

    public func movePaneDown() {
        guard let column = columns[safe: focusedColumnIndex],
              column.focusedPaneIndex < column.panes.count - 1 else { return }
        let idx = column.focusedPaneIndex
        column.panes.swapAt(idx, idx + 1)
        column.focusedPaneIndex = idx + 1
        rebuildColumnView(column: column)
        view.layoutSubtreeIfNeeded()
        setFocus(columnIndex: focusedColumnIndex, paneIndex: column.focusedPaneIndex)
    }

    // MARK: - Stack View Rebuild

    /// Rebuild arrangedSubviews from columns array, inserting resize handles between columns.
    func rebuildStackView() {
        for v in stackView.arrangedSubviews.reversed() {
            stackView.removeArrangedSubview(v)
            if v is PaneResizeHandle { v.removeFromSuperview() }
        }
        for (i, column) in columns.enumerated() {
            if i > 0 {
                let handle = makeColumnResizeHandle(leftIndex: i - 1, rightIndex: i)
                stackView.addArrangedSubview(handle)
                NSLayoutConstraint.activate(PaneResizeHandle.makeConstraints(for: handle))
            }
            stackView.addArrangedSubview(column.containerView)
        }
        // Add a trailing resize handle on the last column so single-pane layouts can be resized
        if let lastIndex = columns.indices.last {
            let handle = makeTrailingResizeHandle(columnIndex: lastIndex)
            stackView.addArrangedSubview(handle)
            NSLayoutConstraint.activate(PaneResizeHandle.makeConstraints(for: handle))
        }
    }

    private func makeTrailingResizeHandle(columnIndex: Int) -> PaneResizeHandle {
        let handle = PaneResizeHandle(orientation: .horizontal)
        let column = columns[columnIndex]
        // Active state is managed by updateHandleActiveStates (left-side neighbor === focused column).
        // mouseDown blocks drag when !isActive, so onDrag doesn't need to re-check focus.
        handle.onDrag = { [weak self, weak column] deltaX in
            guard let self, let column, let constraint = column.widthConstraint else { return }
            let newWidth = max(self.minPaneWidth, constraint.constant + deltaX)
            constraint.constant = newWidth
            column.currentPreset = nil
        }
        return handle
    }

    private func makeColumnResizeHandle(leftIndex: Int, rightIndex: Int) -> PaneResizeHandle {
        let handle = PaneResizeHandle(orientation: .horizontal)
        let leftColumn = columns[leftIndex]
        let rightColumn = columns[rightIndex]
        handle.onDrag = { [weak self, weak leftColumn, weak rightColumn] deltaX in
            guard let self, let leftColumn, let rightColumn else { return }
            let isLeftFocused = leftColumn.id == self.columns[safe: self.focusedColumnIndex]?.id
            let isRightFocused = rightColumn.id == self.columns[safe: self.focusedColumnIndex]?.id
            guard isLeftFocused || isRightFocused else { return }
            let focusedColumn = isLeftFocused ? leftColumn : rightColumn
            guard let constraint = focusedColumn.widthConstraint else { return }
            let sign: CGFloat = isLeftFocused ? 1 : -1
            let newWidth = max(self.minPaneWidth, constraint.constant + deltaX * sign)
            let actualDelta = newWidth - constraint.constant
            constraint.constant = newWidth
            focusedColumn.currentPreset = nil
            if isRightFocused, actualDelta != 0 {
                var origin = self.scrollView.contentView.bounds.origin
                origin.x += actualDelta
                self.scrollView.contentView.setBoundsOrigin(origin)
            }
        }
        return handle
    }

    /// Rebuild the containerView of a column from its panes array.
    /// Inserts vertical resize handles between panes and sets equal height constraints.
    func rebuildColumnView(column: ColumnModel) {
        // Clean up old constraints and views
        NSLayoutConstraint.deactivate(column.equalHeightConstraints)
        column.equalHeightConstraints.removeAll()
        for v in column.containerView.arrangedSubviews.reversed() {
            column.containerView.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        var firstCV: NSView?
        for (i, pane) in column.panes.enumerated() {
            if i > 0 {
                let handle = makeVerticalResizeHandle(column: column, topIndex: i - 1, bottomIndex: i)
                column.containerView.addArrangedSubview(handle)
                NSLayoutConstraint.activate(PaneResizeHandle.makeConstraints(for: handle))
            }
            let cv = pane.containerView
            column.containerView.addArrangedSubview(cv)
            NSLayoutConstraint.activate([
                cv.leadingAnchor.constraint(equalTo: column.containerView.leadingAnchor),
                cv.trailingAnchor.constraint(equalTo: column.containerView.trailingAnchor),
            ])
            // Equal height constraints between all panes (deactivated on drag)
            if let first = firstCV {
                let c = cv.heightAnchor.constraint(equalTo: first.heightAnchor)
                c.isActive = true
                column.equalHeightConstraints.append(c)
            } else {
                firstCV = cv
            }
        }

        // addArrangedSubview appends to subviews (back to front), which would sink
        // the foldedLabelView behind pane views. Re-hoist it to the front so the
        // overlay stays on top when the column is folded.
        if column.foldedLabelView.superview === column.containerView {
            column.containerView.addSubview(column.foldedLabelView, positioned: .above, relativeTo: nil)
        }
    }

    private func makeVerticalResizeHandle(column: ColumnModel, topIndex: Int, bottomIndex: Int) -> PaneResizeHandle {
        let handle = PaneResizeHandle(orientation: .vertical)
        // Vertical handles are always active within a column (unlike horizontal
        // handles which are only active adjacent to the focused column).
        handle.isActive = true
        let topPaneId = column.panes[topIndex].id
        let bottomPaneId = column.panes[bottomIndex].id
        handle.onDrag = { [weak self, weak column] deltaY in
            guard let self, let column, column.panes.count > 1,
                  let topIdx = column.panes.firstIndex(where: { $0.id == topPaneId }),
                  let bottomIdx = column.panes.firstIndex(where: { $0.id == bottomPaneId })
            else { return }
            let topPane = column.panes[topIdx]
            let bottomPane = column.panes[bottomIdx]

            // AppKit Y is up, so dragging down (negative deltaY) should grow the top pane
            let newTopHeight = topPane.containerView.frame.height - deltaY
            let newBottomHeight = bottomPane.containerView.frame.height + deltaY
            guard newTopHeight >= self.minPaneHeight, newBottomHeight >= self.minPaneHeight else { return }

            // Replace all height constraints with ratio constraints relative to first pane.
            // Ratio constraints fill the container naturally — no absolute heights needed.
            NSLayoutConstraint.deactivate(column.equalHeightConstraints)
            column.equalHeightConstraints.removeAll()

            let firstCV = column.panes[0].containerView
            // Use current frame heights (with the drag delta applied to the two panes)
            for (i, pane) in column.panes.enumerated() where i > 0 {
                let currentHeight: CGFloat
                if pane.id == topPane.id {
                    currentHeight = newTopHeight
                } else if pane.id == bottomPane.id {
                    currentHeight = newBottomHeight
                } else {
                    currentHeight = pane.containerView.frame.height
                }
                let firstHeight = (column.panes[0].id == topPane.id) ? newTopHeight :
                                  (column.panes[0].id == bottomPane.id) ? newBottomHeight :
                                  firstCV.frame.height
                guard firstHeight > 0 else { continue }
                let ratio = currentHeight / firstHeight
                let c = pane.containerView.heightAnchor.constraint(
                    equalTo: firstCV.heightAnchor, multiplier: ratio
                )
                c.isActive = true
                column.equalHeightConstraints.append(c)
            }
        }
        return handle
    }

    /// Update which resize handles are active based on focused column.
    func updateHandleActiveStates() {
        guard let focusedColumn = columns[safe: focusedColumnIndex] else { return }
        for v in stackView.arrangedSubviews {
            guard let handle = v as? PaneResizeHandle else { continue }
            guard let handleIndex = stackView.arrangedSubviews.firstIndex(of: handle) else { continue }
            let leftView = stackView.arrangedSubviews[safe: handleIndex - 1]
            let rightView = stackView.arrangedSubviews[safe: handleIndex + 1]
            handle.isActive = leftView === focusedColumn.containerView
                || rightView === focusedColumn.containerView
        }
    }

    // MARK: - Focus Indicator

    func applyFocusBorder(_ pane: PaneModel) {
        // Apply to pane.containerView
        let cv = pane.containerView
        cv.wantsLayer = true
        cv.layer?.borderWidth = focusBorderWidth
        cv.layer?.borderColor = focusBorderColor.cgColor

        // If pane is in a folded column, also border the folded label so the
        // focus is visible while panes are hidden.
        if let column = columns.first(where: { $0.panes.contains(where: { $0.id == pane.id }) }),
           column.isFolded
        {
            column.foldedLabelView.wantsLayer = true
            column.foldedLabelView.layer?.borderWidth = focusBorderWidth
            column.foldedLabelView.layer?.borderColor = focusBorderColor.cgColor
        }
    }

    func clearFocusBorder(_ pane: PaneModel) {
        let cv = pane.containerView
        cv.layer?.borderWidth = 0
        cv.layer?.borderColor = nil

        if let column = columns.first(where: { $0.panes.contains(where: { $0.id == pane.id }) }) {
            column.foldedLabelView.layer?.borderWidth = 0
            column.foldedLabelView.layer?.borderColor = nil
        }
    }

    // MARK: - Scrolling

    func scrollToColumn(at index: Int) {
        guard let column = columns[safe: index] else { return }
        let targetView = column.containerView

        view.layoutSubtreeIfNeeded()

        let columnFrame = targetView.frame
        let visibleWidth = scrollView.contentView.bounds.width
        let contentWidth = stackView.frame.width

        if contentWidth <= visibleWidth { return }

        let targetX: CGFloat
        if columnFrame.width >= visibleWidth {
            targetX = columnFrame.minX
        } else {
            targetX = columnFrame.midX - visibleWidth / 2
        }

        let maxScrollX = contentWidth - visibleWidth
        let clampedX = max(0, min(maxScrollX, targetX))

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scrollView.contentView.animator().bounds.origin.x = clampedX
        }
    }

    // MARK: - Event Handlers

    /// Called when a GhosttyTerminalView gains focus via click.
    func handleFocusChange(from pane: PaneModel) {
        for (colIdx, column) in columns.enumerated() {
            if let paneIdx = column.panes.firstIndex(where: { $0.id == pane.id }) {
                guard colIdx != focusedColumnIndex || paneIdx != column.focusedPaneIndex else { return }
                setFocus(columnIndex: colIdx, paneIndex: paneIdx)
                return
            }
        }
    }
}
