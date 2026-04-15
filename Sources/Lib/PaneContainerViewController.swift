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

    public private(set) var panes: [PaneModel] = []
    private var focusedIndex: Int = 0

    private let defaultPaneWidth: CGFloat = 640
    private let minPaneWidth: CGFloat = 100
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
        addPane()
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
        // Recalculate fraction-based presets on window resize
        let visibleWidth = scrollView.contentView.bounds.width
        for pane in panes {
            if case .fraction(let f) = pane.currentPreset, visibleWidth > 0 {
                pane.widthConstraint?.constant = visibleWidth * f
            }
            pane.terminalView.setFrameSize(pane.terminalView.frame.size)
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

    // MARK: - Pane Management

    @discardableResult
    public func addPane() -> PaneModel {
        let pane = PaneModel(ghosttyApp: ghosttyApp)

        pane.terminalView.onFocusChanged = { [weak self, weak pane] focused in
            guard let self, let pane, focused else { return }
            self.handleFocusChange(from: pane)
        }

        pane.terminalView.onClose = { [weak self, weak pane] in
            guard let self, let pane else { return }
            guard let index = self.panes.firstIndex(where: { $0.id == pane.id }) else { return }
            self.removePane(at: index)
        }

        let insertIndex = panes.isEmpty ? 0 : focusedIndex + 1
        panes.insert(pane, at: insertIndex)

        let tv = pane.terminalView
        tv.translatesAutoresizingMaskIntoConstraints = false

        // New panes start at defaultPaneWidth with no preset (currentPreset=nil).
        // User can cycle presets with ⌥⌃+/.
        let wc = tv.widthAnchor.constraint(equalToConstant: defaultPaneWidth)
        wc.isActive = true
        pane.widthConstraint = wc

        rebuildStackView()
        view.layoutSubtreeIfNeeded()
        setFocus(index: insertIndex)
        return pane
    }

    public func removePane(at index: Int) {
        guard panes.indices.contains(index) else { return }

        let pane = panes.remove(at: index)
        clearFocusBorder(pane)
        pane.terminalView.removeFromSuperview()

        if panes.isEmpty {
            for v in stackView.arrangedSubviews { v.removeFromSuperview() }
            view.window?.close()
            return
        }

        rebuildStackView()
        let newIndex = min(index, panes.count - 1)
        setFocus(index: newIndex)
    }

    /// Close the focused pane. Shows a confirmation dialog if a process is running.
    public func removeCurrentPane() {
        guard let pane = panes[safe: focusedIndex] else { return }
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
            let targetId = pane.id
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self else { return }
                if let idx = self.panes.firstIndex(where: { $0.id == targetId }) {
                    self.removePane(at: idx)
                }
            }
            return
        }
        removePane(at: focusedIndex)
    }

    // MARK: - Focus

    public func setFocus(index: Int) {
        guard panes.indices.contains(index) else { return }

        if let previous = panes[safe: focusedIndex] {
            clearFocusBorder(previous)
            hideHeaderForPane(previous)
        }

        focusedIndex = index

        let pane = panes[index]
        applyFocusBorder(pane)
        view.window?.makeFirstResponder(pane.terminalView)
        updateHandleActiveStates()
        showHeaderForFocusedPane()
        scrollToPane(at: index)
    }

    public func focusLeft() {
        guard focusedIndex > 0 else { return }
        setFocus(index: focusedIndex - 1)
    }

    public func focusRight() {
        guard focusedIndex < panes.count - 1 else { return }
        setFocus(index: focusedIndex + 1)
    }

    // MARK: - Width Preset Cycle

    /// Cycle the focused pane's width through the given preset list.
    public func cycleWidthPreset(_ cycle: [PaneWidthPreset]) {
        guard !cycle.isEmpty, let pane = panes[safe: focusedIndex] else { return }

        let nextIndex: Int
        if let current = pane.currentPreset,
           let idx = cycle.firstIndex(of: current)
        {
            nextIndex = (idx + 1) % cycle.count
        } else {
            nextIndex = 0
        }

        let preset = cycle[nextIndex]
        pane.currentPreset = preset
        applyPreset(preset, to: pane)
        view.layoutSubtreeIfNeeded()
        scrollToPane(at: focusedIndex)
    }

    private func applyPreset(_ preset: PaneWidthPreset, to pane: PaneModel) {
        guard let constraint = pane.widthConstraint else { return }
        switch preset {
        case .columns(let n):
            guard let surface = pane.terminalView.surface,
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

    // MARK: - Pane Reorder

    public func movePaneLeft() {
        guard focusedIndex > 0 else { return }
        panes.swapAt(focusedIndex, focusedIndex - 1)
        focusedIndex -= 1
        rebuildStackView()
        view.layoutSubtreeIfNeeded()
        setFocus(index: focusedIndex)
    }

    public func movePaneRight() {
        guard focusedIndex < panes.count - 1 else { return }
        panes.swapAt(focusedIndex, focusedIndex + 1)
        focusedIndex += 1
        rebuildStackView()
        view.layoutSubtreeIfNeeded()
        setFocus(index: focusedIndex)
    }

    // MARK: - Stack View Rebuild

    /// Rebuild arrangedSubviews from panes array, inserting resize handles between panes.
    /// Full rebuild (vs differential update) trades minor layout cost for correctness —
    /// manual arrangedSubview index management was error-prone with handles interleaved.
    private func rebuildStackView() {
        // Remove handles; pane views stay in superview (they have constraints)
        for v in stackView.arrangedSubviews.reversed() {
            stackView.removeArrangedSubview(v)
            if v is PaneResizeHandle { v.removeFromSuperview() }
        }
        for (i, pane) in panes.enumerated() {
            if i > 0 {
                let handle = makeResizeHandle(leftIndex: i - 1, rightIndex: i)
                stackView.addArrangedSubview(handle)
                NSLayoutConstraint.activate(PaneResizeHandle.makeConstraints(for: handle))
            }
            stackView.addArrangedSubview(pane.terminalView)
        }
    }

    private func makeResizeHandle(leftIndex: Int, rightIndex: Int) -> PaneResizeHandle {
        let handle = PaneResizeHandle()
        let leftPane = panes[leftIndex]
        let rightPane = panes[rightIndex]
        handle.onDrag = { [weak self, weak leftPane, weak rightPane] deltaX in
            guard let self, let leftPane, let rightPane else { return }
            // Resize only the focused pane
            let isLeftFocused = leftPane.id == self.panes[safe: self.focusedIndex]?.id
            let isRightFocused = rightPane.id == self.panes[safe: self.focusedIndex]?.id
            guard isLeftFocused || isRightFocused else { return }
            let focusedPane = isLeftFocused ? leftPane : rightPane
            guard let constraint = focusedPane.widthConstraint else { return }
            // Left pane: drag right → wider. Right pane: drag left → wider.
            let sign: CGFloat = isLeftFocused ? 1 : -1
            let newWidth = max(self.minPaneWidth, constraint.constant + deltaX * sign)
            let actualDelta = newWidth - constraint.constant
            constraint.constant = newWidth
            focusedPane.currentPreset = nil
            // When resizing via the LEFT handle, compensate scroll so the
            // right edge appears fixed (stack view anchors from the left).
            if isRightFocused, actualDelta != 0 {
                var origin = self.scrollView.contentView.bounds.origin
                origin.x += actualDelta
                self.scrollView.contentView.setBoundsOrigin(origin)
            }
        }
        return handle
    }

    /// Update which resize handles are active based on focused pane.
    private func updateHandleActiveStates() {
        guard let focusedPane = panes[safe: focusedIndex] else { return }
        for v in stackView.arrangedSubviews {
            guard let handle = v as? PaneResizeHandle else { continue }
            guard let handleIndex = stackView.arrangedSubviews.firstIndex(of: handle) else { continue }
            // Handle at arrangedSubviews index i is between pane at i-1 and i+1.
            // It's active if either adjacent arranged view is the focused pane's terminalView.
            let leftView = stackView.arrangedSubviews[safe: handleIndex - 1]
            let rightView = stackView.arrangedSubviews[safe: handleIndex + 1]
            handle.isActive = leftView === focusedPane.terminalView
                || rightView === focusedPane.terminalView
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

    private func scrollToPane(at index: Int) {
        guard panes.indices.contains(index) else { return }
        let targetView = panes[index].terminalView

        view.layoutSubtreeIfNeeded()

        let paneFrame = targetView.frame
        let visibleWidth = scrollView.contentView.bounds.width
        let contentWidth = stackView.frame.width

        if contentWidth <= visibleWidth { return }

        let targetX: CGFloat
        if paneFrame.width >= visibleWidth {
            targetX = paneFrame.minX
        } else {
            targetX = paneFrame.midX - visibleWidth / 2
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
        guard let index = panes.firstIndex(where: { $0.id == pane.id }) else { return }
        guard index != focusedIndex else { return }
        setFocus(index: index)
    }

    // MARK: - Header

    private var headerAlwaysVisible = false
    private var titleDebounceTimer: Timer?
    private var lastShownTitle: String = ""
    private static let titleDebounceInterval: TimeInterval = 0.1

    public func toggleHeaderVisibility() {
        headerAlwaysVisible.toggle()
        guard let pane = panes[safe: focusedIndex] else { return }
        if headerAlwaysVisible {
            pane.headerView.show(title: pane.title, autoHide: false)
        } else {
            pane.headerView.hide()
        }
    }

    private func showHeaderForFocusedPane() {
        guard let pane = panes[safe: focusedIndex], !pane.title.isEmpty else { return }
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
        guard let pane = panes.first(where: { $0.terminalView.surface == surface }) else { return }

        let titleChanged = pane.title != title
        pane.title = title

        let isFocused = pane.id == panes[safe: focusedIndex]?.id

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
                guard pane.id == self.panes[safe: self.focusedIndex]?.id else { return }
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
