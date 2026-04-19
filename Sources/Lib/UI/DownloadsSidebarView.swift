import AppKit

/// Downloads list rendered inside the sidebar's `downloads` mode.
/// Subscribes to the shared `DownloadsManager` so mutations (new
/// transfers, pause / resume / cancel, the legacy pane's delete button,
/// etc.) reflect live without a manual reload.
///
/// Mirrors `HistorySidebarView`'s compact 260pt-friendly layout with
/// downloads-specific extensions:
/// - the status line carries percent + byte counts for in-flight rows
/// - a 2pt accent-coloured overlay hugs the cell's bottom edge for
///   `.downloading` / `.paused` rows with known total bytes, giving a
///   low-noise progress indicator that doesn't push row height up
/// - the trailing slot surfaces state-dependent actions (pause+cancel,
///   resume+remove, reveal+remove, remove) in the hover-revealed button
///   stack; longer tails (copy URL, open file, editing) are deferred
///   to the stage 5 ellipsis menu pass shared with history/bookmarks
///
/// Layout stability for hover-reveal: the trailing stack uses
/// `detachesHiddenViews = false`, so toggling individual button
/// `isHidden` on hover doesn't reflow the title label. Without that
/// flag, the stack's reflow momentarily moves the button out from
/// under the cursor, causing its `mouseExited` to fire and hide the
/// button immediately after it appeared — a flicker that's especially
/// noticeable when aiming at the tiny 18×18 hit zone.
@MainActor
final class DownloadsSidebarView: NSView {
    /// Fired when cancel is requested on an in-flight download.
    var onCancel: ((Int64) -> Void)?
    /// Fired when pause is requested on an in-flight download.
    var onPause: ((Int64) -> Void)?
    /// Fired when resume is requested on a paused download.
    var onResume: ((Int64) -> Void)?
    /// Fired when a row is removed from the list (non-active states,
    /// or the user explicitly abandoning an in-flight transfer).
    var onRemove: ((Int64) -> Void)?
    /// Fired when reveal-in-Finder is requested on a completed row.
    /// The payload is the destination file path; empty paths are
    /// filtered by the sidebar controller before reaching Finder.
    var onShowInFinder: ((String) -> Void)?

    private let manager: DownloadsManager
    private var listenerToken: DownloadsListenerToken?
    private let scrollView = NSScrollView()
    private let tableView = DownloadsTableView()
    private let emptyLabel = NSTextField(labelWithString: "No downloads")
    private var rows: [Download] = []
    private var scrollObserver: NSObjectProtocol?

    init(manager: DownloadsManager) {
        self.manager = manager
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setupLayout()
        reload()
        listenerToken = manager.addListener { [weak self] in self?.reload() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    // NOTE: No deinit cleanup for the listener or scroll observer. The
    // closures capture `[weak self]`, so post-dealloc invocations are
    // no-ops. `DownloadsManager` is a process-lifetime singleton held
    // by the container and the sidebar view is recreated at most per
    // container, so the listener list never grows beyond a handful of
    // entries.

    private func setupLayout() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("downloads"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = DownloadsSidebarCellView.height
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.style = .plain
        tableView.target = self
        tableView.action = #selector(handleClick)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onDeleteKey = { [weak self] in
            guard let self else { return }
            self.removeRow(at: self.tableView.selectedRow)
        }
        tableView.onActivateRow = { [weak self] in
            guard let self else { return }
            self.activateRow(at: self.tableView.selectedRow)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Mirrors the history / bookmarks sidebar lists: `.inVisibleRect`
        // tracking doesn't deliver `mouseExited` under a stationary
        // cursor when a hovered row slides out from under it. Force-hide
        // every cell's trailing buttons whenever the clip view's bounds
        // shift (trackpad inertia and wheel scroll both fire this).
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideAllActionButtons() }
        }

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.drawsBackground = false
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func reload() {
        rows = manager.all()
        tableView.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
    }

    private func hideAllActionButtons() {
        tableView.enumerateAvailableRowViews { _, row in
            (self.tableView.view(
                atColumn: 0, row: row, makeIfNecessary: false
            ) as? DownloadsSidebarCellView)?.forceHideActionButtons()
        }
    }

    @objc private func handleClick() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        activateRow(at: row)
    }

    private func activateRow(at row: Int) {
        guard rows.indices.contains(row) else { return }
        let entry = rows[row]
        // UX policy: only completed rows have a row-click action
        // (reveal in Finder). Downloading / paused / failed / cancelled
        // rows are inert — their state-dependent actions live in the
        // hover-revealed trailing buttons so the click target isn't
        // ambiguous with the per-state action set.
        guard entry.state == .completed else { return }
        onShowInFinder?(entry.destination)
    }

    private func removeRow(at index: Int) {
        guard rows.indices.contains(index) else { return }
        let entry = rows[index]
        // Removal goes through the manager; its listener-driven reload
        // keeps the UI and data source in sync regardless of which
        // entry point triggered it (this list's × button, Delete key,
        // the legacy pane, etc.).
        onRemove?(entry.id)
    }
}

// MARK: - NSTableViewDataSource

extension DownloadsSidebarView: NSTableViewDataSource {
    func numberOfRows(in _: NSTableView) -> Int { rows.count }
}

// MARK: - NSTableViewDelegate

extension DownloadsSidebarView: NSTableViewDelegate {
    func tableView(
        _ tv: NSTableView, viewFor _: NSTableColumn?, row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("DownloadsSidebarCell")
        let cell = tv.makeView(withIdentifier: identifier, owner: self)
            as? DownloadsSidebarCellView
            ?? DownloadsSidebarCellView(identifier: identifier)
        cell.onCancel = { [weak self] id in self?.onCancel?(id) }
        cell.onPause = { [weak self] id in self?.onPause?(id) }
        cell.onResume = { [weak self] id in self?.onResume?(id) }
        cell.onRemove = { [weak self] id in self?.onRemove?(id) }
        cell.onShowInFinder = { [weak self] path in self?.onShowInFinder?(path) }
        cell.configure(with: rows[row])
        return cell
    }

    func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        DownloadsSidebarRowView()
    }
}

// MARK: - Row view

private final class DownloadsSidebarRowView: NSTableRowView {
    private var trackingArea: NSTrackingArea?

    override var isEmphasized: Bool { get { false } set {} }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        guard let tv = superview as? NSTableView else { return }
        let row = tv.row(for: self)
        guard row >= 0, tv.selectedRow != row else { return }
        tv.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
}

// MARK: - Cell view

private final class DownloadsSidebarCellView: NSView {
    static let height: CGFloat = 40

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var onCancel: ((Int64) -> Void)?
    var onPause: ((Int64) -> Void)?
    var onResume: ((Int64) -> Void)?
    var onRemove: ((Int64) -> Void)?
    var onShowInFinder: ((String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let actionsStack = NSStackView()
    private let progressOverlay = NSView()
    private var progressOverlayWidth: NSLayoutConstraint?

    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false
    private var lastFraction: Double = 0
    private var progressIsVisible: Bool = false
    private var currentID: Int64 = 0
    private var currentDestination: String = ""

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func setup() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.drawsBackground = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.drawsBackground = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        actionsStack.orientation = .horizontal
        actionsStack.spacing = 2
        // Keep hidden arranged subviews in layout so toggling
        // individual button visibility on hover doesn't reflow the
        // title. Reflow would move the button out from under the
        // cursor and its mouseExited would fire the moment it
        // appeared — hover-reveal becomes un-clickable without this.
        actionsStack.detachesHiddenViews = false
        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionsStack)

        progressOverlay.wantsLayer = true
        progressOverlay.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.7).cgColor
        progressOverlay.layer?.cornerRadius = 1
        progressOverlay.translatesAutoresizingMaskIntoConstraints = false
        progressOverlay.isHidden = true
        addSubview(progressOverlay)

        let overlayWidth = progressOverlay.widthAnchor.constraint(equalToConstant: 0)
        progressOverlayWidth = overlayWidth

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: actionsStack.leadingAnchor, constant: -6),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            actionsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            progressOverlay.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressOverlay.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            progressOverlay.heightAnchor.constraint(equalToConstant: 2),
            overlayWidth,
        ])
    }

    override func layout() {
        super.layout()
        refreshProgressWidth()
    }

    private func refreshProgressWidth() {
        guard progressIsVisible else { return }
        let available = titleLabel.frame.width
        let target = max(0, available * CGFloat(lastFraction))
        if let constraint = progressOverlayWidth,
           abs(constraint.constant - target) > 0.5 {
            constraint.constant = target
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            // `.cursorUpdate` lets AppKit call `cursorUpdate(with:)`
            // while the pointer is inside the cell so rows advertise
            // their clickability (hover highlight alone looks passive).
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
        showActionButtons()
    }

    override func mouseExited(with _: NSEvent) {
        // AppKit can deliver a spurious mouseExited when the cursor
        // moves from this cell's tracking area into a subview's own
        // tracking area (a HoverIconButton in our trailing slot) and
        // back, even though the cursor never actually left our bounds.
        // Re-check against the live cursor position; if we're still
        // inside, ignore the event so the hover-revealed button
        // doesn't flicker off mid-aim.
        if cursorIsStillInside() { return }
        isHovered = false
        hideActionButtons()
    }

    /// Re-validate that the cursor is truly outside the cell before
    /// responding to a mouseExited. The same helper is duplicated
    /// verbatim in the bookmarks and history sidebar cells by the
    /// legacy-separation rule — keep the three copies in sync until
    /// they can be folded into a shared helper.
    private func cursorIsStillInside() -> Bool {
        // When the window has gone (mode swap, table reload tearing
        // this cell out of the hierarchy) there's no meaningful
        // cursor-position check we can perform. Return `true` so a
        // stray mouseExited during teardown is ignored: the function
        // name reads as "still inside" and a cell not attached to a
        // window isn't presenting its reveal anyway.
        guard let window else { return true }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = convert(windowPoint, from: nil)
        // Prefer `NSMouseInRect` over `bounds.contains` so flipped /
        // non-flipped coordinate changes can't silently invert the
        // check when the cell view's `isFlipped` is overridden later.
        return NSMouseInRect(localPoint, bounds, isFlipped)
    }

    override func cursorUpdate(with _: NSEvent) {
        NSCursor.pointingHand.set()
    }

    private func showActionButtons() {
        actionsStack.arrangedSubviews.forEach { $0.isHidden = false }
    }

    private func hideActionButtons() {
        actionsStack.arrangedSubviews.forEach { $0.isHidden = true }
    }

    /// Force-hide the trailing buttons regardless of tracking state.
    /// Used by the parent list when the clip view scrolls, because
    /// `.inVisibleRect` doesn't reliably fire `mouseExited` for cells
    /// that scroll out from under a stationary cursor.
    func forceHideActionButtons() {
        isHovered = false
        hideActionButtons()
    }

    func configure(with entry: Download) {
        currentID = entry.id
        currentDestination = entry.destination
        titleLabel.stringValue = entry.filename.isEmpty ? entry.url : entry.filename
        subtitleLabel.stringValue = Self.statusLine(for: entry)

        let fraction: Double
        if entry.totalBytes > 0 {
            fraction = min(max(Double(entry.bytesWritten) / Double(entry.totalBytes), 0), 1)
        } else {
            fraction = 0
        }
        lastFraction = fraction

        // Progress is only meaningful when we know the total. A
        // `.downloading` row with `totalBytes == 0` reads as a
        // chunked / streaming transfer — the subtitle carries the
        // running byte count; the overlay stays hidden.
        let showProgress = (entry.state == .downloading || entry.state == .paused)
            && entry.totalBytes > 0
        progressIsVisible = showProgress
        progressOverlay.isHidden = !showProgress

        rebuildActionButtons(for: entry.state)
        needsLayout = true
    }

    private func rebuildActionButtons(for state: DownloadState) {
        actionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        switch state {
        case .downloading:
            actionsStack.addArrangedSubview(makeButton(
                symbol: "pause.circle", tooltip: "Pause",
                action: #selector(handlePauseTapped)
            ))
            actionsStack.addArrangedSubview(makeButton(
                symbol: "xmark", tooltip: "Cancel",
                action: #selector(handleCancelTapped)
            ))
        case .paused:
            actionsStack.addArrangedSubview(makeButton(
                symbol: "play.circle", tooltip: "Resume",
                action: #selector(handleResumeTapped)
            ))
            actionsStack.addArrangedSubview(makeButton(
                symbol: "xmark", tooltip: "Remove",
                action: #selector(handleRemoveTapped)
            ))
        case .completed:
            actionsStack.addArrangedSubview(makeButton(
                symbol: "folder", tooltip: "Show in Finder",
                action: #selector(handleShowInFinderTapped)
            ))
            actionsStack.addArrangedSubview(makeButton(
                symbol: "xmark", tooltip: "Remove",
                action: #selector(handleRemoveTapped)
            ))
        case .failed, .cancelled:
            actionsStack.addArrangedSubview(makeButton(
                symbol: "xmark", tooltip: "Remove",
                action: #selector(handleRemoveTapped)
            ))
        }

        // Sync visibility to current hover state so cells rebuilt
        // under the cursor (e.g. a state transition reload triggered
        // from a WebKit progress tick) don't flicker the buttons off
        // until the next mouse move.
        actionsStack.arrangedSubviews.forEach { $0.isHidden = !isHovered }
    }

    private func makeButton(symbol: String, tooltip: String, action: Selector) -> HoverIconButton {
        let button = HoverIconButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.toolTip = tooltip
        button.target = self
        button.action = action
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 18),
            button.heightAnchor.constraint(equalToConstant: 18),
        ])
        return button
    }

    @objc private func handlePauseTapped() { onPause?(currentID) }
    @objc private func handleResumeTapped() { onResume?(currentID) }
    @objc private func handleCancelTapped() { onCancel?(currentID) }
    @objc private func handleRemoveTapped() { onRemove?(currentID) }
    @objc private func handleShowInFinderTapped() { onShowInFinder?(currentDestination) }

    // MARK: - Status line formatting

    private static func statusLine(for entry: Download) -> String {
        switch entry.state {
        case .downloading:
            if entry.totalBytes > 0 {
                let percent = Int((Double(entry.bytesWritten) / Double(entry.totalBytes)) * 100)
                return "\(percent)% · \(formatBytes(entry.bytesWritten)) / \(formatBytes(entry.totalBytes))"
            }
            let size = formatBytes(entry.bytesWritten)
            return size.isEmpty ? "Downloading…" : "Downloading… · \(size)"
        case .paused:
            if entry.totalBytes > 0 {
                let percent = Int((Double(entry.bytesWritten) / Double(entry.totalBytes)) * 100)
                return "Paused · \(percent)% · \(formatBytes(entry.bytesWritten)) / \(formatBytes(entry.totalBytes))"
            }
            return "Paused"
        case .completed:
            let host = URL(string: entry.url)?.host() ?? entry.url
            let size = formatBytes(entry.bytesWritten)
            let when = relative(entry.completedAt ?? entry.startedAt)
            // Size and time first, host last: long hosts (e.g. CDN
            // redirect URLs or deep GitHub artefact paths) would
            // otherwise consume the line and push the "how big / when"
            // signal past the truncation boundary. Host is secondary
            // context here and survives partial truncation just fine.
            return size.isEmpty ? "\(when) · \(host)" : "\(size) · \(when) · \(host)"
        case .failed:
            return "Failed · \(entry.errorMessage ?? "Unknown error")"
        case .cancelled:
            return "Cancelled · \(relative(entry.completedAt ?? entry.startedAt))"
        }
    }

    private static func formatBytes(_ value: Int64) -> String {
        value > 0 ? byteFormatter.string(fromByteCount: value) : ""
    }

    private static func relative(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 5 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Table view

/// `NSTableView` subclass that intercepts Delete and Return keys for
/// the sidebar downloads list, and adds emacs-style Ctrl+N / Ctrl+P
/// navigation alongside the default arrow keys.
private final class DownloadsTableView: NSTableView {
    var onDeleteKey: (() -> Void)?
    var onActivateRow: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            onDeleteKey?()
            return
        case 36, 76:
            onActivateRow?()
            return
        default:
            break
        }

        if event.modifierFlags.contains(.control) {
            switch event.charactersIgnoringModifiers {
            case "n":
                moveSelection(by: 1)
                return
            case "p":
                moveSelection(by: -1)
                return
            default:
                break
            }
        }

        super.keyDown(with: event)
    }

    private func moveSelection(by delta: Int) {
        let count = numberOfRows
        guard count > 0 else { return }
        let base = selectedRow >= 0 ? selectedRow : (delta > 0 ? -1 : count)
        let target = max(0, min(count - 1, base + delta))
        selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        scrollRowToVisible(target)
    }
}
