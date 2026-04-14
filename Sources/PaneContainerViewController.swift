import AppKit
import GhosttyTerminal

final class PaneContainerViewController: NSViewController {
    private let controller = TerminalController { builder in
        builder.withFontSize(14)
    }

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()

    private(set) var panes: [PaneModel] = []
    private var focusedIndex: Int = 0

    private let defaultPaneWidth: CGFloat = 640
    private let focusBorderWidth: CGFloat = 2
    private let focusBorderColor: NSColor = .systemBlue

    nonisolated(unsafe) private var scrollEventMonitor: Any?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureScrollView()
        installScrollEventMonitor()
        addPane()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Set overlay style after the window is established.
        // Setting it in viewDidLoad can be overridden by the system
        // during window setup.
        scrollView.scrollerStyle = .overlay
    }

    private var isUpdatingLayout = false

    override func viewDidLayout() {
        super.viewDidLayout()
        // Guard against re-entrant layout: fitToSize() can trigger another layout
        // pass, which would call viewDidLayout again, creating an infinite loop
        // that also keeps the overlay scroller permanently visible.
        guard !isUpdatingLayout else { return }
        isUpdatingLayout = true
        for pane in panes {
            pane.terminalView.fitToSize()
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

    /// Intercept scroll wheel events at the application level.
    /// TerminalView consumes all scrollWheel events for terminal buffer scrolling,
    /// so horizontal scroll events never reach the parent NSScrollView through
    /// the normal responder chain. This monitor captures horizontal-dominant
    /// scroll events before TerminalView can consume them and redirects
    /// them to the scroll view.
    private func installScrollEventMonitor() {
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self] event in
            guard let self else { return event }

            // Only intercept if the event is within our scroll view
            let locationInView = self.scrollView.convert(event.locationInWindow, from: nil)
            guard self.scrollView.bounds.contains(locationInView) else { return event }

            // Horizontal-dominant scroll: redirect to our scroll view
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                self.scrollView.scrollWheel(with: event)
                return nil  // consume the event
            }

            // Vertical scroll: let it pass through to TerminalView
            return event
        }
    }

    // MARK: - Pane Management

    @discardableResult
    func addPane() -> PaneModel {
        let pane = PaneModel(
            controller: controller,
            onTitle: { [weak self] (id: UUID, title: String) in self?.handleTitleChange(title, from: id) },
            onClose: { [weak self] (id: UUID) in self?.handlePaneClose(from: id) }
        )

        let insertIndex = panes.isEmpty ? 0 : focusedIndex + 1
        panes.insert(pane, at: insertIndex)

        let terminalView = pane.terminalView
        terminalView.translatesAutoresizingMaskIntoConstraints = false

        if insertIndex < stackView.arrangedSubviews.count {
            stackView.insertArrangedSubview(terminalView, at: insertIndex)
        } else {
            stackView.addArrangedSubview(terminalView)
        }

        NSLayoutConstraint.activate([
            terminalView.widthAnchor.constraint(equalToConstant: defaultPaneWidth),
        ])

        // Layout before scrolling so frame is computed
        view.layoutSubtreeIfNeeded()
        setFocus(index: insertIndex)
        return pane
    }

    func removePane(at index: Int) {
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

    func removeCurrentPane() {
        removePane(at: focusedIndex)
    }

    // MARK: - Focus

    func setFocus(index: Int) {
        guard panes.indices.contains(index) else { return }

        // Clear previous focus indicator
        if let previous = panes[safe: focusedIndex] {
            clearFocusBorder(previous)
        }

        focusedIndex = index

        let pane = panes[index]
        applyFocusBorder(pane)
        view.window?.makeFirstResponder(pane.terminalView)
        scrollToPane(at: index)
    }

    func focusLeft() {
        guard focusedIndex > 0 else { return }
        setFocus(index: focusedIndex - 1)
    }

    func focusRight() {
        guard focusedIndex < panes.count - 1 else { return }
        setFocus(index: focusedIndex + 1)
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

        // Get pane's frame in the document (stackView) coordinate space
        let paneFrame = targetView.frame
        let visibleWidth = scrollView.contentView.bounds.width
        let contentWidth = stackView.frame.width

        // No scroll needed if everything fits
        if contentWidth <= visibleWidth {
            return
        }

        let targetX: CGFloat
        if paneFrame.width >= visibleWidth {
            // Pane is wider than viewport: align left edge
            targetX = paneFrame.minX
        } else {
            // Pane fits in viewport: center it
            targetX = paneFrame.midX - visibleWidth / 2
        }

        // Clamp to valid scroll range
        let maxScrollX = contentWidth - visibleWidth
        let clampedX = max(0, min(maxScrollX, targetX))

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scrollView.contentView.animator().bounds.origin.x = clampedX
        }
    }

    // MARK: - Terminal Event Handlers

    private func handleTitleChange(_ title: String, from paneID: UUID) {
        guard let focused = panes[safe: focusedIndex], focused.id == paneID else { return }
        view.window?.title = title
    }

    private func handlePaneClose(from paneID: UUID) {
        guard let index = panes.firstIndex(where: { $0.id == paneID }) else { return }
        removePane(at: index)
    }
}

// MARK: - Safe Array Access

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
