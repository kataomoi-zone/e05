import AppKit

/// Download manager pane (`e05://downloads`).
///
/// Intentionally not built on `ListPaneView` — downloads have live
/// progress, multi-state lifecycle, and per-state action buttons that
/// would pollute the simpler list abstraction. Shared primitives
/// (gray-selection `HoverableRowView`, header label) can be hoisted
/// into a common base once a third list-style pane lands.
@MainActor
public final class DownloadsPaneView: NSView {
    private let manager: DownloadsManager
    private var listenerToken: DownloadsListenerToken?
    private let scrollView = NSScrollView()
    private let tableView = FocusReportingTableView()
    private let headerLabel = NSTextField(labelWithString: "Downloads")
    private let clearButton = NSButton(title: "Clear Completed", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "No downloads yet.")
    private var rows: [Download] = []

    /// View that receives keyboard focus when the pane is focused.
    public var focusTarget: NSView { tableView }

    /// Invoked when the table becomes first responder.
    public var onFocusChanged: (() -> Void)?

    public init(manager: DownloadsManager) {
        self.manager = manager
        super.init(frame: .zero)
        setup()
        refresh()
        listenerToken = manager.addListener { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    // NOTE: No deinit cleanup for the listener registration. The closure
    // captures `[weak self]`, so post-dealloc invocations are no-ops.
    // Removing the registration from a nonisolated deinit would require
    // hopping to the MainActor, and this view is scheduled for removal
    // in Phase 8-2 stage 3-D anyway (functionality moves into the
    // sidebar).

    // MARK: - Setup

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor
        appearance = NSAppearance(named: .darkAqua)

        headerLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        headerLabel.textColor = .labelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)

        clearButton.bezelStyle = .texturedRounded
        clearButton.controlSize = .small
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.target = self
        clearButton.action = #selector(handleClearCompleted)
        addSubview(clearButton)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("download"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 92  // fits title + url + status + progress
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onBecameFirstResponder = { [weak self] in
            self?.onFocusChanged?()
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            clearButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Refresh

    private func refresh() {
        let newRows = manager.all()
        let structuralChange = newRows.count != rows.count
            || zip(newRows, rows).contains(where: { $0.id != $1.id })
        rows = newRows

        if structuralChange {
            tableView.reloadData()
        } else {
            // Same rows in same order — reuse cells, just re-configure
            // so live NSProgressIndicator keeps animating smoothly.
            let indexes = IndexSet(integersIn: 0..<rows.count)
            tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
        }
        emptyLabel.isHidden = !rows.isEmpty
        // Enable "Clear Completed" only when at least one row is in a
        // terminal state. Downloading and paused rows must stay —
        // pausing a download and then accidentally wiping it out
        // would be a nasty footgun.
        clearButton.isEnabled = rows.contains {
            $0.state != .downloading && $0.state != .paused
        }
    }

    // MARK: - Actions

    @objc private func handleClearCompleted() {
        manager.clearCompleted()
    }

    // MARK: - Focus

    /// Clicks on the pane background (outside the table) still move
    /// focus to the pane so the parent controller scrolls the column
    /// into view. Click inside the table is handled by the table's
    /// own `becomeFirstResponder`.
    public override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onFocusChanged?()
    }
}

// MARK: - NSTableViewDataSource

extension DownloadsPaneView: NSTableViewDataSource {
    public func numberOfRows(in _: NSTableView) -> Int { rows.count }
}

// MARK: - NSTableViewDelegate

extension DownloadsPaneView: NSTableViewDelegate {
    public func tableView(
        _ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("DownloadCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? DownloadCellView ?? DownloadCellView(identifier: identifier)
        cell.configure(
            with: rows[row],
            onCancel: { [weak self] id in self?.manager.cancel(id: id) },
            onPause: { [weak self] id in self?.manager.pause(id: id) },
            onResume: { [weak self] id in self?.manager.resume(id: id) },
            onShowInFinder: { path in
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            },
            onOpen: { path in
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            },
            onDelete: { [weak self] id in self?.manager.remove(id: id) },
            onCopyURL: { url in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
        )
        return cell
    }

    public func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        DownloadsRowView()
    }
}

// MARK: - Table (focus reporting)

/// NSTableView subclass that reports first-responder changes so the
/// container can route pane focus when the user clicks a row.
private final class FocusReportingTableView: NSTableView {
    var onBecameFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecameFirstResponder?() }
        return ok
    }
}

// MARK: - Row View (gray selection only)

/// Forces the non-emphasized gray selection color so the pane matches
/// the URL bar / command palette. Unlike `ListPaneView`'s row view,
/// this one doesn't do hover-to-select — every row-level interaction
/// in the downloads pane goes through the explicit action buttons
/// (Show in Finder / Open / Copy URL / Cancel / Remove), so a wandering
/// selection highlight would only suggest non-existent keyboard
/// activation on a row.
private final class DownloadsRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

// MARK: - Cell

private final class DownloadCellView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let urlLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let actionsStack = NSStackView()
    private var currentID: Int64 = 0
    private var currentDestination: String = ""
    private var currentURL: String = ""

    private var onCancel: ((Int64) -> Void)?
    private var onPause: ((Int64) -> Void)?
    private var onResume: ((Int64) -> Void)?
    private var onShowInFinder: ((String) -> Void)?
    private var onOpen: ((String) -> Void)?
    private var onDelete: ((Int64) -> Void)?
    private var onCopyURL: ((String) -> Void)?

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func setup() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        urlLabel.font = .systemFont(ofSize: 11)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingTail
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.toolTip = ""

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        actionsStack.orientation = .horizontal
        actionsStack.spacing = 4
        actionsStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(urlLabel)
        addSubview(statusLabel)
        addSubview(progressBar)
        addSubview(actionsStack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: actionsStack.leadingAnchor, constant: -8),

            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            urlLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            urlLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            progressBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            progressBar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 4),

            actionsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    func configure(
        with download: Download,
        onCancel: @escaping (Int64) -> Void,
        onPause: @escaping (Int64) -> Void,
        onResume: @escaping (Int64) -> Void,
        onShowInFinder: @escaping (String) -> Void,
        onOpen: @escaping (String) -> Void,
        onDelete: @escaping (Int64) -> Void,
        onCopyURL: @escaping (String) -> Void
    ) {
        currentID = download.id
        currentDestination = download.destination
        currentURL = download.url
        self.onCancel = onCancel
        self.onPause = onPause
        self.onResume = onResume
        self.onShowInFinder = onShowInFinder
        self.onOpen = onOpen
        self.onDelete = onDelete
        self.onCopyURL = onCopyURL

        titleLabel.stringValue = download.filename.isEmpty ? download.url : download.filename
        urlLabel.stringValue = download.url
        urlLabel.toolTip = download.url
        statusLabel.stringValue = Self.statusLine(for: download)

        // Progress bar is visible for downloading + paused (paused
        // shows a static frozen bar at the last recorded progress so
        // the user sees how far through they are). Terminal states
        // hide it entirely.
        switch download.state {
        case .downloading:
            progressBar.isHidden = false
            if download.totalBytes > 0 {
                progressBar.isIndeterminate = false
                progressBar.doubleValue = Double(download.bytesWritten) / Double(download.totalBytes)
            } else {
                progressBar.isIndeterminate = true
                progressBar.startAnimation(nil)
            }
        case .paused:
            progressBar.isHidden = false
            progressBar.isIndeterminate = false
            progressBar.stopAnimation(nil)
            progressBar.doubleValue = download.totalBytes > 0
                ? Double(download.bytesWritten) / Double(download.totalBytes)
                : 0
        case .completed, .failed, .cancelled:
            progressBar.isHidden = true
            progressBar.stopAnimation(nil)
        }

        rebuildActions(for: download.state)
    }

    private static func statusLine(for download: Download) -> String {
        let timestamp = timeFormatter.string(from: download.completedAt ?? download.startedAt)
        switch download.state {
        case .downloading:
            if download.totalBytes > 0 {
                let percent = Int((Double(download.bytesWritten) / Double(download.totalBytes)) * 100)
                return "\(percent)% · \(formatBytes(download.bytesWritten)) / \(formatBytes(download.totalBytes))"
            }
            return formatBytes(download.bytesWritten)
        case .paused:
            if download.totalBytes > 0 {
                let percent = Int((Double(download.bytesWritten) / Double(download.totalBytes)) * 100)
                return "Paused · \(percent)% · \(formatBytes(download.bytesWritten)) / \(formatBytes(download.totalBytes))"
            }
            let size = formatBytes(download.bytesWritten)
            return size.isEmpty ? "Paused" : "Paused · \(size)"
        case .completed:
            let size = formatBytes(download.bytesWritten)
            return size.isEmpty
                ? "Completed · \(timestamp)"
                : "Completed · \(size) · \(timestamp)"
        case .failed:
            return "Failed · \(download.errorMessage ?? "Unknown error") · \(timestamp)"
        case .cancelled:
            return "Cancelled · \(timestamp)"
        }
    }

    /// Human-readable byte count. Returns an empty string for 0 so
    /// callers can decide whether to show a placeholder — the stock
    /// `ByteCountFormatter` renders 0 as "Zero KB", which reads as a
    /// UI bug on successful downloads where the count just hasn't
    /// been resolved yet.
    private static func formatBytes(_ value: Int64) -> String {
        value > 0 ? byteFormatter.string(fromByteCount: value) : ""
    }

    private func rebuildActions(for state: DownloadState) {
        actionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Per-state action set. `xmark` is shared between "cancel the
        // running download" and "remove this row" — the intent differs
        // but the visual is the same because both actions dismiss the
        // row from the manager's point of view. Trash icon was avoided
        // because it implies the downloaded file would be deleted.
        switch state {
        case .downloading:
            actionsStack.addArrangedSubview(makeButton(
                symbol: "doc.on.doc", tooltip: "Copy URL",
                action: #selector(handleCopyURL)
            ))
            actionsStack.addArrangedSubview(makeButton(
                symbol: "pause.circle", tooltip: "Pause",
                action: #selector(handlePause)
            ))
            actionsStack.addArrangedSubview(makeButton(
                symbol: "xmark", tooltip: "Cancel",
                action: #selector(handleCancel)
            ))
        case .paused:
            actionsStack.addArrangedSubview(makeButton(
                symbol: "doc.on.doc", tooltip: "Copy URL",
                action: #selector(handleCopyURL)
            ))
            actionsStack.addArrangedSubview(makeButton(
                symbol: "play.circle", tooltip: "Resume",
                action: #selector(handleResume)
            ))
            actionsStack.addArrangedSubview(makeButton(
                symbol: "xmark", tooltip: "Remove from list",
                action: #selector(handleDelete)
            ))
        case .completed:
            actionsStack.addArrangedSubview(makeButton(
                symbol: "doc.on.doc", tooltip: "Copy URL",
                action: #selector(handleCopyURL)
            ))
            actionsStack.addArrangedSubview(makeButton(
                symbol: "folder", tooltip: "Show in Finder",
                action: #selector(handleShowInFinder)
            ))
            actionsStack.addArrangedSubview(makeButton(
                symbol: "arrow.up.forward.app", tooltip: "Open",
                action: #selector(handleOpen)
            ))
            actionsStack.addArrangedSubview(makeButton(
                symbol: "xmark", tooltip: "Remove from list",
                action: #selector(handleDelete)
            ))
        case .failed, .cancelled:
            actionsStack.addArrangedSubview(makeButton(
                symbol: "doc.on.doc", tooltip: "Copy URL",
                action: #selector(handleCopyURL)
            ))
            actionsStack.addArrangedSubview(makeButton(
                symbol: "xmark", tooltip: "Remove from list",
                action: #selector(handleDelete)
            ))
        }
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
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
        return button
    }

    @objc private func handleCancel() { onCancel?(currentID) }
    @objc private func handlePause() { onPause?(currentID) }
    @objc private func handleResume() { onResume?(currentID) }
    @objc private func handleShowInFinder() { onShowInFinder?(currentDestination) }
    @objc private func handleOpen() { onOpen?(currentDestination) }
    @objc private func handleDelete() { onDelete?(currentID) }
    @objc private func handleCopyURL() { onCopyURL?(currentURL) }
}
