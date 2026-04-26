import AppKit

/// Downloads list rendered inside the sidebar's `downloads` mode.
/// Subscribes to the shared `DownloadsManager` so mutations (new
/// transfers, pause / resume / cancel, removals from other entry
/// points) reflect live without a manual reload.
///
/// Mirrors `HistorySidebarView`'s compact 260pt-friendly layout with
/// downloads-specific extensions:
/// - the status line carries percent + byte counts for in-flight rows
/// - a 2pt accent-coloured overlay hugs the cell's bottom edge for
///   `.downloading` / `.paused` rows with known total bytes, giving a
///   low-noise progress indicator that doesn't push row height up
/// - the trailing slot surfaces state-dependent actions directly
///   (no ellipsis menu): active rows expose pause/resume + copy URL
///   + cancel, completed rows expose reveal + copy URL + remove,
///   terminal-failure rows expose copy URL + remove. Keeping the
///   primary transport controls (pause, resume, cancel) as single
///   clicks matches the user's expectation that mid-transfer decisions
///   are quick; Copy URL is promoted to a first-class button so it
///   stays one click too even though it's less frequent.
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
  /// Fired when a row is removed from the list. Only valid for
  /// terminal states (.completed / .failed / .cancelled) — in-flight
  /// rows route their trailing × through `onCancel` instead, matching
  /// the invariant "active downloads can't be removed without first
  /// being cancelled".
  var onRemove: ((Int64) -> Void)?
  /// Fired when reveal-in-Finder is requested on a completed row.
  /// The payload is the destination file path; empty paths are
  /// filtered by the sidebar controller before reaching Finder.
  var onShowInFinder: ((String) -> Void)?
  /// Fired when Copy URL is requested on any row. The payload is
  /// the download's id; the parent view controller looks up the
  /// live URL so a racing store mutation can't copy a stale string.
  var onCopyURL: ((Int64) -> Void)?

  private let manager: DownloadsManager
  private var listenerToken: DownloadsListenerToken?
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let emptyLabel = NSTextField(labelWithString: "No downloads")
  private var rows: [Download] = []
  nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?

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

  deinit {
    // Block-based observers keep their closure retained inside
    // NotificationCenter until the token is passed to
    // `removeObserver`, so a `[weak self]` capture alone does not
    // free the subscription. The `DownloadsManager` listener is
    // left registered intentionally: the store is process-lifetime
    // and the closure weak-captures self, so post-dealloc
    // invocations are no-ops.
    if let token = scrollObserver {
      NotificationCenter.default.removeObserver(token)
    }
  }

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
    let newRows = manager.all()
    // Fast path: the manager fires listeners for *every* progress
    // tick, not just membership changes. If the row identity list
    // is unchanged we skip `reloadData` (which would re-run
    // `viewFor` and `updateTrackingAreas` on every visible cell,
    // flapping `isHovered` and making the hover-revealed buttons
    // blink faster than they can be clicked) and push updates
    // directly into the existing cells. Each cell's own
    // `configure` already skips button rebuilds when its (id,
    // state) hasn't changed, so the whole progress-tick path only
    // mutates the subtitle text and the progress overlay width —
    // no hit-test churn.
    let identitiesMatch =
      rows.count == newRows.count
      && zip(rows, newRows).allSatisfy { $0.id == $1.id }

    // Update the backing array *before* any table mutation so
    // `numberOfRows(in:)` (which reads `rows.count`) matches the
    // shape we're asking the table to render. Deferring this until
    // after `reloadData()` would make the table ask for the old
    // count and miss the newly inserted row, leaving fresh
    // downloads invisible until the next listener fire.
    rows = newRows
    emptyLabel.isHidden = !newRows.isEmpty

    guard identitiesMatch else {
      tableView.reloadData()
      return
    }
    for (index, entry) in newRows.enumerated() {
      let cell =
        tableView.view(
          atColumn: 0, row: index, makeIfNecessary: false
        ) as? DownloadsSidebarCellView
      cell?.configure(with: entry)
    }
  }

  private func hideAllActionButtons() {
    tableView.enumerateAvailableRowViews { _, row in
      (self.tableView.view(
        atColumn: 0, row: row, makeIfNecessary: false
      ) as? SidebarListCellView)?.forceHideHoverActions()
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
    let cell =
      tv.makeView(withIdentifier: identifier, owner: self)
      as? DownloadsSidebarCellView
      ?? DownloadsSidebarCellView(identifier: identifier)
    cell.onCancel = { [weak self] id in self?.onCancel?(id) }
    cell.onPause = { [weak self] id in self?.onPause?(id) }
    cell.onResume = { [weak self] id in self?.onResume?(id) }
    cell.onRemove = { [weak self] id in self?.onRemove?(id) }
    cell.onShowInFinder = { [weak self] path in self?.onShowInFinder?(path) }
    cell.onCopyURL = { [weak self] id in self?.onCopyURL?(id) }
    cell.configure(with: rows[row])
    return cell
  }

  func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
    SidebarListRowView()
  }
}

// MARK: - Cell view

private final class DownloadsSidebarCellView: SidebarListCellView {
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
  var onCopyURL: ((Int64) -> Void)?

  private let titleLabel = NSTextField(labelWithString: "")
  private let subtitleLabel = NSTextField(labelWithString: "")
  private let actionsStack = NSStackView()
  private let progressOverlay = NSView()
  private var progressOverlayWidth: NSLayoutConstraint?

  private var lastFraction: Double = 0
  private var lastState: DownloadState?
  private var lastConfiguredID: Int64?
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
    progressOverlay.layer?.backgroundColor =
      NSColor.controlAccentColor
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
      // `lessThanOrEqualTo` so the stack settles at its intrinsic
      // width (3 buttons × 18pt + spacing) anchored flush to the
      // trailing edge. With `equalTo` the stack would stretch to
      // fill the remaining horizontal space and the buttons would
      // gravitate to its leading edge, leaving dead space before
      // the row's right margin.
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: actionsStack.leadingAnchor, constant: -6
      ),

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
      abs(constraint.constant - target) > 0.5
    {
      constraint.constant = target
    }
  }

  override func setHoverActionsHidden(_ hidden: Bool) {
    actionsStack.arrangedSubviews.forEach { $0.isHidden = hidden }
  }

  func configure(with entry: Download) {
    currentID = entry.id
    currentDestination = entry.destination
    titleLabel.stringValue = entry.filename.isEmpty ? entry.url : entry.filename
    subtitleLabel.stringValue = Self.statusLine(for: entry)
    // Tooltips surface full text when the compact 260pt sidebar
    // truncates either label. Title tooltip carries the source URL
    // as a secondary line so a hover reveals where the download
    // came from even if the filename alone isn't distinctive. When
    // there's no filename the main label already renders the URL,
    // so a tooltip with the same string adds no information — leave
    // it nil and let subtitleLabel remain the full-URL entry point.
    titleLabel.toolTip =
      entry.filename.isEmpty
      ? nil
      : "\(entry.filename)\n\(entry.url)"
    // For downloads the subtitle-level detail worth revealing is
    // the on-disk destination (if we have one) — otherwise the URL.
    subtitleLabel.toolTip = entry.destination.isEmpty ? entry.url : entry.destination

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
    let showProgress =
      (entry.state == .downloading || entry.state == .paused)
      && entry.totalBytes > 0
    progressIsVisible = showProgress
    progressOverlay.isHidden = !showProgress

    // Only rebuild the trailing button stack when the identity or
    // state actually changed. Progress ticks on a `.downloading`
    // row fire `fireListeners()` every time the bytes written
    // advance, which re-enters `configure`. Rebuilding the stack
    // removes the hover-revealed buttons from the tracking area
    // mid-aim, so a user hovering over Cancel sees the button
    // disappear and reappear several times a second — effectively
    // un-clickable. Skipping the rebuild keeps the same button
    // instances under the cursor so hover state sticks.
    let stateChanged = lastState != entry.state
    let idChanged = lastConfiguredID != entry.id
    if stateChanged || idChanged {
      rebuildActionButtons(for: entry.state)
      lastState = entry.state
      lastConfiguredID = entry.id
    }
    needsLayout = true
  }

  private func rebuildActionButtons(for state: DownloadState) {
    actionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

    // Leading primary action: transport control for active rows,
    // reveal-in-Finder for completed rows, absent for terminal
    // failure states (nothing primary to do there — the user
    // either copies the URL to retry manually or removes the row).
    switch state {
    case .downloading:
      actionsStack.addArrangedSubview(
        makeButton(
          symbol: "pause.circle", tooltip: "Pause",
          action: #selector(handlePauseTapped)
        ))
    case .paused:
      actionsStack.addArrangedSubview(
        makeButton(
          symbol: "play.circle", tooltip: "Resume",
          action: #selector(handleResumeTapped)
        ))
    case .completed:
      actionsStack.addArrangedSubview(
        makeButton(
          symbol: "folder", tooltip: "Show in Finder",
          action: #selector(handleShowInFinderTapped)
        ))
    case .failed, .cancelled:
      break
    }

    // Copy URL lives next to the primary because users reach for
    // it frequently enough to deserve a single click, but not so
    // frequently that it should eclipse the state-specific primary.
    actionsStack.addArrangedSubview(
      makeButton(
        symbol: "link", tooltip: "Copy URL",
        action: #selector(handleCopyURLTapped)
      ))

    // Trailing slot: cancel while the transfer is still live,
    // remove once it has terminated. The invariant is "you can't
    // remove an active download without cancelling it first" —
    // routing downloading/paused through `onCancel` enforces that
    // at the UI layer and keeps the manager's state machine from
    // having to guard callers.
    switch state {
    case .downloading, .paused:
      actionsStack.addArrangedSubview(
        makeButton(
          symbol: "xmark", tooltip: "Cancel",
          action: #selector(handleCancelTapped)
        ))
    case .completed, .failed, .cancelled:
      actionsStack.addArrangedSubview(
        makeButton(
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
  @objc private func handleCopyURLTapped() { onCopyURL?(currentID) }

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
