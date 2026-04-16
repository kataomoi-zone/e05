import AppKit

/// A suggestion entry displayed in the URL bar dropdown.
public struct Suggestion: Equatable {
    public let url: String
    public let title: String
    public let isBookmark: Bool

    public init(url: String, title: String, isBookmark: Bool) {
        self.url = url
        self.title = title
        self.isBookmark = isBookmark
    }

    public var displayTitle: String {
        let prefix = isBookmark ? "\u{2605} " : ""
        return title.isEmpty ? "\(prefix)\(url)" : "\(prefix)\(title)"
    }

    /// Rank a pool of suggestion candidates against a fuzzy query.
    ///
    /// Candidates are ranked by `FuzzyMatcher` across their title and URL;
    /// items with no subsequence match are dropped. Bookmarks receive a
    /// constant score bonus so they outrank equal-fuzzy-score history —
    /// matching the previous SQLite-based behavior where bookmarks always
    /// sorted above history in the URL-bar dropdown. The bonus is small
    /// enough that a strong fuzzy match on a history item (e.g. prefix
    /// match on a long URL) still wins over a weaker bookmark match.
    ///
    /// Caller responsibility: build `candidates` with dedup already applied
    /// (e.g. URL appearing in both bookmarks and history should be present
    /// only once, marked `isBookmark: true`). This keeps the ranker free of
    /// dedup policy decisions.
    ///
    /// - Parameters:
    ///   - query: search query. Empty query ranks by bookmark bonus only
    ///     (bookmarks first, then input order within each group), limited
    ///     to `maxResults`.
    ///   - candidates: pre-built suggestion pool.
    ///   - bookmarkBonus: score added to `isBookmark == true` items. Default
    ///     50 ≈ one consecutive-match bonus (`scoreConsecutive = 35`) plus
    ///     a small margin.
    ///   - maxResults: cap on returned suggestions.
    public static func rank(
        query: String,
        candidates: [Suggestion],
        bookmarkBonus: Int = 50,
        maxResults: Int = 15
    ) -> [Suggestion] {
        let ranked = FuzzyMatcher.rank(
            query: query,
            items: candidates,
            keys: { [$0.title, $0.url] }
        )
        // Tag with enumeration index before sorting so that ties are broken
        // by the order produced by FuzzyMatcher.rank (itself stable by input
        // order). Swift's Array.sorted(by:) is documented as unstable, so
        // relying on sorted() alone would leave same-score results in an
        // undefined order across stdlib versions.
        struct Scored {
            let item: Suggestion
            let score: Int
            let order: Int
        }
        let scored: [Scored] = ranked.enumerated().map { index, pair in
            let boosted = pair.match.score + (pair.item.isBookmark ? bookmarkBonus : 0)
            return Scored(item: pair.item, score: boosted, order: index)
        }
        return scored
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.order < rhs.order
            }
            .prefix(maxResults)
            .map(\.item)
    }
}

/// Dropdown list of URL suggestions shown below the URL bar.
@MainActor
public final class SuggestionListView: NSView {
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var suggestions: [Suggestion] = []
    // Derived from the cell's Auto Layout fitting size so that rowHeight
    // equals (title intrinsic + 2pt gap + URL intrinsic) exactly. Using a
    // hard-coded constant left ~6pt of slack between the labels and the
    // highlight frame because NSTextField intrinsic heights depend on font
    // metrics that vary slightly across system updates. A fitted value
    // guarantees zero top/bottom padding regardless of font.
    //
    // Computed once per session via static let — font metrics never change
    // during an app run, so recomputing on every SuggestionListView init
    // (one per pane) just burns cycles.
    private static let rowHeight: CGFloat = {
        let cell = SuggestionCellView()
        cell.titleLabel.stringValue = "X"
        cell.urlLabel.stringValue = "X"
        return ceil(cell.fittingSize.height)
    }()
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
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .regular
        // macOS 11+ defaults NSTableView.style to .automatic which resolves to
        // .inset and injects non-customisable padding on all four row edges
        // (Scintilla bug #2248 reports the same "single-hit dropdown shows a
        // bogus scrollbar" symptom). .plain mitigates most of it but cells
        // still carry hard-coded padding per Apple Developer Forums #666341
        // (Etresoft: "table view cells have some hard-coded padding you
        // can't avoid"). The row-view override below neutralises what
        // remains.
        tableView.style = .plain
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
        // autohidesScrollers only takes effect when scrollerStyle is .overlay.
        // If the user has System Settings → Appearance → Show scroll bars set
        // to "Always", NSScrollView defaults to .legacy and the scrollbar is
        // always visible regardless of documentView/clipView sizing. Force
        // overlay to guarantee the autohide contract.
        scrollView.scrollerStyle = .overlay
        // Stop AppKit from silently inflating contentInsets (e.g. for
        // window-level safe areas). A non-zero inset makes clipView visible
        // area smaller than documentView.height, re-creating the scrollbar
        // symptom we just fixed elsewhere.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Inset the scrollView 6pt from the top and bottom so the dropdown
        // gets visual breathing room without inflating the clipView beyond
        // the documentView. Zero inset was "content-tight" but looked cramped;
        // putting padding on the outer container (instead of inside each cell)
        // keeps documentView == clipView height, so the overlay scrollbar
        // never appears on single-hit queries.
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
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
        // Only expose a scroller when content actually overflows the visible
        // window. With N <= maxVisibleRows every row is already on screen so
        // the scroller serves no purpose — and autohide can't be fully
        // trusted across system settings and layout timing.
        scrollView.hasVerticalScroller = suggestions.count > maxVisibleRows
        // Height = (rowHeight * visible rows) + 12pt of outer inset (6pt top
        // + 6pt bottom, matching the scrollView's leading/trailing pin). The
        // scrollView itself is sized at rowHeight * N so its clipView matches
        // the documentView exactly — no bogus scrollbar — while the extra
        // 12pt becomes visible breathing room on the SuggestionListView
        // background layer.
        frame.size.height = CGFloat(visibleRows) * Self.rowHeight + 12
        // Setting .frame directly doesn't propagate through Auto Layout to
        // our pinned scrollView. If the previous update filled 8 rows and
        // this one has 1, scrollView stays at the old height, clipping the
        // new cell. Force the layout pass synchronously.
        needsLayout = true
        layoutSubtreeIfNeeded()

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

// MARK: - Cell View

/// Two-line cell showing the suggestion title on top and the URL below.
///
/// Intentionally inherits from `NSView`, not `NSTableCellView`. `NSTableCellView`
/// has undocumented auto-behavior around its `textField` / `imageView` /
/// `backgroundStyle` properties that interferes with subviews — in our case
/// the URL label was laid out correctly (topAnchor/bottomAnchor, frame
/// within bounds, hidden=false, alpha=1) yet never drew on screen. Dropping
/// the `NSTableCellView` base class eliminates that entire magic surface.
/// `NSTableView`'s `viewFor:` delegate accepts any `NSView`.
@MainActor
private final class SuggestionCellView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let urlLabel = NSTextField(labelWithString: "")

    // Flipped (top-down) coordinates match the enclosing NSTableView/
    // NSTableRowView so topAnchor/bottomAnchor constraints map to their
    // visual meanings without mental gymnastics.
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func configure() {
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        urlLabel.font = .systemFont(ofSize: 11)
        urlLabel.textColor = NSColor(white: 0.75, alpha: 1.0)
        urlLabel.lineBreakMode = .byTruncatingTail
        urlLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(urlLabel)

        // Flush layout: title pinned to the cell top, URL pinned 2pt below the
        // title. No top/bottom padding — any padding here would make the
        // single-hit dropdown taller than its content and surface a bogus
        // scrollbar. The bottom constraint is `lessThanOrEqual` so that font
        // metric variance can't force the cell to stretch past rowHeight.
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),

            urlLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            urlLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            urlLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }
}

// MARK: - Row View

/// Custom NSTableRowView that places its cell views flush to the row bounds.
///
/// Apple Developer Forums #666341 documents that NSTableView inserts
/// hard-coded padding between its default NSTableRowView and the hosted
/// NSView cell. Even with `tableView.style = .plain` and
/// `intercellSpacing = .zero` the stock row view keeps that slack, which
/// shows up as visible gaps between the cell content and the selection
/// highlight, and inflates documentView height enough to trigger a bogus
/// scrollbar on single-hit results. Overriding `layout()` to rewrite each
/// subview's frame back to `bounds` after AppKit's own layout pass neutralises
/// the padding without needing to subclass NSTableView itself.
@MainActor
private final class SuggestionRowView: NSTableRowView {
    /// Reset subview frames to the row bounds on every layout pass.
    ///
    /// The cell's own Auto Layout constraints (leading/trailing with 8pt
    /// padding, title/URL vertical pins) stay intact because the cell's
    /// subviews keep `translatesAutoresizingMaskIntoConstraints = false`.
    /// What gets overwritten is the cell-view-frame chosen by NSTableView
    /// when it attaches the cell to the row — on macOS 11+ that placement
    /// is offset by the non-customisable row padding. Rewriting to
    /// `bounds` after `super.layout()` shifts the whole cell to hug the
    /// highlight frame, and the cell's internal constraints reposition
    /// the labels inside it on the next pass. Hence the "redundant"
    /// assignment actually does work that the internal constraints can't:
    /// it controls the outer container, not the inner layout.
    override func layout() {
        super.layout()
        for subview in subviews {
            subview.frame = bounds
        }
    }
}

// MARK: - NSTableViewDelegate

extension SuggestionListView: NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        // Return a padding-free row view per Apple Developer Forums #666341.
        let rowID = NSUserInterfaceItemIdentifier("SuggestionRow")
        if let reused = tableView.makeView(withIdentifier: rowID, owner: nil) as? SuggestionRowView {
            return reused
        }
        let row = SuggestionRowView()
        row.identifier = rowID
        return row
    }

    public func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard suggestions.indices.contains(row) else { return nil }
        let suggestion = suggestions[row]

        let cellID = NSUserInterfaceItemIdentifier("SuggestionCell")
        let cell: SuggestionCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? SuggestionCellView {
            cell = reused
        } else {
            cell = SuggestionCellView()
            cell.identifier = cellID
        }

        cell.titleLabel.stringValue = suggestion.displayTitle
        cell.urlLabel.stringValue = suggestion.url
        return cell
    }
}
