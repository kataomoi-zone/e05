import AppKit
import GhosttyKit

/// NSScrollView that forces overlay scrollers regardless of system preference.
/// Overrides the getter to always return .overlay, and re-applies on system
/// preference changes (e.g. mouse connect/disconnect).
private final class OverlayScrollView: NSScrollView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollerStyleDidChange),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    @objc private func scrollerStyleDidChange(_ notification: Notification) {
        super.scrollerStyle = .overlay
    }
}

public final class PaneContainerViewController: NSViewController {
    private let ghosttyApp: GhosttyApp

    private let scrollView = OverlayScrollView()
    private let stackView = NSStackView()

    public private(set) var columns: [ColumnModel] = []
    private var focusedColumnIndex: Int = 0

    private var focusedPane: PaneModel? {
        columns[safe: focusedColumnIndex]?.focusedPane
    }

    private let defaultPaneWidth: CGFloat = 640
    private let minPaneWidth: CGFloat = 100
    private let minPaneHeight: CGFloat = 50
    private let focusBorderWidth: CGFloat = 2
    private let focusBorderColor: NSColor = .systemBlue

    nonisolated(unsafe) private var scrollEventMonitor: Any?

    // MARK: - Init

    public init(ghosttyApp: GhosttyApp) {
        self.ghosttyApp = ghosttyApp
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    // MARK: - Lifecycle

    public override func loadView() {
        view = NSView()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        configureScrollView()
        installScrollEventMonitor()
        addColumn()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        DispatchQueue.main.async { [weak self] in
            self?.scrollView.scrollerStyle = .overlay
        }
    }

    private var isUpdatingLayout = false

    public override func viewDidLayout() {
        super.viewDidLayout()
        guard !isUpdatingLayout else { return }
        isUpdatingLayout = true
        let visibleWidth = scrollView.contentView.bounds.width
        for column in columns {
            // Recalculate fraction-based width presets on window resize
            if case .fraction(let f) = column.currentPreset, visibleWidth > 0 {
                column.widthConstraint?.constant = visibleWidth * f
            }
            for pane in column.panes {
                pane.terminalView.setFrameSize(pane.terminalView.frame.size)
            }
        }
        isUpdatingLayout = false
    }

    deinit {
        if let monitor = scrollEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Scroll View

    private func configureScrollView() {
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.5, alpha: 1.0) // neutral gray
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true

        stackView.orientation = .horizontal
        stackView.spacing = 0  // handles serve as spacing between panes
        stackView.detachesHiddenViews = false

        scrollView.documentView = stackView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
        ])
    }

    /// Intercept horizontal scroll events before GhosttyTerminalView consumes them.
    private func installScrollEventMonitor() {
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            guard let self else { return event }

            let locationInView = self.scrollView.convert(event.locationInWindow, from: nil)
            guard self.scrollView.bounds.contains(locationInView) else { return event }

            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                self.scrollView.scrollWheel(with: event)
                return nil
            }

            return event
        }
    }

    // MARK: - Column Management

    @discardableResult
    public func addColumn() -> ColumnModel {
        let pane = PaneModel(ghosttyApp: ghosttyApp)
        let column = ColumnModel(pane: pane)

        setupPaneCallbacks(pane: pane, column: column)

        let tv = pane.terminalView

        // Add terminalView to column's containerView
        column.containerView.addArrangedSubview(tv)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: column.containerView.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: column.containerView.trailingAnchor),
        ])

        // Width constraint on the containerView
        let wc = column.containerView.widthAnchor.constraint(equalToConstant: defaultPaneWidth)
        wc.isActive = true
        column.widthConstraint = wc

        let insertIndex = columns.isEmpty ? 0 : focusedColumnIndex + 1
        columns.insert(column, at: insertIndex)

        rebuildStackView()
        view.layoutSubtreeIfNeeded()
        setFocus(columnIndex: insertIndex, paneIndex: 0)
        return column
    }

    private func setupPaneCallbacks(pane: PaneModel, column: ColumnModel) {
        pane.terminalView.onFocusChanged = { [weak self, weak pane] focused in
            guard let self, let pane, focused else { return }
            self.handleFocusChange(from: pane)
        }

        pane.terminalView.onClose = { [weak self, weak pane] in
            guard let self, let pane else { return }
            for (colIdx, col) in self.columns.enumerated() {
                if let paneIdx = col.panes.firstIndex(where: { $0.id == pane.id }) {
                    self.removePane(columnIndex: colIdx, paneIndex: paneIdx)
                    return
                }
            }
        }
    }

    // MARK: - Vertical Split

    public func splitVertical() {
        guard let column = columns[safe: focusedColumnIndex] else { return }

        let newPane = PaneModel(ghosttyApp: ghosttyApp)
        setupPaneCallbacks(pane: newPane, column: column)

        let insertPaneIndex = column.focusedPaneIndex + 1
        column.panes.insert(newPane, at: insertPaneIndex)

        rebuildColumnView(column: column)
        view.layoutSubtreeIfNeeded()
        setFocus(columnIndex: focusedColumnIndex, paneIndex: insertPaneIndex)
    }

    // MARK: - Pane Removal

    private func removePane(columnIndex: Int, paneIndex: Int) {
        guard let column = columns[safe: columnIndex],
              column.panes.indices.contains(paneIndex) else { return }

        let pane = column.panes.remove(at: paneIndex)
        clearFocusBorder(pane)

        if column.panes.isEmpty {
            // Remove column
            columns.remove(at: columnIndex)
            column.containerView.removeFromSuperview()

            if columns.isEmpty {
                for v in stackView.arrangedSubviews { v.removeFromSuperview() }
                view.window?.close()
                return
            }

            rebuildStackView()
            let newColIndex = min(columnIndex, columns.count - 1)
            setFocus(columnIndex: newColIndex, paneIndex: 0)
        } else {
            pane.terminalView.removeFromSuperview()
            rebuildColumnView(column: column)
            let newPaneIndex = min(paneIndex, column.panes.count - 1)
            setFocus(columnIndex: columnIndex, paneIndex: newPaneIndex)
        }
    }

    /// Close the focused pane. Shows a confirmation dialog if a process is running.
    public func removeCurrentPane() {
        guard let column = columns[safe: focusedColumnIndex],
              let pane = column.focusedPane else { return }
        if let surface = pane.terminalView.surface,
           ghostty_surface_needs_confirm_quit(surface)
        {
            let alert = NSAlert()
            alert.messageText = "Close this pane?"
            alert.informativeText = "A process is still running."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard let window = view.window else { return }
            let targetPaneId = pane.id
            let targetColId = column.id
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self else { return }
                guard let colIdx = self.columns.firstIndex(where: { $0.id == targetColId }),
                      let col = self.columns[safe: colIdx],
                      let paneIdx = col.panes.firstIndex(where: { $0.id == targetPaneId }) else { return }
                self.removePane(columnIndex: colIdx, paneIndex: paneIdx)
            }
            return
        }
        removePane(columnIndex: focusedColumnIndex, paneIndex: column.focusedPaneIndex)
    }

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
        view.window?.makeFirstResponder(pane.terminalView)
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
                  let surface = pane.terminalView.surface,
                  let scale = pane.terminalView.window?.backingScaleFactor
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
    private func rebuildStackView() {
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
    private func rebuildColumnView(column: ColumnModel) {
        // Clean up old constraints and views
        NSLayoutConstraint.deactivate(column.equalHeightConstraints)
        column.equalHeightConstraints.removeAll()
        for v in column.containerView.arrangedSubviews.reversed() {
            column.containerView.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        var firstTV: NSView?
        for (i, pane) in column.panes.enumerated() {
            if i > 0 {
                let handle = makeVerticalResizeHandle(column: column, topIndex: i - 1, bottomIndex: i)
                column.containerView.addArrangedSubview(handle)
                NSLayoutConstraint.activate(PaneResizeHandle.makeConstraints(for: handle))
            }
            let tv = pane.terminalView
            column.containerView.addArrangedSubview(tv)
            NSLayoutConstraint.activate([
                tv.leadingAnchor.constraint(equalTo: column.containerView.leadingAnchor),
                tv.trailingAnchor.constraint(equalTo: column.containerView.trailingAnchor),
            ])
            // Equal height constraints between all panes (deactivated on drag)
            if let first = firstTV {
                let c = tv.heightAnchor.constraint(equalTo: first.heightAnchor)
                c.isActive = true
                column.equalHeightConstraints.append(c)
            } else {
                firstTV = tv
            }
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
            let newTopHeight = topPane.terminalView.frame.height - deltaY
            let newBottomHeight = bottomPane.terminalView.frame.height + deltaY
            guard newTopHeight >= self.minPaneHeight, newBottomHeight >= self.minPaneHeight else { return }

            // Replace all height constraints with ratio constraints relative to first pane.
            // Ratio constraints fill the container naturally — no absolute heights needed.
            NSLayoutConstraint.deactivate(column.equalHeightConstraints)
            column.equalHeightConstraints.removeAll()

            let firstTV = column.panes[0].terminalView
            // Use current frame heights (with the drag delta applied to the two panes)
            for (i, pane) in column.panes.enumerated() where i > 0 {
                let currentHeight: CGFloat
                if pane.id == topPane.id {
                    currentHeight = newTopHeight
                } else if pane.id == bottomPane.id {
                    currentHeight = newBottomHeight
                } else {
                    currentHeight = pane.terminalView.frame.height
                }
                let firstHeight = (column.panes[0].id == topPane.id) ? newTopHeight :
                                  (column.panes[0].id == bottomPane.id) ? newBottomHeight :
                                  firstTV.frame.height
                guard firstHeight > 0 else { continue }
                let ratio = currentHeight / firstHeight
                let c = pane.terminalView.heightAnchor.constraint(
                    equalTo: firstTV.heightAnchor, multiplier: ratio
                )
                c.isActive = true
                column.equalHeightConstraints.append(c)
            }
        }
        return handle
    }

    /// Update which resize handles are active based on focused column.
    private func updateHandleActiveStates() {
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

    private func applyFocusBorder(_ pane: PaneModel) {
        let tv = pane.terminalView
        tv.wantsLayer = true
        tv.layer?.borderWidth = focusBorderWidth
        tv.layer?.borderColor = focusBorderColor.cgColor
    }

    private func clearFocusBorder(_ pane: PaneModel) {
        let tv = pane.terminalView
        tv.layer?.borderWidth = 0
        tv.layer?.borderColor = nil
    }

    // MARK: - Scrolling

    private func scrollToColumn(at index: Int) {
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
    private func handleFocusChange(from pane: PaneModel) {
        for (colIdx, column) in columns.enumerated() {
            if let paneIdx = column.panes.firstIndex(where: { $0.id == pane.id }) {
                guard colIdx != focusedColumnIndex || paneIdx != column.focusedPaneIndex else { return }
                setFocus(columnIndex: colIdx, paneIndex: paneIdx)
                return
            }
        }
    }

    // MARK: - Header

    private var headerAlwaysVisible = false
    private var titleDebounceTimer: Timer?
    private var lastShownTitle: String = ""
    private static let titleDebounceInterval: TimeInterval = 0.1

    public func toggleHeaderVisibility() {
        headerAlwaysVisible.toggle()
        guard let pane = focusedPane else { return }
        if headerAlwaysVisible {
            pane.headerView.show(title: pane.title, autoHide: false)
        } else {
            pane.headerView.hide()
        }
    }

    private func showHeaderForFocusedPane() {
        guard let pane = focusedPane, !pane.title.isEmpty else { return }
        lastShownTitle = pane.title
        pane.headerView.show(title: pane.title, autoHide: !headerAlwaysVisible)
    }

    private func hideHeaderForPane(_ pane: PaneModel) {
        pane.headerView.hideImmediately()
    }

    /// Update a pane's title and show header if it's the focused pane.
    /// Debounced: header only shows when the title is stable for a short time,
    /// filtering out rapid changes from shell command execution.
    public func handleTitleChange(surface: ghostty_surface_t, title: String) {
        let allPanes = columns.flatMap(\.panes)
        guard let pane = allPanes.first(where: { $0.terminalView.surface == surface }) else { return }

        let titleChanged = pane.title != title
        pane.title = title

        let isFocused = pane.id == focusedPane?.id

        // Window title: immediate (matches ghostty behavior)
        if isFocused {
            view.window?.title = title
        }

        guard titleChanged, isFocused else { return }

        // Header overlay: debounced to filter transient title changes
        titleDebounceTimer?.invalidate()
        titleDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.titleDebounceInterval, repeats: false
        ) { [weak self, weak pane] _ in
            DispatchQueue.main.async {
                guard let self, let pane else { return }
                guard pane.id == self.focusedPane?.id else { return }
                guard pane.title != self.lastShownTitle else { return }
                self.lastShownTitle = pane.title
                pane.headerView.show(title: pane.title, autoHide: !self.headerAlwaysVisible)
            }
        }
    }
}

// MARK: - Safe Array Access

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
