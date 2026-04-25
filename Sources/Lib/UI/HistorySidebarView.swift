import AppKit

/// Browsing history list rendered inside the sidebar's `history` mode.
/// Subscribes to the shared `BrowsingHistory` store so external
/// mutations (new page visits from any browser pane, URL bar
/// recordings, deletions triggered elsewhere) reflect live without a
/// manual reload.
///
/// Mirrors `BookmarksSidebarView`'s compact 260pt-friendly layout:
/// transparent background (Liquid Glass stays visible through the
/// row), no header (the mode name is already in the places section),
/// 40pt rows with title + "host · relative time", and a
/// hover-revealed delete button. A flat list is intentional: future
/// date-header grouping converges with bookmarks folder headers and
/// is planned as a single later pass (see sidebar-design future
/// requests), not as a history-only divergence now.
@MainActor
final class HistorySidebarView: NSView {
  /// Fired on single click. UX policy: always open in a new browser
  /// column in the current workspace.
  var onOpen: ((String) -> Void)?

  /// Fired on Cmd+click. UX policy: always open in a newly created
  /// workspace. The container is responsible for the
  /// `createWorkspace()` + `addColumn` orchestration.
  var onOpenInNewWorkspace: ((String) -> Void)?

  private let history: BrowsingHistory
  private var listenerToken: BrowsingHistoryListenerToken?
  private let scrollView = NSScrollView()
  private let tableView = SidebarListTableView()
  private let emptyLabel = NSTextField(labelWithString: "No history yet")
  private var rows: [BrowsingHistory.Entry] = []
  nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?
  nonisolated(unsafe) private var faviconObserver: NSObjectProtocol?

  /// Cap on rows loaded into the sidebar list. 500 entries is
  /// comfortable for a flat scroll list; a planned search field
  /// will handle deeper lookups.
  private static let rowLimit = 500

  init(history: BrowsingHistory) {
    self.history = history
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    setupLayout()
    reload()
    listenerToken = history.addListener { [weak self] in self?.reload() }
    // Re-render every cell when a favicon fetch settles so rows
    // showing the `globe` placeholder for the newly-cached host
    // upgrade in place. Row count is capped at `rowLimit` so a
    // single reloadData stays inexpensive.
    faviconObserver = NotificationCenter.default.addObserver(
      forName: FaviconCache.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.tableView.reloadData() }
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  deinit {
    // Block-based observers keep their closure retained inside
    // NotificationCenter until the token is passed to
    // `removeObserver`, so a `[weak self]` capture alone does not
    // free the subscription. The `BrowsingHistory` listener is left
    // registered intentionally: the store is process-lifetime and
    // the closure weak-captures self, so post-dealloc invocations
    // are no-ops.
    if let token = scrollObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = faviconObserver {
      NotificationCenter.default.removeObserver(token)
    }
  }

  private func setupLayout() {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.backgroundColor = .clear
    tableView.rowHeight = HistorySidebarCellView.height
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
    rows = history.mostRecent(limit: Self.rowLimit)
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
    // `reload()`, which keeps the row removal and selection
    // restoration consistent regardless of which entry point
    // (this list's × button, the URL bar, command palette, …)
    // triggered the delete.
    history.delete(id: entry.id)
  }
}

// MARK: - NSTableViewDataSource

extension HistorySidebarView: NSTableViewDataSource {
  func numberOfRows(in _: NSTableView) -> Int { rows.count }
}

// MARK: - NSTableViewDelegate

extension HistorySidebarView: NSTableViewDelegate {
  func tableView(
    _ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int
  ) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("HistorySidebarCell")
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: self)
      as? HistorySidebarCellView ?? HistorySidebarCellView(identifier: identifier)
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

extension HistorySidebarView {
  fileprivate func handleRowAction(id: Int64, action: HistoryRowAction) {
    guard let entry = rows.first(where: { $0.id == id }) else { return }
    switch action {
    case .delete:
      history.delete(id: entry.id)
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
}

// MARK: - Cell actions

/// Per-row action surfaced via the trailing ellipsis menu. Single
/// callback + enum keeps the parent view as the single owner of
/// mutation / pasteboard side effects.
///
/// Same-site filtering ("history of this host") will land alongside
/// the history search UI, so it's intentionally absent here.
enum HistoryRowAction {
  case delete
  case copyURL
  case openInCurrentWorkspace
  case openInNewWorkspace
}

// MARK: - Cell

/// Compact two-line cell: page title on top (label color) and
/// "relative_time · host" on the bottom (secondary). Hovering
/// reveals a trailing ellipsis (…) button that opens a small action
/// menu (Copy URL / Delete). Transparent background so the Liquid
/// Glass sidebar remains visible through the row.
private final class HistorySidebarCellView: SidebarListCellView {
  static let height: CGFloat = 40

  /// Shared across all cells — `RelativeDateTimeFormatter` allocation
  /// is expensive enough that `HistoryDataSource` already memoises
  /// it; the sidebar follows suit so a fast scroll doesn't pay per
  /// cell reuse.
  private static let formatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
  }()

  static let iconSize: CGFloat = 16

  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let subtitleLabel = NSTextField(labelWithString: "")
  private let actionButton = HoverIconButton()
  private var currentID: Int64 = 0

  var onRowAction: ((Int64, HistoryRowAction) -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    setup()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setup() {
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.imageFrameStyle = .none
    iconView.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
    titleLabel.textColor = .labelColor
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.drawsBackground = false
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    subtitleLabel.font = .systemFont(ofSize: 10)
    subtitleLabel.textColor = .secondaryLabelColor
    subtitleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.drawsBackground = false
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

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

    addSubview(iconView)
    addSubview(titleLabel)
    addSubview(subtitleLabel)
    addSubview(actionButton)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
      titleLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -6),

      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

      actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      actionButton.widthAnchor.constraint(equalToConstant: 18),
      actionButton.heightAnchor.constraint(equalToConstant: 18),
    ])
  }

  override func setHoverActionsHidden(_ hidden: Bool) {
    actionButton.isHidden = hidden
  }

  func configure(with entry: BrowsingHistory.Entry) {
    currentID = entry.id
    titleLabel.stringValue = entry.title.isEmpty ? entry.url : entry.title
    // `host()` returns nil for atypical schemes; fall back to the
    // full URL so the row is still recognisable.
    let parsedHost = URL(string: entry.url)?.host(percentEncoded: false)
    let host = parsedHost ?? entry.url
    if let parsedHost, !parsedHost.isEmpty,
      let image = FaviconCache.shared.image(for: parsedHost)
    {
      iconView.image = image
    } else {
      iconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    }
    // Relative time first, host last: long hosts (e.g. deep
    // artefact URLs) would otherwise consume the line and push the
    // timestamp past the truncation boundary, hiding the "when"
    // signal users rely on when scanning history.
    subtitleLabel.stringValue = "\(Self.relativeDescription(for: entry.visitedAt)) · \(host)"
    // Tooltips surface full text when the compact 260pt sidebar
    // truncates either label. Title tooltip carries the URL as a
    // secondary line so a hover answers "which page was this?"
    // even when the title alone isn't distinctive. When the entry
    // has no title the main label already renders the URL, so a
    // tooltip with the same string adds no information — leave it
    // nil and let subtitleLabel remain the full-URL entry point.
    titleLabel.toolTip =
      entry.title.isEmpty
      ? nil
      : "\(entry.title)\n\(entry.url)"
    subtitleLabel.toolTip = entry.url
  }

  /// Relative-time wording that avoids `RelativeDateTimeFormatter`'s
  /// "0 秒後" / "in 0 seconds" quirk. The formatter picks future tense
  /// for sub-second deltas (the store's listener fires immediately
  /// after a visit, so the cell reloads while the interval is still
  /// effectively zero). Anything under five seconds reads as "just
  /// now"; five seconds and beyond hand back to the locale-aware
  /// formatter so "5 秒前"/"2 分前" etc. keep working.
  private static func relativeDescription(for date: Date) -> String {
    let elapsed = Date().timeIntervalSince(date)
    if elapsed < 5 { return "just now" }
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  @objc private func actionTapped() {
    let menu = NSMenu()

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

    let origin = NSPoint(x: 0, y: actionButton.bounds.height)
    menu.popUp(positioning: nil, at: origin, in: actionButton)
  }

  @objc private func menuCopyURL() { onRowAction?(currentID, .copyURL) }
  @objc private func menuDelete() { onRowAction?(currentID, .delete) }
  @objc private func menuOpenInCurrent() { onRowAction?(currentID, .openInCurrentWorkspace) }
  @objc private func menuOpenInNew() { onRowAction?(currentID, .openInNewWorkspace) }
}
