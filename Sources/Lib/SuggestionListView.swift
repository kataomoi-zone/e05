import AppKit

/// A suggestion entry displayed in the URL bar dropdown.
public struct Suggestion {
    public let url: String
    public let title: String
    public let isBookmark: Bool

    public var displayTitle: String {
        let prefix = isBookmark ? "\u{2605} " : ""
        return title.isEmpty ? "\(prefix)\(url)" : "\(prefix)\(title)"
    }
}

/// Dropdown list of URL suggestions shown below the URL bar.
@MainActor
public final class SuggestionListView: NSView {
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var suggestions: [Suggestion] = []
    private let rowHeight: CGFloat = 32
    private let maxVisibleRows = 8

    /// Called when user selects a suggestion.
    public var onSelect: ((Suggestion) -> Void)?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    private func setup() {
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.95).cgColor
        layer?.cornerRadius = 4
        layer?.borderColor = NSColor(white: 0.3, alpha: 1.0).cgColor
        layer?.borderWidth = 1

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(handleClick)
        tableView.doubleAction = #selector(handleClick)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Public API

    /// Update the suggestions list and resize.
    public func update(suggestions: [Suggestion]) {
        self.suggestions = suggestions
        tableView.reloadData()

        if suggestions.isEmpty {
            isHidden = true
            return
        }

        isHidden = false
        let visibleRows = min(suggestions.count, maxVisibleRows)
        let height = CGFloat(visibleRows) * rowHeight + 4 // padding
        frame.size.height = height

        // Auto-select first row
        if !suggestions.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// Move selection up.
    public func selectPrevious() {
        guard !suggestions.isEmpty else { return }
        let current = tableView.selectedRow
        let next = current > 0 ? current - 1 : suggestions.count - 1
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    /// Move selection down.
    public func selectNext() {
        guard !suggestions.isEmpty else { return }
        let current = tableView.selectedRow
        let next = current < suggestions.count - 1 ? current + 1 : 0
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    /// Get the currently selected suggestion.
    public var selectedSuggestion: Suggestion? {
        let row = tableView.selectedRow
        guard suggestions.indices.contains(row) else { return nil }
        return suggestions[row]
    }

    /// Hide the suggestion list.
    public func dismiss() {
        suggestions = []
        tableView.reloadData()
        isHidden = true
    }

    // MARK: - Actions

    @objc private func handleClick() {
        guard let suggestion = selectedSuggestion else { return }
        onSelect?(suggestion)
    }
}

// MARK: - NSTableViewDataSource

extension SuggestionListView: NSTableViewDataSource {
    public func numberOfRows(in _: NSTableView) -> Int {
        suggestions.count
    }
}

// MARK: - NSTableViewDelegate

extension SuggestionListView: NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard suggestions.indices.contains(row) else { return nil }
        let suggestion = suggestions[row]

        let cellID = NSUserInterfaceItemIdentifier("SuggestionCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID

            let titleLabel = NSTextField(labelWithString: "")
            titleLabel.font = .systemFont(ofSize: 12)
            titleLabel.textColor = .white
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            let urlLabel = NSTextField(labelWithString: "")
            urlLabel.font = .systemFont(ofSize: 10)
            urlLabel.textColor = NSColor(white: 0.6, alpha: 1.0)
            urlLabel.lineBreakMode = .byTruncatingTail
            urlLabel.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(titleLabel)
            cell.addSubview(urlLabel)
            cell.textField = titleLabel

            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                titleLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: -6),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),

                urlLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                urlLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: 6),
                urlLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            ])

            // Tag the url label for reuse
            urlLabel.tag = 100
        }

        cell.textField?.stringValue = suggestion.displayTitle

        if let urlLabel = cell.viewWithTag(100) as? NSTextField {
            urlLabel.stringValue = suggestion.url
        }

        return cell
    }
}
