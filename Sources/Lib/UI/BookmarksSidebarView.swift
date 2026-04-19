import AppKit

/// Bookmarks list rendered inside the sidebar's `bookmarks` mode.
/// Subscribes to the shared `Bookmarks` store so external mutations
/// (URL bar Cmd+D, command palette Toggle Bookmark) reflect live
/// without a manual reload.
///
/// Sized for the 260pt sidebar: transparent background (Liquid Glass
/// stays visible), no header (the mode name is already in the places
/// section), compact 40pt rows with title + host, and a hover-revealed
/// delete button.
@MainActor
final class BookmarksSidebarView: NSView {
    /// Fired on single click. UX policy: always open in a new browser
    /// column in the current workspace.
    var onOpen: ((String) -> Void)?

    /// Fired on Cmd+click. UX policy: always open in a newly created
    /// workspace. The container is responsible for the
    /// `createWorkspace()` + `addColumn` orchestration and for
    /// no-op'ing at the workspace cap.
    var onOpenInNewWorkspace: ((String) -> Void)?

    private let bookmarks: Bookmarks
    private var listenerToken: BookmarksListenerToken?
    private let scrollView = NSScrollView()
    private let tableView = BookmarksTableView()
    private let emptyLabel = NSTextField(labelWithString: "No bookmarks yet")
    private var rows: [Bookmarks.Entry] = []
    private var scrollObserver: NSObjectProtocol?

    init(bookmarks: Bookmarks) {
        self.bookmarks = bookmarks
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setupLayout()
        reload()
        listenerToken = bookmarks.addListener { [weak self] in self?.reload() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    // NOTE: No deinit cleanup for the listener registration. The closure
    // captures `[weak self]`, so post-dealloc invocations are no-ops.
    // `Bookmarks` is a process-lifetime singleton held by the container
    // and the sidebar view is recreated at most per container, so the
    // listener list never grows beyond a handful of entries.

    private func setupLayout() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bookmark"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = BookmarksSidebarCellView.height
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
            self.deleteRow(at: self.tableView.selectedRow)
        }
        tableView.onActivateRow = { [weak self] in
            guard let self else { return }
            self.activateRow(at: self.tableView.selectedRow, newWorkspace: false)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Hover-revealed × buttons rely on NSTrackingArea with
        // `.inVisibleRect`, which doesn't deliver `mouseExited` when a
        // hovered cell scrolls out from under a stationary cursor. Watch
        // the clip view's bounds change (fired continuously during both
        // trackpad inertia and wheel scrolls) so we can force-hide every
        // row's delete button whenever the list scrolls.
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideAllDeleteButtons() }
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
        rows = bookmarks.all()
        tableView.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
    }

    private func hideAllDeleteButtons() {
        tableView.enumerateAvailableRowViews { _, row in
            if let cell = self.tableView.view(
                atColumn: 0, row: row, makeIfNecessary: false
            ) as? BookmarksSidebarCellView {
                cell.forceHideDeleteButton()
            }
        }
    }

    @objc private func handleClick() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        let cmdHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        activateRow(at: row, newWorkspace: cmdHeld)
    }

    private func activateRow(at row: Int, newWorkspace: Bool) {
        guard rows.indices.contains(row) else { return }
        let url = rows[row].url
        if newWorkspace {
            onOpenInNewWorkspace?(url)
        } else {
            onOpen?(url)
        }
    }

    private func deleteRow(at index: Int) {
        guard rows.indices.contains(index) else { return }
        let entry = rows[index]
        // Remove from the store first — its listener will trigger
        // `reload()`, which handles the row removal and selection
        // restoration consistently with any external deletion source
        // (URL bar, command palette, etc.).
        bookmarks.remove(id: entry.id)
    }
}

// MARK: - NSTableViewDataSource

extension BookmarksSidebarView: NSTableViewDataSource {
    func numberOfRows(in _: NSTableView) -> Int { rows.count }
}

// MARK: - NSTableViewDelegate

extension BookmarksSidebarView: NSTableViewDelegate {
    func tableView(
        _ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("BookmarksSidebarCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? BookmarksSidebarCellView ?? BookmarksSidebarCellView(identifier: identifier)
        cell.configure(with: rows[row])
        cell.onDelete = { [weak self] id in
            guard let self,
                  let idx = self.rows.firstIndex(where: { $0.id == id }) else { return }
            self.deleteRow(at: idx)
        }
        return cell
    }

    func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        BookmarksSidebarRowView()
    }
}

// MARK: - Cell

/// Compact two-line cell: bookmark title on top (label color) and
/// host on the bottom (secondary). Hovering reveals a trailing
/// delete (×) button. Transparent background so the Liquid Glass
/// sidebar remains visible through the row.
private final class BookmarksSidebarCellView: NSView {
    static let height: CGFloat = 40

    private let titleLabel = NSTextField(labelWithString: "")
    private let hostLabel = NSTextField(labelWithString: "")
    private let deleteButton = HoverIconButton()
    private var currentID: Int64 = 0
    private var trackingArea: NSTrackingArea?

    var onDelete: ((Int64) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
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

        hostLabel.font = .systemFont(ofSize: 10)
        hostLabel.textColor = .secondaryLabelColor
        hostLabel.lineBreakMode = .byTruncatingTail
        hostLabel.drawsBackground = false
        hostLabel.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: "Delete"
        )
        deleteButton.imagePosition = .imageOnly
        deleteButton.isBordered = false
        deleteButton.bezelStyle = .regularSquare
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.toolTip = "Delete"
        // Hover-revealed: the cell's tracking area toggles visibility.
        deleteButton.isHidden = true

        addSubview(titleLabel)
        addSubview(hostLabel)
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -6),

            hostLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            hostLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            hostLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            deleteButton.widthAnchor.constraint(equalToConstant: 18),
            deleteButton.heightAnchor.constraint(equalToConstant: 18),
        ])
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
        deleteButton.isHidden = false
    }

    override func mouseExited(with _: NSEvent) {
        // AppKit delivers a spurious mouseExited when the cursor moves
        // from this cell's tracking area into a subview's own tracking
        // area (a HoverIconButton in our trailing slot) and back —
        // ignore those so the hover-reveal doesn't flicker off mid-aim.
        if cursorIsStillInsideBounds() { return }
        deleteButton.isHidden = true
    }

    override func cursorUpdate(with _: NSEvent) {
        NSCursor.pointingHand.set()
    }

    /// Force-hide the hover-revealed × button regardless of tracking
    /// state. Used by the parent list when the clip view scrolls,
    /// because NSTrackingArea with `.inVisibleRect` doesn't reliably
    /// fire `mouseExited` for cells that scroll out from under a
    /// stationary cursor.
    func forceHideDeleteButton() {
        deleteButton.isHidden = true
    }

    func configure(with entry: Bookmarks.Entry) {
        currentID = entry.id
        titleLabel.stringValue = entry.title.isEmpty ? entry.url : entry.title
        // Fall back to the full URL if the host can't be parsed — rare
        // but possible for entries stored with an atypical scheme.
        hostLabel.stringValue = URL(string: entry.url)?.host() ?? entry.url
        // Re-enable after reuse so a cell whose previous occupant was
        // deleted serves new rows normally. Visibility is driven by
        // the tracking area; resetting `isHidden` here would fight it.
        deleteButton.isEnabled = true
    }

    @objc private func deleteTapped() {
        // Disable immediately so the button can't fire twice during
        // the store's listener-driven reload cycle.
        deleteButton.isEnabled = false
        onDelete?(currentID)
    }
}

// MARK: - Row view

/// Row view that moves the table selection on hover (unifying mouse
/// and keyboard feedback into a single highlight) and forces the
/// non-key gray selection color so the sidebar's focus state doesn't
/// flash blue when the list steals first-responder momentarily.
private final class BookmarksSidebarRowView: NSTableRowView {
    private var trackingArea: NSTrackingArea?

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

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
        guard let tableView = superview as? NSTableView else { return }
        let row = tableView.row(for: self)
        guard row >= 0, tableView.selectedRow != row else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
}

// MARK: - Table view

/// `NSTableView` subclass that intercepts Delete and Return keys for
/// the sidebar bookmarks list, and adds emacs-style Ctrl+N / Ctrl+P
/// navigation alongside the default arrow keys.
private final class BookmarksTableView: NSTableView {
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
