import AppKit
import GhosttyKit

public final class PaneContainerViewController: NSViewController {
    let ghosttyApp: GhosttyApp
    public let browsingHistory = BrowsingHistory()
    public let bookmarks = Bookmarks()

    let scrollView = OverlayScrollView()
    let stackView = NSStackView()

    public internal(set) var columns: [ColumnModel] = []
    var focusedColumnIndex: Int = 0

    var focusedPane: PaneModel? {
        columns[safe: focusedColumnIndex]?.focusedPane
    }

    let defaultPaneWidth: CGFloat = 640
    let minPaneWidth: CGFloat = 100
    let minPaneHeight: CGFloat = 50
    let focusBorderWidth: CGFloat = 2
    let focusBorderColor: NSColor = .systemBlue

    nonisolated(unsafe) var scrollEventMonitor: Any?

    // MARK: - Undo Close

    static let undoTimeout: TimeInterval = 10

    /// Recently closed pane with enough info to restore it to its original position.
    struct ClosedPane {
        let pane: PaneModel
        let columnIndex: Int
        let paneIndex: Int
        let columnWidth: CGFloat?
        /// true if this was the only pane in the column (column was also removed)
        let wasOnlyPaneInColumn: Bool
        let timer: Timer
    }

    nonisolated(unsafe) var recentlyClosed: [ClosedPane] = []

    var urlBarVisible = false

    var titleDebounceTimer: Timer?
    var lastShownTitle: String = ""
    static let titleDebounceInterval: TimeInterval = 0.1

    let commandPalette = CommandPaletteView()
    /// Actions from the most recent `searchActions` call, retained so that
    /// the command palette can look up the handler by index on Execute.
    var cachedActionResults: [Action] = []
    /// Snapshot of `actions()` taken when the palette opens. The action
    /// list doesn't change while the palette is visible, so caching at
    /// `show` time avoids re-building the full array (with all its
    /// closure captures) on every keystroke.
    var cachedAllActions: [Action] = []

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
        setupCommandPalette()

        if let session = SessionState.load() {
            restoreSession(session)
        }
        if columns.isEmpty {
            addColumn()
        }
    }

    /// Factory: construct a `PaneModel` with all dependencies the container
    /// owns. Using this instead of `PaneModel.init` directly keeps call
    /// sites agnostic of the full dependency list — adding a new
    /// dependency (e.g. for `e05://downloads`) touches only this method.
    func makePane(address: PaneAddress) -> PaneModel {
        PaneModel(
            address: address,
            ghosttyApp: ghosttyApp,
            browsingHistory: browsingHistory,
            bookmarks: bookmarks
        )
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
}
