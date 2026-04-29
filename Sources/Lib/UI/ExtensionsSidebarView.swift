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
/// version), with a trailing `NSSwitch` for enable/disable and a
/// hover-revealed ellipsis menu (`Move to Trash`). Richer per-row
/// actions (Reload, Open Options Page, View Errors) are intentionally
/// absent.
@MainActor
final class ExtensionsSidebarView: NSView {
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let emptyLabel = NSTextField(labelWithString: "")
  private let addButton = NSButton()
  private var rows: [LoadedExtension] = []
  nonisolated(unsafe) private var changeObserver: NSObjectProtocol?
  nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?

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
    if let token = scrollObserver {
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

    // Hover-revealed ellipsis menus rely on `.inVisibleRect` tracking
    // areas, which don't deliver `mouseExited` when a hovered cell
    // scrolls out from under a stationary cursor. Watch the clip
    // view's bounds so we can force-hide every cell's hover affordance
    // whenever the list scrolls — same pattern used by Bookmarks /
    // History / Downloads.
    scrollView.contentView.postsBoundsChangedNotifications = true
    scrollObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: scrollView.contentView,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.hideAllActionButtons() }
    }

    // Compact recessed button matches the visual weight of inline
    // controls used elsewhere in the sidebar (download trailing
    // buttons, find-bar buttons). `imagePosition = .imageLeading`
    // pairs the SF Symbol with the title.
    addButton.title = "Add Extension"
    addButton.image = NSImage(
      systemSymbolName: "plus", accessibilityDescription: "Add Extension"
    )
    addButton.imagePosition = .imageLeading
    addButton.bezelStyle = .recessed
    addButton.font = .systemFont(ofSize: 11, weight: .medium)
    addButton.target = self
    addButton.action = #selector(addClicked)
    addButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(addButton)

    // Two-line empty state mirroring the placeholder feel of other
    // sidebar modes. The path hint surfaces the convention so users
    // know where the picker copies the chosen folder to.
    emptyLabel.font = .systemFont(ofSize: 12)
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.drawsBackground = false
    emptyLabel.isHidden = true
    emptyLabel.alignment = .center
    emptyLabel.maximumNumberOfLines = 0
    emptyLabel.lineBreakMode = .byWordWrapping
    emptyLabel.stringValue =
      "No extensions loaded.\n"
      + "Use “Add Extension” above or drop an\n"
      + "unpacked extension into\n"
      + "~/.config/e05/extensions/"
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(emptyLabel)

    NSLayoutConstraint.activate([
      addButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      addButton.heightAnchor.constraint(equalToConstant: 22),

      scrollView.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 6),
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

  /// View's own window first, then keyWindow / mainWindow as a
  /// fallback. Sidebar views attach to a window during the same
  /// runloop tick they're inserted, but a sheet click landing in
  /// that gap, or during a transient detach, would otherwise drop
  /// the open panel silently. The fallback windows are still owned
  /// by the same NSApp so sheet semantics behave identically.
  private var hostWindow: NSWindow? {
    window ?? NSApp.keyWindow ?? NSApp.mainWindow
  }

  @objc private func addClicked() {
    guard let host = hostWindow else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Choose an unpacked extension folder."
    panel.prompt = "Add"
    panel.beginSheetModal(for: host) { [weak self] response in
      guard response == .OK, let chosen = panel.urls.first else { return }
      Task { @MainActor in
        do {
          try await ExtensionController.shared.addExtension(from: chosen)
        } catch {
          self?.presentAddError(error)
        }
      }
    }
  }

  private func presentAddError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "Could not add extension"
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    if let host = hostWindow {
      alert.beginSheetModal(for: host, completionHandler: nil)
    } else {
      // Window-less fallback — running modal still surfaces the
      // failure rather than silently swallowing it.
      alert.runModal()
    }
  }

  private func reload() {
    rows = ExtensionController.shared.loadedExtensions
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
    cell.onRemove = { sourceURL in
      ExtensionController.shared.removeExtension(for: sourceURL)
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
  private let menuButton = HoverIconButton()
  private var currentSourceURL: URL?

  /// Fired when the user flips the trailing switch. The parent list
  /// view forwards the request to `ExtensionController.setEnabled`,
  /// which posts `didChangeNotification` on completion so this cell's
  /// next `configure` reflects the persisted state.
  var onToggleEnabled: ((URL, Bool) -> Void)?

  /// Fired when the user picks `Move to Trash` from the row's
  /// hover-revealed menu. The parent list view delegates to
  /// `ExtensionController.removeExtension`.
  var onRemove: ((URL) -> Void)?

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

    menuButton.image = NSImage(
      systemSymbolName: "ellipsis", accessibilityDescription: "More actions"
    )
    menuButton.imagePosition = .imageOnly
    menuButton.isBordered = false
    menuButton.bezelStyle = .regularSquare
    menuButton.translatesAutoresizingMaskIntoConstraints = false
    menuButton.target = self
    menuButton.action = #selector(menuTapped)
    menuButton.toolTip = "More actions"
    menuButton.isHidden = true

    addSubview(iconView)
    addSubview(titleLabel)
    addSubview(subtitleLabel)
    addSubview(menuButton)
    addSubview(toggle)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
      titleLabel.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -6),

      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

      menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      menuButton.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -4),
      menuButton.widthAnchor.constraint(equalToConstant: 18),
      menuButton.heightAnchor.constraint(equalToConstant: 18),

      toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
      toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
    ])
  }

  override func setHoverActionsHidden(_ hidden: Bool) {
    menuButton.isHidden = hidden
  }

  @objc private func menuTapped() {
    guard let sourceURL = currentSourceURL else { return }
    let menu = NSMenu()
    let removeItem = NSMenuItem(
      title: "Move to Trash", action: #selector(menuRemove(_:)), keyEquivalent: ""
    )
    removeItem.target = self
    removeItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
    // Bind the URL to the menu item rather than reading
    // `currentSourceURL` at fire time. The menu pop-up runs a nested
    // runloop, and a `didChangeNotification` arriving during it would
    // trigger `tableView.reloadData()` and overwrite this cell's
    // `currentSourceURL` with another row's URL — picking the wrong
    // extension to trash. The captured value here is immutable.
    removeItem.representedObject = sourceURL
    menu.addItem(removeItem)
    // Anchor flush to the menu button's bottom-left so the first item
    // sits directly under the glyph (same idiom as Bookmarks).
    let origin = NSPoint(x: 0, y: menuButton.bounds.height)
    menu.popUp(positioning: nil, at: origin, in: menuButton)
  }

  @objc private func menuRemove(_ sender: NSMenuItem) {
    guard let sourceURL = sender.representedObject as? URL else { return }
    onRemove?(sourceURL)
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
