import AppKit
import os.log

private let extensionsCellLogger = Logger(
  subsystem: "com.kawarimidoll.e05", category: "ExtensionsSidebar"
)

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
/// hover-revealed ellipsis menu (`Reload`, `View Errors`, `Move to
/// Trash`). `Open Options Page` is deferred until
/// `WKWebExtensionTab` / `WKWebExtensionWindow` adoption gives us a
/// `webView` that can host `webkit-extension://` URLs.
@MainActor
final class ExtensionsSidebarView: NSView {
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let emptyLabel = NSTextField(labelWithString: "")
  private let addButton = NSButton()
  private let addMenuButton = NSButton()
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
    // Default action is the folder/zip picker — that path predates
    // store install and stays the lowest-friction option for users
    // pointing at an unpacked dev build. The dropdown to its right
    // surfaces the alternative install sources.
    addButton.action = #selector(addFromFolderClicked)
    addButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(addButton)

    // Split-button companion: chevron.down to the right of the main
    // Add Extension button opens a menu listing every install
    // source. Visually flush with the main button so the pair reads
    // as a single split control.
    addMenuButton.image = NSImage(
      systemSymbolName: "chevron.down", accessibilityDescription: "More install options"
    )
    addMenuButton.imagePosition = .imageOnly
    addMenuButton.bezelStyle = .recessed
    addMenuButton.target = self
    addMenuButton.action = #selector(addMenuClicked)
    addMenuButton.toolTip = "More install options"
    addMenuButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(addMenuButton)

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

      addMenuButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
      addMenuButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 2),
      addMenuButton.widthAnchor.constraint(equalToConstant: 22),
      addMenuButton.heightAnchor.constraint(equalToConstant: 22),

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

  @objc private func addFromFolderClicked() {
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

  @objc private func addMenuClicked() {
    let menu = NSMenu()
    menu.autoenablesItems = false

    let folderItem = NSMenuItem(
      title: "From Folder or ZIP…",
      action: #selector(addFromFolderClicked),
      keyEquivalent: ""
    )
    folderItem.target = self
    folderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    menu.addItem(folderItem)

    menu.addItem(.separator())

    let chromeItem = NSMenuItem(
      title: "From Chrome Web Store…",
      action: #selector(addFromChromeWebStoreClicked),
      keyEquivalent: ""
    )
    chromeItem.target = self
    chromeItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    menu.addItem(chromeItem)

    let amoItem = NSMenuItem(
      title: "From Mozilla Add-ons…",
      action: #selector(addFromAMOClicked),
      keyEquivalent: ""
    )
    amoItem.target = self
    amoItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    menu.addItem(amoItem)

    let origin = NSPoint(x: 0, y: addMenuButton.bounds.height)
    menu.popUp(positioning: nil, at: origin, in: addMenuButton)
  }

  @objc private func addFromChromeWebStoreClicked() {
    promptForStoreInstall(
      title: "Install from Chrome Web Store",
      placeholder: "https://chromewebstore.google.com/detail/<name>/<id>",
      parser: Self.parseChromeWebStoreID,
      install: { id in
        try await ExtensionController.shared.installFromChromeWebStore(extensionID: id)
      }
    )
  }

  @objc private func addFromAMOClicked() {
    promptForStoreInstall(
      title: "Install from Mozilla Add-ons",
      placeholder: "https://addons.mozilla.org/en-US/firefox/addon/<slug>/",
      parser: Self.parseAMOSlug,
      install: { slug in
        try await ExtensionController.shared.installFromAMO(slug: slug)
      }
    )
  }

  /// Shared sheet for store-sourced installs: a single text field
  /// accepts either a full listing URL or a bare ID/slug, the parser
  /// closure normalises the input, and the install closure performs
  /// the asynchronous fetch + load. Errors surface through
  /// `presentAddError`.
  private func promptForStoreInstall(
    title: String,
    placeholder: String,
    parser: @escaping (String) -> String?,
    install: @escaping (String) async throws -> Void
  ) {
    guard let host = hostWindow else { return }
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = "Paste the listing URL or extension ID."
    alert.addButton(withTitle: "Install")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(string: "")
    field.placeholderString = placeholder
    field.translatesAutoresizingMaskIntoConstraints = false
    // NSAlert sizes its accessoryView from a combination of the
    // initial frame and Auto Layout's fittingSize — seeding the
    // frame keeps the field from collapsing to a sliver before the
    // layout pass resolves the width constraint. Same lesson the
    // bookmarks edit sheet documents.
    field.frame = NSRect(x: 0, y: 0, width: 380, height: 22)
    NSLayoutConstraint.activate([
      field.widthAnchor.constraint(equalToConstant: 380)
    ])
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    alert.beginSheetModal(for: host) { [weak self] response in
      guard let self else { return }
      guard response == .alertFirstButtonReturn else { return }
      let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let id = parser(raw), !id.isEmpty else {
        self.presentRowAlert(
          title: "Invalid input",
          text: "Couldn't parse a store URL or extension ID from the input.",
          style: .warning
        )
        return
      }
      Task { @MainActor in
        do {
          try await install(id)
        } catch {
          self.presentAddError(error)
        }
      }
    }
  }

  private func presentAddError(_ error: Error) {
    presentRowAlert(
      title: "Could not add extension",
      text: error.localizedDescription,
      style: .warning
    )
  }

  /// Pull a 32-character Chrome Web Store ID out of `input`. Accepts:
  /// - the bare ID (32 chars from the `[a-p]` alphabet Google uses)
  /// - any Web Store URL (`chromewebstore.google.com/detail/...`,
  ///   the legacy `chrome.google.com/webstore/...`, or any future
  ///   variant) — the ID is uniquely formatted enough that a
  ///   first-match regex finds it without per-host parsing.
  ///
  /// Marked `nonisolated` because the function is purely textual and
  /// mainly exists for unit tests; running it off the main actor in
  /// a future store-search pipeline costs nothing.
  nonisolated static func parseChromeWebStoreID(_ input: String) -> String? {
    if let match = input.firstMatch(of: #/[a-p]{32}/#) {
      return String(match.0)
    }
    return nil
  }

  /// Pull an AMO slug out of `input`. Accepts:
  /// - a bare slug (`bitwarden-password-manager`)
  /// - any AMO listing URL (`addons.mozilla.org/<locale>/firefox/addon/<slug>/`).
  ///
  /// AMO slugs follow a strict lowercase-alphanumeric + `-`/`_`
  /// alphabet starting with a letter or digit. The regex enforces
  /// that shape both inside the URL capture and in the bare-input
  /// path, so values like `..`, `foo:bar`, or uppercase-mixed
  /// strings are rejected up front instead of being passed to the
  /// AMO API as a valid-looking slug.
  nonisolated static func parseAMOSlug(_ input: String) -> String? {
    if let match = input.firstMatch(of: #/firefox/addon/([a-z0-9][a-z0-9_-]*)/#) {
      return String(match.output.1)
    }
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let match = trimmed.wholeMatch(of: #/[a-z0-9][a-z0-9_-]*/#) {
      return String(match.0)
    }
    return nil
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
    cell.onRowAction = { [weak self] sourceURL, action in
      self?.handle(action: action, for: sourceURL)
    }
    return cell
  }

  func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
    SidebarListRowView()
  }
}

// MARK: - Row action routing

/// Per-row action surfaced via the trailing ellipsis menu. The cell
/// fans these out through a single callback so this view can own all
/// the orchestration (controller mutations, error alerts, scheduling).
enum ExtensionRowAction {
  case reload
  case viewErrors
  case remove
}

extension ExtensionsSidebarView {
  fileprivate func handle(action: ExtensionRowAction, for sourceURL: URL) {
    switch action {
    case .reload:
      Task { @MainActor in
        do {
          try await ExtensionController.shared.reloadExtension(for: sourceURL)
        } catch {
          presentRowAlert(
            title: "Could not reload extension",
            text: error.localizedDescription,
            style: .warning
          )
        }
      }
    case .viewErrors:
      let errors = ExtensionController.shared.errors(for: sourceURL)
      let body =
        errors.isEmpty
        ? "No runtime errors have been reported for this extension."
        : errors.enumerated()
          .map { i, ns in "\(i + 1). [\(ns.domain) #\(ns.code)] \(ns.localizedDescription)" }
          .joined(separator: "\n\n")
      presentRowAlert(
        title: "Extension errors", text: body, style: .informational
      )
    case .remove:
      ExtensionController.shared.removeExtension(for: sourceURL)
    }
  }

  /// Sheet-modal alert anchored to `hostWindow`, falling back to a
  /// freestanding modal when the view is detached. Shared landing
  /// for store-install / row-action / add errors so all three paths
  /// render identically and the window-detach corner case never
  /// drops an alert silently.
  private func presentRowAlert(title: String, text: String, style: NSAlert.Style) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    alert.alertStyle = style
    if let host = hostWindow {
      alert.beginSheetModal(for: host, completionHandler: nil)
    } else {
      alert.runModal()
    }
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

  /// Fired when the user picks an item from the hover-revealed menu.
  /// The single callback (rather than per-action callbacks) lets the
  /// parent dispatch on the enum and keep all the orchestration in one
  /// place — same idiom as `BookmarkRowAction` in `BookmarksSidebarView`.
  var onRowAction: ((URL, ExtensionRowAction) -> Void)?

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
    let hasErrors = !ExtensionController.shared.errors(for: sourceURL).isEmpty
    let menu = NSMenu()
    // Default-true autoenablesItems would override per-item
    // `isEnabled = false` whenever the item carries a wired
    // target/action, masking the disabled state for `View Errors`.
    menu.autoenablesItems = false

    // Bind the URL to each menu item rather than reading
    // `currentSourceURL` at fire time. The menu pop-up runs a nested
    // runloop, and a `didChangeNotification` arriving during it would
    // trigger `tableView.reloadData()` and overwrite this cell's
    // `currentSourceURL` with another row's URL — picking the wrong
    // extension to act on. The captured values here are immutable.
    menu.addItem(
      buildMenuItem(
        title: "Reload",
        symbol: "arrow.clockwise",
        action: #selector(menuReload(_:)),
        sourceURL: sourceURL
      )
    )
    menu.addItem(
      buildMenuItem(
        title: "View Errors",
        symbol: "exclamationmark.triangle",
        action: #selector(menuViewErrors(_:)),
        sourceURL: sourceURL,
        enabled: hasErrors
      )
    )
    menu.addItem(.separator())
    menu.addItem(
      buildMenuItem(
        title: "Move to Trash",
        symbol: "trash",
        action: #selector(menuRemove(_:)),
        sourceURL: sourceURL
      )
    )

    // Anchor flush to the menu button's bottom-left so the first item
    // sits directly under the glyph (same idiom as Bookmarks).
    let origin = NSPoint(x: 0, y: menuButton.bounds.height)
    menu.popUp(positioning: nil, at: origin, in: menuButton)
  }

  private func buildMenuItem(
    title: String,
    symbol: String,
    action: Selector,
    sourceURL: URL,
    enabled: Bool = true
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    item.representedObject = sourceURL
    item.isEnabled = enabled
    return item
  }

  @objc private func menuReload(_ sender: NSMenuItem) {
    guard let sourceURL = sourceURL(from: sender) else { return }
    onRowAction?(sourceURL, .reload)
  }

  @objc private func menuViewErrors(_ sender: NSMenuItem) {
    guard let sourceURL = sourceURL(from: sender) else { return }
    onRowAction?(sourceURL, .viewErrors)
  }

  @objc private func menuRemove(_ sender: NSMenuItem) {
    guard let sourceURL = sourceURL(from: sender) else { return }
    onRowAction?(sourceURL, .remove)
  }

  /// Pull the row's URL back out of the menu item. A nil result means
  /// the item was constructed without `representedObject` set —
  /// `buildMenuItem` always populates it, so a nil here is a bug in
  /// the constructor rather than a user-visible no-op.
  private func sourceURL(from item: NSMenuItem) -> URL? {
    if let url = item.representedObject as? URL { return url }
    extensionsCellLogger.error(
      "Menu item '\(item.title, privacy: .public)' fired without a representedObject URL"
    )
    return nil
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
