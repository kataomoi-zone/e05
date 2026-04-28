import AppKit

/// Extensions list rendered inside the sidebar's `extensions` mode.
/// Subscribes to `ExtensionController.didChangeNotification` so loads
/// completing after the sidebar has appeared (the controller scans
/// asynchronously at app launch) reach the list without an explicit
/// reload call.
///
/// Sized to match the other list-based modes (Bookmarks / History /
/// Downloads): transparent background, 48pt rows showing the
/// extension's action icon plus a two-line label (display name and
/// version), with a trailing `NSSwitch` for enable/disable. Richer
/// per-row actions (Reload, Open Options Page, View Errors) are
/// intentionally absent — the toggle is the only interactive
/// affordance the cell exposes.
@MainActor
final class ExtensionsSidebarView: NSView {
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let emptyLabel = NSTextField(labelWithString: "")
  private var rows: [LoadedExtension] = []
  nonisolated(unsafe) private var changeObserver: NSObjectProtocol?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    setupLayout()
    reload()
    changeObserver = NotificationCenter.default.addObserver(
      forName: ExtensionController.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reload() }
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  deinit {
    // Block-based observers keep their closure retained inside
    // NotificationCenter until the token is passed to
    // `removeObserver`, so a `[weak self]` capture alone does not
    // free the subscription. Same idiom as the other sidebar list
    // views.
    if let token = changeObserver {
      NotificationCenter.default.removeObserver(token)
    }
  }

  private func setupLayout() {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("extension"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.backgroundColor = .clear
    tableView.rowHeight = ExtensionsSidebarCellView.height
    tableView.intercellSpacing = NSSize(width: 0, height: 1)
    tableView.selectionHighlightStyle = .regular
    tableView.allowsMultipleSelection = false
    tableView.style = .plain
    tableView.dataSource = self
    tableView.delegate = self
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scrollView)

    // Two-line empty state mirroring the placeholder feel of other
    // sidebar modes. The path hint surfaces the convention so users
    // know where to drop an unpacked extension on first run.
    emptyLabel.font = .systemFont(ofSize: 12)
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.drawsBackground = false
    emptyLabel.isHidden = true
    emptyLabel.alignment = .center
    emptyLabel.maximumNumberOfLines = 0
    emptyLabel.lineBreakMode = .byWordWrapping
    emptyLabel.stringValue =
      "No extensions loaded.\n"
      + "Drop an unpacked extension into\n"
      + "~/.config/e05/extensions/"
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(emptyLabel)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      emptyLabel.leadingAnchor.constraint(
        greaterThanOrEqualTo: leadingAnchor, constant: 12),
      emptyLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingAnchor, constant: -12),
    ])
  }

  private func reload() {
    rows = ExtensionController.shared.loadedExtensions
    tableView.reloadData()
    emptyLabel.isHidden = !rows.isEmpty
  }
}

// MARK: - NSTableViewDataSource

extension ExtensionsSidebarView: NSTableViewDataSource {
  func numberOfRows(in _: NSTableView) -> Int { rows.count }
}

// MARK: - NSTableViewDelegate

extension ExtensionsSidebarView: NSTableViewDelegate {
  func tableView(
    _ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int
  ) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("ExtensionsSidebarCell")
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: self)
      as? ExtensionsSidebarCellView ?? ExtensionsSidebarCellView(identifier: identifier)
    cell.configure(with: rows[row])
    cell.onToggleEnabled = { sourceURL, enabled in
      ExtensionController.shared.setEnabled(enabled, for: sourceURL)
    }
    return cell
  }

  func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
    SidebarListRowView()
  }
}

// MARK: - Cell

/// Compact two-line cell: extension display name on top (label color)
/// and version (or manifest version when version is missing) on the
/// bottom (secondary). The icon slot is 32pt to match the sidebar's
/// extension-detail aesthetic (action icons are typically rendered at
/// 32×32 in MV3 manifests). Transparent background so the Liquid
/// Glass sidebar shows through.
private final class ExtensionsSidebarCellView: SidebarListCellView {
  static let height: CGFloat = 48
  static let iconSize: CGFloat = 32

  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let subtitleLabel = NSTextField(labelWithString: "")
  private let toggle = NSSwitch()
  private var currentSourceURL: URL?

  /// Fired when the user flips the trailing switch. The parent list
  /// view forwards the request to `ExtensionController.setEnabled`,
  /// which posts `didChangeNotification` on completion so this cell's
  /// next `configure` reflects the persisted state.
  var onToggleEnabled: ((URL, Bool) -> Void)?

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

    // Compact switch keeps the trailing edge from crowding the title
    // on the 260pt sidebar and matches the visual weight of the
    // ellipsis buttons in other cell types.
    toggle.controlSize = .small
    toggle.translatesAutoresizingMaskIntoConstraints = false
    toggle.target = self
    toggle.action = #selector(toggleChanged)

    addSubview(iconView)
    addSubview(titleLabel)
    addSubview(subtitleLabel)
    addSubview(toggle)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
      titleLabel.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -8),

      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

      toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
      toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
    ])
  }

  @objc private func toggleChanged() {
    guard let sourceURL = currentSourceURL else { return }
    onToggleEnabled?(sourceURL, toggle.state == .on)
  }

  func configure(with entry: LoadedExtension) {
    currentSourceURL = entry.sourceURL
    titleLabel.stringValue = entry.displayName
    if let version = entry.version, !version.isEmpty {
      subtitleLabel.stringValue = "v\(version)"
    } else {
      // Manifest version is typed as `Double` in the WKWebExtension
      // surface; render with `%g` so MV3 reads as "MV3" instead of
      // "MV3.0" when the manifest declared the integer literal.
      let mv = String(format: "%g", entry.manifestVersion)
      subtitleLabel.stringValue = "MV\(mv)"
    }
    iconView.image = entry.icon
      ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
    // Dim the metadata in the disabled state so the row reads as
    // inert at a glance, matching how Safari and Chrome dim disabled
    // extensions in their management UIs.
    let alpha: CGFloat = entry.isEnabled ? 1.0 : 0.45
    iconView.alphaValue = alpha
    titleLabel.alphaValue = alpha
    subtitleLabel.alphaValue = alpha
    toggle.state = entry.isEnabled ? .on : .off
    toolTip = entry.displayName
  }
}
