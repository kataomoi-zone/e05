import AppKit

/// Dropdown list shown below the URL bar. Renders `SuggestionCellModel`
/// values; selection is reported as an index so the caller retains
/// ownership of the original domain objects.
@MainActor
public final class SuggestionListView: NSView {
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private var items: [SuggestionCellModel] = []
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
  /// Two-line row: primary + 2pt gap + secondary.
  private static let twoLineRowHeight: CGFloat = {
    let cell = SuggestionCellView()
    cell.primaryLabel.stringValue = "X"
    cell.secondaryLabel.stringValue = "X"
    // accessoryLabel is centerY-pinned and never taller than the
    // primary+secondary stack, so it doesn't affect fitting height.
    return ceil(cell.fittingSize.height)
  }()
  /// Single-line row: primary only (action palette, no URL). Computed
  /// directly from the primary label's font metrics because
  /// `fittingSize.height` on the full cell ignores `isHidden` — Auto
  /// Layout constraints stay active for hidden views, so the hidden
  /// secondary label's intrinsic height is still counted, producing
  /// the same value as `twoLineRowHeight`.
  private static let singleLineRowHeight: CGFloat = {
    let label = NSTextField(labelWithString: "X")
    label.font = SuggestionCellView.primaryFont
    return ceil(label.intrinsicContentSize.height) + 4
  }()
  private let maxVisibleRows = 8

  /// Called when the user selects an item; receives the row index into
  /// the `items` array last passed to `update(items:)`. Callers map this
  /// index back to their own domain object (a `Suggestion`, `Action`,
  /// etc.) to enact the selection.
  public var onSelectIndex: ((Int) -> Void)?

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
    tableView.rowHeight = Self.twoLineRowHeight
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

  // MARK: - Row Height

  /// Whether the current batch of items uses single-line or two-line
  /// cells. In practice, action mode items all have empty secondary
  /// and URL mode items all have non-empty secondary, so a per-batch
  /// flag (rather than per-row) keeps the height uniform and avoids
  /// jarring mixed-height rows.
  private var useSingleLineHeight = false

  /// The row height for the current batch.
  private var effectiveRowHeight: CGFloat {
    useSingleLineHeight ? Self.singleLineRowHeight : Self.twoLineRowHeight
  }

  /// Cached content height set in `update(items:)`. Used by the direct
  /// `frame.size.height` assignment for frame-based hosts (`PaneURLBar`,
  /// `CommandPaletteView`). Also exposed via `intrinsicContentSize` in
  /// case a future host uses Auto Layout to embed this view.
  private var contentHeight: CGFloat = 0

  public override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
  }

  // MARK: - Public API

  /// Update the list contents and resize. An empty array hides the view.
  public func update(items: [SuggestionCellModel]) {
    self.items = items
    useSingleLineHeight = items.allSatisfy { $0.secondary.isEmpty }
    tableView.rowHeight = effectiveRowHeight
    tableView.reloadData()

    if items.isEmpty {
      isHidden = true
      contentHeight = 0
      invalidateIntrinsicContentSize()
      return
    }

    isHidden = false
    let visibleRows = min(items.count, maxVisibleRows)
    // Only expose a scroller when content actually overflows the visible
    // window. With N <= maxVisibleRows every row is already on screen so
    // the scroller serves no purpose — and autohide can't be fully
    // trusted across system settings and layout timing.
    scrollView.hasVerticalScroller = items.count > maxVisibleRows
    // Height = (rowHeight * visible rows) + 12pt of outer inset (6pt top
    // + 6pt bottom, matching the scrollView's leading/trailing pin). The
    // scrollView itself is sized at rowHeight * N so its clipView matches
    // the documentView exactly — no bogus scrollbar — while the extra
    // 12pt becomes visible breathing room on the SuggestionListView
    // background layer.
    contentHeight = CGFloat(visibleRows) * effectiveRowHeight + 12
    frame.size.height = contentHeight
    // Notify Auto Layout hosts (CommandPaletteView) that our preferred
    // height changed. Frame-based hosts (PaneURLBar) ignore this.
    invalidateIntrinsicContentSize()
    // Setting .frame directly doesn't propagate through Auto Layout to
    // our pinned scrollView. If the previous update filled 8 rows and
    // this one has 1, scrollView stays at the old height, clipping the
    // new cell. Force the layout pass synchronously.
    needsLayout = true
    layoutSubtreeIfNeeded()

    // Auto-select first row. Non-empty is guaranteed by the early
    // return above (`items.isEmpty → isHidden = true; return`).
    tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
  }

  /// Move selection up.
  public func selectPrevious() {
    guard !items.isEmpty else { return }
    let current = tableView.selectedRow
    let next = current > 0 ? current - 1 : items.count - 1
    tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
    tableView.scrollRowToVisible(next)
  }

  /// Move selection down.
  public func selectNext() {
    guard !items.isEmpty else { return }
    let current = tableView.selectedRow
    let next = current < items.count - 1 ? current + 1 : 0
    tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
    tableView.scrollRowToVisible(next)
  }

  /// Row index of the currently selected item, or `nil` when nothing is
  /// selected (empty list or selection cleared by AppKit).
  public var selectedIndex: Int? {
    let row = tableView.selectedRow
    return items.indices.contains(row) ? row : nil
  }

  /// Hide the suggestion list.
  public func dismiss() {
    items = []
    tableView.reloadData()
    isHidden = true
  }

  // MARK: - Hover Tracking

  private var trackingArea: NSTrackingArea?

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .cursorUpdate],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  public override func cursorUpdate(with event: NSEvent) {
    // Override background elements' cursor — show arrow over the list.
    NSCursor.arrow.set()
  }

  public override func mouseMoved(with event: NSEvent) {
    let point = tableView.convert(event.locationInWindow, from: nil)
    let row = tableView.row(at: point)
    if row >= 0, row != tableView.selectedRow {
      tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
  }

  public override func mouseExited(with event: NSEvent) {
    // Restore selection to first row when mouse leaves the list.
    if !items.isEmpty {
      tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
  }

  // MARK: - Actions

  @objc private func handleClick() {
    guard let index = selectedIndex else { return }
    onSelectIndex?(index)
  }
}

// MARK: - NSTableViewDataSource

extension SuggestionListView: NSTableViewDataSource {
  public func numberOfRows(in _: NSTableView) -> Int {
    items.count
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
  let iconView = NSImageView()
  let primaryLabel = NSTextField(labelWithString: "")
  let secondaryLabel = NSTextField(labelWithString: "")
  let accessoryLabel = NSTextField(labelWithString: "")

  /// Leading edge of the text stack. Points at the iconView trailing
  /// anchor when the model carries an icon, or flush at 8pt from the
  /// cell's leading edge when the slot is empty. Toggled in `apply`
  /// so action rows without icons don't leave a 22pt gap.
  private var textLeadingToIcon: NSLayoutConstraint!
  private var textLeadingFlush: NSLayoutConstraint!

  /// Width of the icon slot. Collapses to 0 for icon-less rows so
  /// the text stack reclaims the horizontal space.
  private var iconWidth: NSLayoutConstraint!

  static let iconSize: CGFloat = 16

  // Flipped (top-down) coordinates match the enclosing NSTableView/
  // NSTableRowView so topAnchor/bottomAnchor constraints map to their
  // visual meanings without mental gymnastics.
  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    configure()
  }

  static let primaryFont: NSFont = .systemFont(ofSize: 12)

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  func apply(_ model: SuggestionCellModel) {
    primaryLabel.stringValue = model.primary
    secondaryLabel.stringValue = model.secondary
    secondaryLabel.isHidden = model.secondary.isEmpty
    if let accessory = model.accessory {
      accessoryLabel.stringValue = accessory
      accessoryLabel.isHidden = false
    } else {
      accessoryLabel.stringValue = ""
      accessoryLabel.isHidden = true
    }
    if let image = model.leadingImage {
      iconView.image = image
      iconView.isHidden = false
      iconWidth.constant = Self.iconSize
      textLeadingFlush.isActive = false
      textLeadingToIcon.isActive = true
    } else {
      iconView.image = nil
      iconView.isHidden = true
      iconWidth.constant = 0
      textLeadingToIcon.isActive = false
      textLeadingFlush.isActive = true
    }
  }

  private func configure() {
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.imageFrameStyle = .none
    iconView.translatesAutoresizingMaskIntoConstraints = false

    primaryLabel.font = Self.primaryFont
    primaryLabel.textColor = .white
    primaryLabel.lineBreakMode = .byTruncatingTail
    primaryLabel.translatesAutoresizingMaskIntoConstraints = false

    secondaryLabel.font = .systemFont(ofSize: 11)
    secondaryLabel.textColor = NSColor(white: 0.75, alpha: 1.0)
    secondaryLabel.lineBreakMode = .byTruncatingTail
    secondaryLabel.translatesAutoresizingMaskIntoConstraints = false

    // Accessory sits at the trailing edge and is used for keyboard
    // shortcut hints in the coming command-palette mode. Kept dim and
    // shorter than the primary text so it reads as metadata.
    accessoryLabel.font = .systemFont(ofSize: 11)
    accessoryLabel.textColor = NSColor(white: 0.6, alpha: 1.0)
    accessoryLabel.alignment = .right
    accessoryLabel.lineBreakMode = .byTruncatingTail
    accessoryLabel.translatesAutoresizingMaskIntoConstraints = false
    accessoryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    // Let the accessory keep its intrinsic width; primary/secondary
    // compress first when the row is too narrow.
    accessoryLabel.setContentHuggingPriority(.required, for: .horizontal)

    addSubview(iconView)
    addSubview(primaryLabel)
    addSubview(secondaryLabel)
    addSubview(accessoryLabel)

    iconWidth = iconView.widthAnchor.constraint(equalToConstant: Self.iconSize)
    textLeadingToIcon = primaryLabel.leadingAnchor.constraint(
      equalTo: iconView.trailingAnchor, constant: 6)
    textLeadingFlush = primaryLabel.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: 8)
    textLeadingToIcon.isActive = true

    // Flush layout: title pinned to the cell top, secondary pinned 2pt
    // below. No top/bottom padding — padding here would make the single-
    // hit dropdown taller than its content and surface a bogus scrollbar.
    // The bottom constraint is `lessThanOrEqual` so that font metric
    // variance can't force the cell to stretch past rowHeight. Accessory
    // is vertically centred and aligned to the trailing edge; primary/
    // secondary trailing constraints target the accessory's leading
    // anchor with an 8pt gap so long titles don't collide with shortcuts.
    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconWidth,
      iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

      primaryLabel.topAnchor.constraint(equalTo: topAnchor),
      primaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: accessoryLabel.leadingAnchor, constant: -8),

      secondaryLabel.leadingAnchor.constraint(equalTo: primaryLabel.leadingAnchor),
      secondaryLabel.topAnchor.constraint(equalTo: primaryLabel.bottomAnchor, constant: 2),
      secondaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
      secondaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: accessoryLabel.leadingAnchor, constant: -8),

      accessoryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      accessoryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
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
    guard items.indices.contains(row) else { return nil }

    let cellID = NSUserInterfaceItemIdentifier("SuggestionCell")
    let cell: SuggestionCellView
    if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? SuggestionCellView {
      cell = reused
    } else {
      cell = SuggestionCellView()
      cell.identifier = cellID
    }

    cell.apply(items[row])
    return cell
  }
}
