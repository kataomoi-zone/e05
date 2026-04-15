import AppKit
import GhosttyKit

public final class PaneContainerViewController: NSViewController {
    private let ghosttyApp: GhosttyApp

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()

    public private(set) var panes: [PaneModel] = []
    private var focusedIndex: Int = 0

    private let defaultPaneWidth: CGFloat = 640
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
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .allowed

        stackView.orientation = .horizontal
        stackView.spacing = 1
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

        if insertIndex < stackView.arrangedSubviews.count {
            stackView.insertArrangedSubview(tv, at: insertIndex)
        } else {
            stackView.addArrangedSubview(tv)
        }

        // New panes start at defaultPaneWidth with no preset (currentPreset=nil).
        // User can cycle presets with ⌥⌃+/.
        let wc = tv.widthAnchor.constraint(equalToConstant: defaultPaneWidth)
        wc.isActive = true
        pane.widthConstraint = wc

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
            view.window?.close()
            return
        }

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
        }

        focusedIndex = index

        let pane = panes[index]
        applyFocusBorder(pane)
        view.window?.makeFirstResponder(pane.terminalView)
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
        let from = focusedIndex
        let to = focusedIndex - 1
        panes.swapAt(from, to)
        // Move only the target view to its new position
        let tv = panes[to].terminalView
        stackView.removeArrangedSubview(tv)
        stackView.insertArrangedSubview(tv, at: to)
        view.layoutSubtreeIfNeeded()
        setFocus(index: to)
    }

    public func movePaneRight() {
        guard focusedIndex < panes.count - 1 else { return }
        let from = focusedIndex
        let to = focusedIndex + 1
        panes.swapAt(from, to)
        let tv = panes[to].terminalView
        stackView.removeArrangedSubview(tv)
        stackView.insertArrangedSubview(tv, at: to)
        view.layoutSubtreeIfNeeded()
        setFocus(index: to)
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

        if let previous = panes[safe: focusedIndex] {
            clearFocusBorder(previous)
        }
        focusedIndex = index
        applyFocusBorder(panes[index])
        scrollToPane(at: index)
    }

    /// Update the window title when the focused pane's title changes.
    public func handleTitleChange(surface: ghostty_surface_t, title: String) {
        guard let focused = panes[safe: focusedIndex],
              focused.terminalView.surface == surface
        else { return }
        view.window?.title = title
    }
}

// MARK: - Safe Array Access

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
