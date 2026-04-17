import AppKit

/// Data backing a `ListPaneView`. Concrete implementations wrap a SQLite
/// store (history / bookmarks / downloads) and expose a uniform row shape
/// so the view stays data-source agnostic.
@MainActor
public protocol ListPaneDataSource: AnyObject {
    /// Header title shown at the top of the pane.
    var title: String { get }
    /// Snapshot of all rows to display, sorted most-relevant first.
    func load() -> [ListPaneRow]
    /// Remove the entry identified by `id` from the underlying store.
    func delete(id: Int64)
}

/// View-model row rendered by `ListPaneView`. `id` is the underlying DB
/// primary key so the view can report deletes back to the data source.
public struct ListPaneRow: Equatable {
    public let id: Int64
    public let title: String
    public let url: String
    public let subtitle: String

    public init(id: Int64, title: String, url: String, subtitle: String) {
        self.id = id
        self.title = title
        self.url = url
        self.subtitle = subtitle
    }
}

/// Generic list pane used by `e05://history`, `e05://bookmarks`, and
/// future `e05://downloads`. Single-column `NSTableView` with a header
/// label; rows show title + URL + subtitle + a hover-revealed × button.
///
/// Interactions:
/// - Single click / Enter: invokes `onOpen` with the row's URL.
/// - Cmd+Click: invokes `onOpenInNewColumn` to open the URL alongside.
/// - Arrow keys / Ctrl+N/P: move selection.
/// - × button / Delete key: removes row from both UI and data source
///   (optimistic — no reload, selection preserved at same visual index).
@MainActor
public final class ListPaneView: NSView {
    private let dataSource: ListPaneDataSource
    private let scrollView = NSScrollView()
    private let tableView = FocusableTableView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No entries.")
    private var rows: [ListPaneRow] = []

    /// Invoked when the user activates a row (single click or Enter).
    public var onOpen: ((String) -> Void)?

    /// Invoked when the user activates a row with Cmd held (open alongside).
    public var onOpenInNewColumn: ((String) -> Void)?

    /// Invoked when the table becomes first responder (click or keyboard
    /// focus). Used by the container to route focus changes.
    public var onFocusChanged: (() -> Void)?

    /// The view that should receive keyboard focus when this pane is
    /// focused. The table view owns arrow-key navigation.
    public var focusTarget: NSView { tableView }

    public init(dataSource: ListPaneDataSource) {
        self.dataSource = dataSource
        super.init(frame: .zero)
        setup()
        reload()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    // MARK: - Public

    public func reload() {
        rows = dataSource.load()
        tableView.reloadData()
        updateEmptyState()
    }

    // MARK: - Setup

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor
        appearance = NSAppearance(named: .darkAqua)

        headerLabel.stringValue = dataSource.title
        headerLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        headerLabel.textColor = .labelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 56
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.style = .plain
        tableView.target = self
        tableView.action = #selector(handleClick)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onBecameFirstResponder = { [weak self] in
            self?.onFocusChanged?()
        }
        tableView.onDeleteKey = { [weak self] in
            guard let self else { return }
            self.deleteRow(at: self.tableView.selectedRow)
        }
        tableView.onActivateRow = { [weak self] in
            guard let self else { return }
            self.activateRow(at: self.tableView.selectedRow, newColumn: false)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func handleClick() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        // `NSApp.currentEvent` is the mouseUp that fired the action — check
        // Cmd to decide whether to open alongside or replace the pane.
        let cmdHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        activateRow(at: row, newColumn: cmdHeld)
    }

    private func activateRow(at row: Int, newColumn: Bool) {
        guard rows.indices.contains(row) else { return }
        let url = rows[row].url
        if newColumn {
            onOpenInNewColumn?(url)
        } else {
            onOpen?(url)
        }
    }

    private func deleteRow(at index: Int) {
        guard rows.indices.contains(index) else { return }
        let entry = rows.remove(at: index)
        tableView.removeRows(at: IndexSet(integer: index), withAnimation: .slideUp)
        dataSource.delete(id: entry.id)
        updateEmptyState()

        // Preserve selection at the same visual index so repeated Delete
        // key presses drain rows from where the user was navigating rather
        // than snapping back to row 0.
        guard !rows.isEmpty else { return }
        let newSelection = min(index, rows.count - 1)
        tableView.selectRowIndexes(
            IndexSet(integer: newSelection), byExtendingSelection: false
        )
        tableView.scrollRowToVisible(newSelection)
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !rows.isEmpty
    }
}

// MARK: - NSTableViewDataSource

extension ListPaneView: NSTableViewDataSource {
    public func numberOfRows(in _: NSTableView) -> Int { rows.count }
}

// MARK: - NSTableViewDelegate

extension ListPaneView: NSTableViewDelegate {
    public func tableView(
        _ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ListPaneCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? ListPaneCellView ?? ListPaneCellView(identifier: identifier)
        cell.configure(with: rows[row])
        cell.onDelete = { [weak self] id in
            guard let self,
                  let idx = self.rows.firstIndex(where: { $0.id == id }) else { return }
            self.deleteRow(at: idx)
        }
        return cell
    }

    public func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        HoverableRowView()
    }
}

// MARK: - Cell

private final class ListPaneCellView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let urlLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let deleteButton = HoverIconButton()
    private var currentID: Int64 = 0

    var onDelete: ((Int64) -> Void)?

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
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        urlLabel.font = .systemFont(ofSize: 11)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingTail
        urlLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

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

        addSubview(titleLabel)
        addSubview(urlLabel)
        addSubview(subtitleLabel)
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),

            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            urlLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            urlLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),
            deleteButton.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    func configure(with row: ListPaneRow) {
        currentID = row.id
        titleLabel.stringValue = row.title.isEmpty ? row.url : row.title
        urlLabel.stringValue = row.url
        subtitleLabel.stringValue = row.subtitle
        subtitleLabel.isHidden = row.subtitle.isEmpty
        // Re-enable after reuse so a cell whose previous occupant was
        // deleted serves new rows normally.
        deleteButton.isEnabled = true
    }

    @objc private func deleteTapped() {
        // Disable immediately so the button can't fire twice during the
        // slideUp animation. `configure(with:)` re-enables on cell reuse.
        deleteButton.isEnabled = false
        onDelete?(currentID)
    }
}

// MARK: - Focusable NSTableView

/// NSTableView subclass that reports first-responder changes, intercepts
/// the Delete / Return keys, and adds emacs-style Ctrl+N / Ctrl+P
/// selection movement alongside the default arrow keys.
private final class FocusableTableView: NSTableView {
    var onBecameFirstResponder: (() -> Void)?
    var onDeleteKey: (() -> Void)?
    var onActivateRow: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecameFirstResponder?() }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:  // Delete (Backspace), Forward Delete
            onDeleteKey?()
            return
        case 36, 76:   // Return, Keypad Enter
            onActivateRow?()
            return
        default:
            break
        }

        // Emacs-style selection movement: Ctrl+N (next), Ctrl+P (previous).
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

// MARK: - Hoverable NSTableRowView

/// Row view that moves the table selection to itself on hover, unifying
/// mouse and keyboard feedback into a single selection highlight
/// (otherwise keyboard arrow selection and a separate hover tint could
/// light up two different rows simultaneously).
///
/// `isEmphasized = false` forces the non-key / unfocused gray selection
/// color regardless of first-responder state, matching the gray
/// highlight used by URL bar suggestions and the command palette
/// (both of which are naturally non-emphasized because their text
/// field owns first responder).
private final class HoverableRowView: NSTableRowView {
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
        // View-based NSTableView places row views directly under the
        // table. Resolve our current row dynamically — captured indices
        // can become stale after row insertion / removal.
        guard let tableView = superview as? NSTableView else { return }
        let row = tableView.row(for: self)
        guard row >= 0, tableView.selectedRow != row else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
}
