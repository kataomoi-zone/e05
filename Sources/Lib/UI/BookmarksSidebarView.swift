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
    private let tableView = SidebarListTableView()
    private let emptyLabel = NSTextField(labelWithString: "No bookmarks yet")
    private var rows: [Bookmarks.Entry] = []
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?

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

    deinit {
        // Block-based observers keep their closure retained inside
        // NotificationCenter until the token is passed to
        // `removeObserver`, so a `[weak self]` capture alone does not
        // free the subscription. The `Bookmarks` listener is left
        // registered intentionally: the store is process-lifetime and
        // the closure weak-captures self, so post-dealloc invocations
        // are no-ops.
        if let token = scrollObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

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
        rows = bookmarks.all()
        tableView.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
    }

    private func hideAllActionButtons() {
        tableView.enumerateAvailableRowViews { _, row in
            if let cell = self.tableView.view(
                atColumn: 0, row: row, makeIfNecessary: false
            ) as? SidebarListCellView {
                cell.forceHideHoverActions()
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
        cell.onRowAction = { [weak self] id, action in
            self?.handleRowAction(id: id, action: action)
        }
        return cell
    }

    func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        SidebarListRowView()
    }
}

// MARK: - Row action routing

extension BookmarksSidebarView {
    fileprivate func handleRowAction(id: Int64, action: BookmarkRowAction) {
        guard let entry = rows.first(where: { $0.id == id }) else { return }
        switch action {
        case .edit:
            presentEditSheet(for: entry)
        case .delete:
            bookmarks.remove(id: entry.id)
        case .copyURL:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(entry.url, forType: .string)
        case .openInCurrentWorkspace:
            onOpen?(entry.url)
        case .openInNewWorkspace:
            onOpenInNewWorkspace?(entry.url)
        }
    }

    /// Present a modal sheet with Name and URL fields pre-populated
    /// from the bookmark. Save commits via `Bookmarks.update`; a
    /// UNIQUE collision (URL already bookmarked) surfaces a follow-up
    /// warning alert instead of silently swallowing the edit.
    private func presentEditSheet(for entry: Bookmarks.Entry) {
        guard let window else { return }

        let alert = NSAlert()
        alert.messageText = "Edit Bookmark"
        alert.informativeText = "Update the name or URL."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(string: entry.title)
        nameField.placeholderString = "Name"
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let urlField = NSTextField(string: entry.url)
        urlField.placeholderString = "URL"
        urlField.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [nameField, urlField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        // NSAlert sizes its accessoryView from a combination of the
        // initial frame and Auto Layout's fittingSize. Seeding the
        // frame is not dead code: without it, the accessoryView is
        // installed at NSRect.zero and collapses to a sliver before
        // the layout pass resolves the text-field width constraints.
        // Keep both the frame seed and the constraint to get a sheet
        // that's sized correctly on its first appearance.
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(equalToConstant: 320),
            urlField.widthAnchor.constraint(equalToConstant: 320),
        ])

        alert.accessoryView = stack
        // Focus the name field so the user can type immediately.
        alert.window.initialFirstResponder = nameField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let newTitle = nameField.stringValue
            let newURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty URL would leave a ghost row impossible to focus —
            // surface it as an error instead of silently no-op'ing.
            guard !newURL.isEmpty else {
                self.presentEditError(message: "URL cannot be empty.")
                return
            }
            let ok = self.bookmarks.update(id: entry.id, title: newTitle, url: newURL)
            if !ok {
                self.presentEditError(
                    message: "That URL is already bookmarked — changes were not saved."
                )
            }
        }
    }

    private func presentEditError(message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Could not save bookmark"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}

// MARK: - Cell actions

/// Per-row action surfaced via the trailing ellipsis menu. A single
/// callback on the cell dispatches on this enum so the parent view
/// can own all the orchestration (store mutation, pasteboard writes,
/// workspace routing, edit sheet presentation) in one place.
enum BookmarkRowAction {
    case edit
    case delete
    case copyURL
    case openInCurrentWorkspace
    case openInNewWorkspace
}

// MARK: - Cell

/// Compact two-line cell: bookmark title on top (label color) and
/// host on the bottom (secondary). Hovering reveals a trailing
/// ellipsis (…) button that opens an action menu (Edit… / Delete /
/// Copy URL / Open in current or new workspace). Transparent
/// background so the Liquid Glass sidebar remains visible through
/// the row.
private final class BookmarksSidebarCellView: SidebarListCellView {
    static let height: CGFloat = 40

    private let titleLabel = NSTextField(labelWithString: "")
    private let hostLabel = NSTextField(labelWithString: "")
    private let actionButton = HoverIconButton()
    private var currentID: Int64 = 0

    var onRowAction: ((Int64, BookmarkRowAction) -> Void)?

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

        actionButton.image = NSImage(
            systemSymbolName: "ellipsis", accessibilityDescription: "More actions"
        )
        actionButton.imagePosition = .imageOnly
        actionButton.isBordered = false
        actionButton.bezelStyle = .regularSquare
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        actionButton.toolTip = "More actions"
        // Hover-revealed: the cell's tracking area toggles visibility.
        actionButton.isHidden = true

        addSubview(titleLabel)
        addSubview(hostLabel)
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -6),

            hostLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            hostLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            hostLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionButton.widthAnchor.constraint(equalToConstant: 18),
            actionButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    override func setHoverActionsHidden(_ hidden: Bool) {
        actionButton.isHidden = hidden
    }

    func configure(with entry: Bookmarks.Entry) {
        currentID = entry.id
        titleLabel.stringValue = entry.title.isEmpty ? entry.url : entry.title
        // Fall back to the full URL if the host can't be parsed — rare
        // but possible for entries stored with an atypical scheme.
        hostLabel.stringValue = URL(string: entry.url)?.host() ?? entry.url
        // Tooltips surface the full text when the compact 260pt sidebar
        // width truncates either label. The title tooltip shows the URL
        // as a secondary line so a hover reveals "what is this?" even
        // for bookmarks with identical titles on different hosts. When
        // the bookmark has no title the main label already renders the
        // URL, so a tooltip with the same string adds no information —
        // leave it nil so the hostLabel tooltip remains the sole entry
        // point for the full URL.
        titleLabel.toolTip = entry.title.isEmpty
            ? nil
            : "\(entry.title)\n\(entry.url)"
        hostLabel.toolTip = entry.url
    }

    @objc private func actionTapped() {
        let menu = NSMenu()

        let editItem = NSMenuItem(title: "Edit…", action: #selector(menuEdit), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)

        let copyItem = NSMenuItem(title: "Copy URL", action: #selector(menuCopyURL), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "Open in Current Workspace",
            action: #selector(menuOpenInCurrent),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let openNewItem = NSMenuItem(
            title: "Open in New Workspace",
            action: #selector(menuOpenInNew),
            keyEquivalent: ""
        )
        openNewItem.target = self
        menu.addItem(openNewItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(menuDelete), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)

        // Position the menu flush to the action button's bottom-left
        // so the first item lines up under the glyph.
        let origin = NSPoint(x: 0, y: actionButton.bounds.height)
        menu.popUp(positioning: nil, at: origin, in: actionButton)
    }

    @objc private func menuEdit() { onRowAction?(currentID, .edit) }
    @objc private func menuDelete() { onRowAction?(currentID, .delete) }
    @objc private func menuCopyURL() { onRowAction?(currentID, .copyURL) }
    @objc private func menuOpenInCurrent() { onRowAction?(currentID, .openInCurrentWorkspace) }
    @objc private func menuOpenInNew() { onRowAction?(currentID, .openInNewWorkspace) }
}

