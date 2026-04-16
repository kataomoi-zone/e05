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
    public let browsingHistory = BrowsingHistory()
    public let bookmarks = Bookmarks()

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

    // MARK: - Undo Close

    private static let undoTimeout: TimeInterval = 10

    /// Recently closed pane with enough info to restore it to its original position.
    private struct ClosedPane {
        let pane: PaneModel
        let columnIndex: Int
        let paneIndex: Int
        let columnWidth: CGFloat?
        /// true if this was the only pane in the column (column was also removed)
        let wasOnlyPaneInColumn: Bool
        let timer: Timer
    }

    nonisolated(unsafe) private var recentlyClosed: [ClosedPane] = []

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

        if let session = SessionState.load() {
            restoreSession(session)
        }
        if columns.isEmpty {
            addColumn()
        }
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
            // Folded columns keep their fixed strip width regardless of window size
            // — the saved unfoldedWidth is what the fraction preset will restore to.
            if column.isFolded { continue }
            // Recalculate fraction-based width presets on window resize
            if case .fraction(let f) = column.currentPreset, visibleWidth > 0 {
                column.widthConstraint?.constant = visibleWidth * f
            }
            for pane in column.panes {
                pane.containerView.setFrameSize(pane.containerView.frame.size)
            }
        }
        isUpdatingLayout = false
    }

    deinit {
        if let monitor = scrollEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        for closed in recentlyClosed {
            closed.timer.invalidate()
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
    public func addColumn(address: PaneAddress = .terminal) -> ColumnModel {
        insertColumn(with: PaneModel(address: address, ghosttyApp: ghosttyApp))
    }

    @discardableResult
    private func insertColumn(with pane: PaneModel) -> ColumnModel {
        let column = ColumnModel(pane: pane)

        setupPaneCallbacks(pane: pane, column: column)

        let cv = pane.containerView

        // Add pane's containerView to column's containerView
        column.containerView.addArrangedSubview(cv)
        NSLayoutConstraint.activate([
            cv.leadingAnchor.constraint(equalTo: column.containerView.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: column.containerView.trailingAnchor),
        ])

        // Folded label overlay — shown only when column is folded
        attachFoldedLabel(to: column)

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

    /// Attach the folded label overlay to a column's containerView with full-bounds
    /// constraints and wire up click callbacks. Called on column creation (both via
    /// `insertColumn(with:)` and `undoClosePane` for restored single-pane columns).
    private func attachFoldedLabel(to column: ColumnModel) {
        column.containerView.addSubview(column.foldedLabelView)
        NSLayoutConstraint.activate([
            column.foldedLabelView.topAnchor.constraint(equalTo: column.containerView.topAnchor),
            column.foldedLabelView.leadingAnchor.constraint(equalTo: column.containerView.leadingAnchor),
            column.foldedLabelView.trailingAnchor.constraint(equalTo: column.containerView.trailingAnchor),
            column.foldedLabelView.bottomAnchor.constraint(equalTo: column.containerView.bottomAnchor),
        ])

        // Clicking the folded strip focuses the column; expand button unfolds it.
        column.foldedLabelView.onClicked = { [weak self, weak column] in
            guard let self, let column, let pane = column.focusedPane else { return }
            self.handleFocusChange(from: pane)
        }
        column.foldedLabelView.onExpandClicked = { [weak self, weak column] in
            guard let self, let column else { return }
            // Focus the column first, then toggle fold
            if let pane = column.focusedPane {
                self.handleFocusChange(from: pane)
            }
            self.toggleFold()
        }
    }

    private func setupPaneCallbacks(pane: PaneModel, column: ColumnModel) {
        if let tv = pane.terminalView {
            tv.onFocusChanged = { [weak self, weak pane] focused in
                guard let self, let pane, focused else { return }
                self.handleFocusChange(from: pane)
            }

            tv.onClose = { [weak self, weak pane] in
                guard let self, let pane else { return }
                for (colIdx, col) in self.columns.enumerated() {
                    if let paneIdx = col.panes.firstIndex(where: { $0.id == pane.id }) {
                        self.removePane(columnIndex: colIdx, paneIndex: paneIdx)
                        return
                    }
                }
            }
        }

        if let bv = pane.browserView {
            bv.onTitleChange = { [weak self, weak pane] title in
                pane?.title = title
                // Update history title for the current URL
                if let url = pane?.address.url.absoluteString {
                    self?.browsingHistory.updateTitle(url: url, title: title)
                }
            }
            bv.onURLChange = { [weak self, weak pane] url in
                guard let url else { return }
                let urlString = url.absoluteString
                pane?.address = PaneAddress(url)
                pane?.urlBar.setDisplayURL(urlString)
                // Record visit (skips internal pages and duplicates)
                if url.scheme == "https" || url.scheme == "http" {
                    self?.browsingHistory.recordVisit(url: urlString, title: pane?.title ?? "")
                }
            }
            bv.onFocusChanged = { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.handleFocusChange(from: pane)
            }
            bv.onNavigationStateChange = { [weak pane] canGoBack, canGoForward in
                pane?.urlBar.setNavigationEnabled(back: canGoBack, forward: canGoForward)
            }
        } else {
            // Terminal/other panes: navigation buttons always disabled
            pane.urlBar.setNavigationEnabled(back: false, forward: false)
        }

        // URL bar: navigate callback
        pane.urlBar.onNavigate = { [weak self, weak pane] input in
            guard let self, let pane else { return }
            self.handleURLBarNavigate(pane: pane, input: input)
        }

        // URL bar: ESC returns focus to pane content
        pane.urlBar.onCancel = { [weak pane] in
            guard let pane else { return }
            pane.containerView.window?.makeFirstResponder(pane.preferredFirstResponder)
        }

        // URL bar: back/forward for browser panes
        pane.urlBar.onBack = { [weak pane] in
            pane?.browserView?.webView.goBack()
        }
        pane.urlBar.onForward = { [weak pane] in
            pane?.browserView?.webView.goForward()
        }

        // URL bar: clicking moves focus to this pane
        pane.urlBar.onClicked = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.handleFocusChange(from: pane)
        }

        // URL bar: fold button triggers column fold
        // Focus the pane first so toggleFold always targets the clicked pane's
        // column, independent of urlBar callback ordering with onClicked.
        pane.urlBar.onFold = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.handleFocusChange(from: pane)
            self.toggleFold()
        }

        // URL bar: fuzzy find suggestions from history + bookmarks
        pane.urlBar.onTextChanged = { [weak self] query in
            guard let self, !query.isEmpty else { return [] }
            return self.searchSuggestions(query: query)
        }

        // Sync URL bar visibility with global state
        pane.setURLBarVisible(urlBarVisible)
    }

    /// Search history and bookmarks for URL bar suggestions.
    ///
    /// Collects all bookmarks plus the last 500 history entries, deduplicates
    /// by URL (bookmark wins), and runs the combined pool through
    /// `Suggestion.rank` which uses `FuzzyMatcher` + a bookmark score bonus.
    /// Fuzzy matching replaces the old SQLite `LIKE '%q%'` scan — now
    /// queries like `gite05` can find `github.com/kawarimidoll/e05`.
    ///
    /// Cost: O(B + H × |query| × avg(|url| + |title|)) where B = bookmarks,
    /// H ≤ 500. Runs synchronously on the main thread, acceptable under
    /// `PaneURLBar`'s ~150ms debounce. If the history cap ever grows
    /// meaningfully past 500, hoist this onto a background Task to avoid
    /// main-thread blocking while typing.
    private func searchSuggestions(query: String) -> [Suggestion] {
        let bookmarkEntries = bookmarks.all()
        let historyEntries = browsingHistory.mostRecent(limit: 500)
        let bookmarkURLs = Set(bookmarkEntries.map(\.url))

        var candidates: [Suggestion] = bookmarkEntries.map {
            Suggestion(url: $0.url, title: $0.title, isBookmark: true)
        }
        candidates.append(contentsOf: historyEntries.compactMap { entry in
            bookmarkURLs.contains(entry.url)
                ? nil
                : Suggestion(url: entry.url, title: entry.title, isBookmark: false)
        })

        return Suggestion.rank(query: query, candidates: candidates)
    }

    // MARK: - Vertical Split

    public func splitVertical() {
        guard let column = columns[safe: focusedColumnIndex] else { return }

        let newPane = PaneModel(address: .terminal, ghosttyApp: ghosttyApp)
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

        let wasOnlyPane = column.panes.isEmpty
        let columnWidth = column.widthConstraint?.constant

        // Preserve surface BEFORE removing from view hierarchy
        pane.terminalView?.keepSurfaceAlive = true

        if wasOnlyPane {
            // Remove column
            columns.remove(at: columnIndex)
            column.containerView.removeFromSuperview()

            if columns.isEmpty {
                for v in stackView.arrangedSubviews { v.removeFromSuperview() }
                // Last pane closed — window will close, no undo possible
                pane.terminalView?.keepSurfaceAlive = false
                view.window?.close()
                return
            }

            rebuildStackView()
            let newColIndex = min(columnIndex, columns.count - 1)
            setFocus(columnIndex: newColIndex, paneIndex: 0)
        } else {
            pane.containerView.removeFromSuperview()
            rebuildColumnView(column: column)
            let newPaneIndex = min(paneIndex, column.panes.count - 1)
            setFocus(columnIndex: columnIndex, paneIndex: newPaneIndex)
        }

        stashClosedPane(pane, columnIndex: columnIndex, paneIndex: paneIndex,
                         columnWidth: columnWidth, wasOnlyPaneInColumn: wasOnlyPane)
    }

    private static let maxRecentlyClosed = 10

    private func stashClosedPane(_ pane: PaneModel, columnIndex: Int, paneIndex: Int,
                                  columnWidth: CGFloat?, wasOnlyPaneInColumn: Bool) {
        // Evict oldest if at capacity — must explicitly release detached surfaces
        while recentlyClosed.count >= Self.maxRecentlyClosed {
            let evicted = recentlyClosed.removeFirst()
            evicted.timer.invalidate()
            evicted.pane.terminalView?.releaseDetachedSurface()
        }

        // keepSurfaceAlive is already set by removePane before removeFromSuperview.
        // Browser panes don't need keepSurfaceAlive — WKWebView survives detachment.

        let paneId = pane.id
        let timer = Timer.scheduledTimer(withTimeInterval: Self.undoTimeout, repeats: false) {
            [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let idx = self.recentlyClosed.firstIndex(where: { $0.pane.id == paneId }) {
                    let expired = self.recentlyClosed.remove(at: idx)
                    expired.pane.terminalView?.releaseDetachedSurface()
                }
            }
        }
        let closed = ClosedPane(
            pane: pane, columnIndex: columnIndex, paneIndex: paneIndex,
            columnWidth: columnWidth, wasOnlyPaneInColumn: wasOnlyPaneInColumn, timer: timer
        )
        recentlyClosed.append(closed)
    }

    /// Whether there are recently closed panes available for undo.
    public var canUndoClosePane: Bool { !recentlyClosed.isEmpty }

    /// Restore the most recently closed pane. Surface is still alive — full restore.
    public func undoClosePane() {
        guard let closed = recentlyClosed.popLast() else { return }
        closed.timer.invalidate()

        let pane = closed.pane
        // Re-enable normal surface lifecycle now that the view is re-entering the hierarchy
        pane.terminalView?.keepSurfaceAlive = false

        if closed.wasOnlyPaneInColumn {
            // Re-create a column for this pane
            let column = ColumnModel(pane: pane)
            setupPaneCallbacks(pane: pane, column: column)

            let cv = pane.containerView
            column.containerView.addArrangedSubview(cv)
            NSLayoutConstraint.activate([
                cv.leadingAnchor.constraint(equalTo: column.containerView.leadingAnchor),
                cv.trailingAnchor.constraint(equalTo: column.containerView.trailingAnchor),
            ])

            // Folded label overlay — same setup as insertColumn(with:)
            attachFoldedLabel(to: column)

            let wc = column.containerView.widthAnchor.constraint(
                equalToConstant: closed.columnWidth ?? defaultPaneWidth
            )
            wc.isActive = true
            column.widthConstraint = wc

            let insertIndex = min(closed.columnIndex, columns.count)
            columns.insert(column, at: insertIndex)
            rebuildStackView()
            view.layoutSubtreeIfNeeded()
            setFocus(columnIndex: insertIndex, paneIndex: 0)
        } else {
            // Insert back into existing column
            guard !columns.isEmpty else { return }
            let colIndex = min(closed.columnIndex, columns.count - 1)
            guard let column = columns[safe: colIndex] else { return }

            let paneIndex = min(closed.paneIndex, column.panes.count)
            setupPaneCallbacks(pane: pane, column: column)
            column.panes.insert(pane, at: paneIndex)
            rebuildColumnView(column: column)
            view.layoutSubtreeIfNeeded()
            setFocus(columnIndex: colIndex, paneIndex: paneIndex)
        }
    }

    /// Close the focused pane. Shows a confirmation dialog if a process is running.
    public func removeCurrentPane() {
        guard let column = columns[safe: focusedColumnIndex],
              let pane = column.focusedPane else { return }
        if let surface = pane.terminalView?.surface,
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
        view.window?.makeFirstResponder(pane.preferredFirstResponder)
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
    private func rebuildColumnView(column: ColumnModel) {
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

    private func clearFocusBorder(_ pane: PaneModel) {
        let cv = pane.containerView
        cv.layer?.borderWidth = 0
        cv.layer?.borderColor = nil

        if let column = columns.first(where: { $0.panes.contains(where: { $0.id == pane.id }) }) {
            column.foldedLabelView.layer?.borderWidth = 0
            column.foldedLabelView.layer?.borderColor = nil
        }
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

    // MARK: - URL Bar

    /// Whether URL bars are visible across all panes.
    private var urlBarVisible = false

    /// Toggle URL bar visibility for all panes. When URL bar is shown, header overlay is suppressed.
    public func toggleURLBarVisibility() {
        urlBarVisible.toggle()
        for pane in columns.flatMap(\.panes) {
            pane.setURLBarVisible(urlBarVisible)
        }
        // When hiding URL bar, show header overlay for focused pane as fallback
        if !urlBarVisible {
            showHeaderForFocusedPane()
        } else if let pane = focusedPane {
            pane.headerView.hideImmediately()
        }
    }

    /// Focus the URL bar of the focused pane (⌘+L).
    public func focusURLBar(prefill: String? = nil) {
        guard let pane = focusedPane else { return }
        if !urlBarVisible {
            toggleURLBarVisibility()
        }
        if let prefill {
            pane.urlBar.setDisplayURL(prefill)
        }
        pane.urlBar.focusURLField()
    }

    // MARK: - Fold

    private static let foldedColumnWidth: CGFloat = 30

    /// Toggle fold state of the focused column. Folded columns collapse to a narrow strip
    /// with vertical title text (Watchtower-style).
    public func toggleFold() {
        guard let column = columns[safe: focusedColumnIndex],
              let constraint = column.widthConstraint else { return }

        if column.isFolded {
            // Unfold: restore previous width and show panes + handles
            constraint.constant = column.unfoldedWidth
            column.isFolded = false
            column.foldedLabelView.isHidden = true
            for sub in column.containerView.arrangedSubviews {
                sub.isHidden = false
            }
        } else {
            // Fold: save current width, shrink column, hide panes + vertical handles
            column.unfoldedWidth = constraint.constant
            constraint.constant = Self.foldedColumnWidth
            column.isFolded = true
            // Prefer the focused pane's title; fall back to its address when
            // the page hasn't reported a title yet (e.g. blank browser pane).
            let base: String
            if let pane = column.focusedPane {
                base = pane.title.isEmpty ? pane.address.description : pane.title
            } else {
                base = ""
            }
            // Append pane count if the column has multiple panes
            column.foldedLabelView.text = column.panes.count > 1
                ? "\(base) (\(column.panes.count))"
                : base
            column.foldedLabelView.isHidden = false
            // Hide all arranged subviews (pane containers + vertical resize handles)
            for sub in column.containerView.arrangedSubviews {
                sub.isHidden = true
            }
        }
        view.layoutSubtreeIfNeeded()
        // Re-apply focus indicators so folded label gets the border (or removes it)
        if let pane = column.focusedPane {
            applyFocusBorder(pane)
        }
    }

    // MARK: - Web Inspector

    /// Toggle Web Inspector inline in the focused browser pane.
    public func toggleInspector() {
        focusedPane?.browserView?.toggleInspector()
    }

    /// Whether the focused browser pane's Web Inspector is currently open.
    public var isFocusedInspectorOpen: Bool {
        focusedPane?.browserView?.isInspectorOpen ?? false
    }

    // MARK: - Bookmarks

    /// Toggle bookmark for the focused browser pane's current URL.
    /// Returns true if bookmarked, false if removed, nil if not a browser pane.
    @discardableResult
    public func toggleBookmark() -> Bool? {
        guard isFocusedPaneBrowser, let pane = focusedPane else { return nil }
        let url = pane.address.url.absoluteString
        if bookmarks.isBookmarked(url: url) {
            bookmarks.remove(url: url)
            return false
        } else {
            bookmarks.add(url: url, title: pane.title)
            return true
        }
    }

    /// Whether the focused pane is a browser pane with http/https.
    public var isFocusedPaneBrowser: Bool {
        guard let pane = focusedPane else { return false }
        return pane.browserView != nil && pane.address.kind == .browser
    }

    /// Whether the focused pane's URL is bookmarked.
    public var isFocusedPaneBookmarked: Bool {
        guard let pane = focusedPane,
              pane.address.kind == .browser else { return false }
        return bookmarks.isBookmarked(url: pane.address.url.absoluteString)
    }

    /// Handle URL bar navigation: same-type navigates in place, cross-type switches content.
    private func handleURLBarNavigate(pane: PaneModel, input: String) {
        guard let newAddress = PaneAddress.fromUserInput(input),
              newAddress.kind != .unknown else { return }

        if pane.address.requiresContentSwitch(to: newAddress) {
            // Cross-type: replace pane content (Step 4-3)
            // For now, create a new column and remove the old pane
            // TODO: in-place content replacement in Step 4-3
            guard let colIdx = columns.firstIndex(where: { $0.panes.contains(where: { $0.id == pane.id }) }) else { return }
            let column = columns[colIdx]
            guard let paneIdx = column.panes.firstIndex(where: { $0.id == pane.id }) else { return }

            let newPane = PaneModel(address: newAddress, ghosttyApp: ghosttyApp)
            newPane.setURLBarVisible(urlBarVisible)
            setupPaneCallbacks(pane: newPane, column: column)

            // Replace in column
            column.panes[paneIdx] = newPane
            rebuildColumnView(column: column)
            view.layoutSubtreeIfNeeded()
            setFocus(columnIndex: colIdx, paneIndex: paneIdx)
        } else {
            // Same type: navigate in place
            // Browser → browser: load new URL. Terminal → terminal: no-op (address update only).
            pane.address = newAddress
            if let bv = pane.browserView {
                bv.navigate(to: newAddress.url.absoluteString)
            }
            view.window?.makeFirstResponder(pane.preferredFirstResponder)
        }
    }

    // MARK: - Header

    private var titleDebounceTimer: Timer?
    private var lastShownTitle: String = ""
    private static let titleDebounceInterval: TimeInterval = 0.1

    private func showHeaderForFocusedPane() {
        guard !urlBarVisible else { return }
        guard let pane = focusedPane, !pane.title.isEmpty else { return }
        lastShownTitle = pane.title
        pane.headerView.show(title: pane.title, autoHide: true)
    }

    private func hideHeaderForPane(_ pane: PaneModel) {
        pane.headerView.hideImmediately()
    }

    /// Update a pane's title and show header if it's the focused pane.
    /// Debounced: header only shows when the title is stable for a short time,
    /// filtering out rapid changes from shell command execution.
    public func handleTitleChange(surface: ghostty_surface_t, title: String) {
        let allPanes = columns.flatMap(\.panes)
        guard let pane = allPanes.first(where: { $0.terminalView?.surface == surface }) else { return }

        let titleChanged = pane.title != title
        pane.title = title

        let isFocused = pane.id == focusedPane?.id

        // Window title: immediate (matches ghostty behavior)
        if isFocused {
            view.window?.title = title
        }

        guard titleChanged, isFocused else { return }

        // Header overlay: debounced, only when URL bar is hidden
        guard !urlBarVisible else { return }
        titleDebounceTimer?.invalidate()
        titleDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.titleDebounceInterval, repeats: false
        ) { [weak self, weak pane] _ in
            DispatchQueue.main.async {
                guard let self, let pane else { return }
                guard pane.id == self.focusedPane?.id else { return }
                guard pane.title != self.lastShownTitle else { return }
                self.lastShownTitle = pane.title
                pane.headerView.show(title: pane.title, autoHide: true)
            }
        }
    }

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
    private func restoreSession(_ session: SessionState) {
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
                let pane = PaneModel(address: address, ghosttyApp: ghosttyApp)
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

// MARK: - Safe Array Access

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
