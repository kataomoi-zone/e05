import AppKit
import os.log

private let extensionsCellLogger = Logger(
  subsystem: LogSubsystem.app, category: "ExtensionsSidebar"
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
/// hover-revealed ellipsis menu (`Reload`, `View Errors`,
/// `Open Options Page`, `Move to Trash`). The options page opens as
/// a regular browser column whose `WKWebView` is built from the
/// extension context's own `webViewConfiguration` — see
/// `PaneModel.init` for the `webkit-extension://` routing.
@MainActor
final class ExtensionsSidebarView: NSView {
  private let scrollView = NSScrollView()
  private let tableView = NSTableView()
  private let emptyLabel = NSTextField(labelWithString: "")
  private let addButton = NSButton()
  private let openStoreButton = NSButton()
  private var rows: [LoadedExtension] = []
  nonisolated(unsafe) private var changeObserver: NSObjectProtocol?
  nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?

  /// Fired when the user picks `Open Options Page`. The sidebar VC
  /// wires this to `PaneContainerViewController.addColumn(address:)`
  /// so the options page lands as a fresh browser column in the
  /// current workspace, mirroring Bookmarks / History `onOpen` UX.
  var onOpenURL: ((URL) -> Void)?

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
    // Single click on a row body activates the extension (opens its
    // popup, or fires `onClicked`). Clicks on the switch / ellipsis are
    // consumed by those controls and never reach this action.
    tableView.target = self
    tableView.action = #selector(handleRowClick)
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
    addButton.title = "Add from Folder or ZIP"
    addButton.image = NSImage(
      systemSymbolName: "plus", accessibilityDescription: "Add from Folder or ZIP"
    )
    addButton.imagePosition = .imageLeading
    addButton.bezelStyle = .recessed
    addButton.font = .systemFont(ofSize: 11, weight: .medium)
    addButton.target = self
    addButton.action = #selector(addFromFolderClicked)
    addButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(addButton)

    // Companion button that routes the user to the Chrome Web Store
    // in a fresh browser pane. The `ChromeWebStoreOverlay` user
    // script picks up from there: install buttons are rewritten to
    // "Add to E05" and the click intercept funnels through the
    // controller's existing CRX install path.
    openStoreButton.title = "Open Web Store"
    openStoreButton.image = NSImage(
      systemSymbolName: "swatchpalette", accessibilityDescription: "Open Web Store"
    )
    openStoreButton.imagePosition = .imageLeading
    openStoreButton.bezelStyle = .recessed
    openStoreButton.font = .systemFont(ofSize: 11, weight: .medium)
    openStoreButton.target = self
    openStoreButton.action = #selector(openStoreClicked)
    openStoreButton.toolTip = "Open the Chrome Web Store in a new column"
    openStoreButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(openStoreButton)

    // Two-line empty state mirroring the placeholder feel of other
    // sidebar modes. The path hint surfaces the convention so users
    // know where the picker copies the chosen folder to.
    emptyLabel.font = .systemFont(ofSize: 12)
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.drawsBackground = false
    emptyLabel.isHidden = true
    emptyLabel.alignment = .center
    emptyLabel.maximumNumberOfLines = 0
    // The bundle-id-keyed path under `~/Library/Application Support/`
    // has no internal whitespace to break on, so `.byWordWrapping`
    // would push the long token off the sidebar's right edge. Char-
    // wrapping lets the path wrap inside the bundle id segment, and
    // the leading `~` keeps the home prefix readable.
    emptyLabel.lineBreakMode = .byCharWrapping
    let abbreviatedPath = ExtensionController.extensionsRoot.path
      .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    emptyLabel.stringValue =
      "No extensions loaded.\n"
      + "Use the buttons above or drop an\n"
      + "unpacked extension into\n"
      + abbreviatedPath
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(emptyLabel)

    NSLayoutConstraint.activate([
      addButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      addButton.heightAnchor.constraint(equalToConstant: 22),

      // Stack the Web Store button below the folder/ZIP button so
      // both keep their full labels; the two text buttons would
      // overflow the sidebar width if placed on a single row.
      openStoreButton.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 4),
      openStoreButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      openStoreButton.heightAnchor.constraint(equalToConstant: 22),

      scrollView.topAnchor.constraint(equalTo: openStoreButton.bottomAnchor, constant: 6),
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

  @objc private func openStoreClicked() {
    guard let url = URL(string: "https://chromewebstore.google.com/") else { return }
    onOpenURL?(url)
  }

  private func presentAddError(_ error: Error) {
    presentRowAlert(
      title: "Could not add extension",
      text: error.localizedDescription,
      style: .warning
    )
  }

  /// Whether the focused workspace is private. When it is, an enabled
  /// extension that isn't granted private access reads as inactive in
  /// the list — "on overall, off here". Refreshed on every reload and
  /// on workspace switches via `refreshPrivateContext()`.
  private var isPrivateContext = false

  private func currentWorkspaceIsPrivate() -> Bool {
    ExtensionController.shared.workspaceBridge.container?.currentWorkspace.isPrivate ?? false
  }

  /// Re-render when the focused workspace may have changed (a switch
  /// into or out of a private workspace). Reloads only when the private
  /// context actually flipped — the worklane reload that drives this
  /// fires on every focus change, most of which don't cross the boundary.
  func refreshPrivateContext() {
    guard currentWorkspaceIsPrivate() != isPrivateContext else { return }
    reload()
  }

  private func reload() {
    isPrivateContext = currentWorkspaceIsPrivate()
    rows = ExtensionController.shared.loadedExtensions
    tableView.reloadData()
    emptyLabel.isHidden = !rows.isEmpty
  }

  /// Activate the clicked extension — the same effect as clicking its
  /// toolbar button: open the popup popover (anchored to the row's
  /// icon) or fire the extension's `onClicked` handler when it has no
  /// popup. Disabled extensions are skipped because their
  /// `WKWebExtensionContext` is unloaded — there is nothing to action
  /// and the row's switch is the user-facing control in that state.
  @objc private func handleRowClick() {
    let row = tableView.clickedRow
    guard row >= 0, row < rows.count else { return }
    let entry = rows[row]
    guard entry.isEnabled else { return }
    // Inactive in the focused private workspace: the popup would act on
    // the non-private context, so the row is a no-op just like a disabled
    // one (it reads as dimmed for the same reason).
    guard !(isPrivateContext && !entry.allowsPrivate) else { return }
    guard
      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
        as? ExtensionsSidebarCellView
    else { return }
    // WebKit may dispatch the popover present asynchronously. If a
    // `didChangeNotification` reloads the table in that gap, NSTableView
    // can recycle this cell onto another row, so the popover may sprout
    // from a different row's icon — cosmetic only: the action still
    // targets the right extension by `sourceURL`, and the delegate's
    // window-liveness guard keeps it from anchoring to a detached view.
    ExtensionController.shared.performAction(
      for: entry.sourceURL, anchorView: cell, anchorRect: cell.actionAnchorRect)
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
    cell.configure(with: rows[row], isPrivateContext: isPrivateContext)
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
  /// Open the extension's options page (`options_page` /
  /// `options_ui.page` from the manifest) as a fresh browser column.
  /// Gated on `LoadedExtension.hasOptionsPage` at menu-build time.
  case openOptionsPage
  /// Surface the extension as a permanent button in the URL bar's
  /// action row. Toggles to `.unpinFromURLBar` on next click.
  case pinToURLBar
  /// Drop the URL-bar permanent slot. The extension is still
  /// reachable via the puzzle-piece menu.
  case unpinFromURLBar
  /// Grant the extension access to private workspaces. Toggles to
  /// `.disallowPrivate` on next click.
  case allowPrivate
  /// Revoke private-workspace access.
  case disallowPrivate
  /// Move the extension's source archive to the Trash and clear all
  /// caches.
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
    case .openOptionsPage:
      // The cell already greys out this menu item unless the manifest
      // declares an options page **and** the extension is enabled, so
      // a nil URL here means a TOCTOU (the user disabled the extension
      // through some other path between menu render and click).
      // Quietly drop the action — the row's switch is the actionable
      // signal in that race.
      guard let url = ExtensionController.shared.optionsPageURL(for: sourceURL) else {
        return
      }
      onOpenURL?(url)
    case .pinToURLBar:
      ExtensionController.shared.setPinned(true, for: sourceURL)
    case .unpinFromURLBar:
      ExtensionController.shared.setPinned(false, for: sourceURL)
    case .allowPrivate:
      ExtensionController.shared.setAllowsPrivate(true, for: sourceURL)
    case .disallowPrivate:
      ExtensionController.shared.setAllowsPrivate(false, for: sourceURL)
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
  /// Mirrored from the latest `configure(with:)` so menu construction
  /// can gate `Open Options Page` on the manifest declaration without
  /// re-reading the snapshot.
  private var currentHasOptionsPage = false
  /// Mirrors `LoadedExtension.isEnabled`; combined with
  /// `currentHasOptionsPage` to gate the `Open Options Page` menu
  /// item. Disabled extensions can't host their options page (the
  /// underlying `WKWebExtensionContext` is unloaded), so the row's
  /// enable/disable switch is the user-facing fix and the menu
  /// item should reflect that by greying out rather than firing an
  /// alert when clicked.
  private var currentIsEnabled = true
  /// Mirrors `LoadedExtension.isPinned` so menu construction can pick
  /// between `Pin to URL Bar` and `Unpin from URL Bar` without
  /// re-querying the controller during pop-up runloop.
  private var currentIsPinned = false

  /// Mirrors `LoadedExtension.allowsPrivate` so the menu's private-access
  /// item shows the right checkmark without a controller hop.
  private var currentAllowsPrivate = false

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

  /// Frame of the icon in the cell's own coordinates — used as the
  /// popup popover's anchor so the arrow points at the extension's
  /// icon rather than the full-width row.
  var actionAnchorRect: NSRect { iconView.frame }

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
    // Manifests without an options page declaration get a disabled
    // entry rather than a missing one, so the menu shape stays
    // identical across rows — Safari and Chrome do the same with
    // their per-extension management menus. Disabled extensions
    // also grey the item out: the underlying
    // `WKWebExtensionContext` is unloaded so the page can't be
    // hosted; the row's enable switch is the user-facing fix.
    menu.addItem(
      buildMenuItem(
        title: "Open Options Page",
        symbol: "gearshape",
        action: #selector(menuOpenOptionsPage(_:)),
        sourceURL: sourceURL,
        enabled: currentHasOptionsPage && currentIsEnabled
      )
    )
    // Pin/unpin reads from the snapshot so the label flips instantly
    // when the controller posts a change. Greyed out for disabled
    // rows: an inactive extension shouldn't take a permanent URL-bar
    // slot, and the URL-bar buttons would render as dead clicks
    // anyway.
    menu.addItem(
      buildMenuItem(
        title: currentIsPinned ? "Unpin from URL Bar" : "Pin to URL Bar",
        symbol: currentIsPinned ? "pin.slash" : "pin",
        action: #selector(menuTogglePin(_:)),
        sourceURL: sourceURL,
        enabled: currentIsEnabled
      )
    )
    // Private-workspace access is a per-extension grant (a checkmark,
    // not a label flip): off by default so private browsing stays
    // invisible to extensions until the user opts this one in.
    let privateItem = buildMenuItem(
      title: "Allow in Private Workspaces",
      symbol: "hand.raised",
      action: #selector(menuToggleAllowsPrivate(_:)),
      sourceURL: sourceURL,
      enabled: currentIsEnabled
    )
    privateItem.state = currentAllowsPrivate ? .on : .off
    menu.addItem(privateItem)

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

  @objc private func menuOpenOptionsPage(_ sender: NSMenuItem) {
    guard let sourceURL = sourceURL(from: sender) else { return }
    onRowAction?(sourceURL, .openOptionsPage)
  }

  @objc private func menuTogglePin(_ sender: NSMenuItem) {
    guard let sourceURL = sourceURL(from: sender) else { return }
    // `currentIsPinned` is the snapshot captured by `configure`; if a
    // reload during the menu's nested runloop updated it, this read
    // sees the fresh value. `setPinned` is idempotent on the
    // requested side, so even a stale read just dispatches a no-op.
    onRowAction?(sourceURL, currentIsPinned ? .unpinFromURLBar : .pinToURLBar)
  }

  @objc private func menuToggleAllowsPrivate(_ sender: NSMenuItem) {
    guard let sourceURL = sourceURL(from: sender) else { return }
    onRowAction?(sourceURL, currentAllowsPrivate ? .disallowPrivate : .allowPrivate)
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

  func configure(with entry: LoadedExtension, isPrivateContext: Bool) {
    currentSourceURL = entry.sourceURL
    currentHasOptionsPage = entry.hasOptionsPage
    currentIsEnabled = entry.isEnabled
    currentIsPinned = entry.isPinned
    currentAllowsPrivate = entry.allowsPrivate
    titleLabel.stringValue = entry.displayName
    // Enabled globally but not granted private access while the focused
    // workspace is private: the extension is loaded but does nothing in
    // this tab. The dimming below carries that visually; the row text
    // stays the version so the layout doesn't shift (the explanation
    // lives in the tooltip).
    let inactiveInPrivate = isPrivateContext && entry.isEnabled && !entry.allowsPrivate
    if let version = entry.version, !version.isEmpty {
      subtitleLabel.stringValue = "v\(version)"
    } else {
      // Manifest version is typed as `Double` in the WKWebExtension
      // surface; render with `%g` so MV3 reads as "MV3" instead of
      // "MV3.0" when the manifest declared the integer literal.
      let mv = String(format: "%g", entry.manifestVersion)
      subtitleLabel.stringValue = "MV\(mv)"
    }
    iconView.image =
      entry.icon
      ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
    // Dim the metadata when the row is inert at a glance — disabled
    // globally, or enabled-but-inactive in the current private
    // workspace — matching how Safari and Chrome dim such rows. The
    // switch keeps its true (global) on/off so the user sees it's still
    // enabled overall; the `⋯` menu's "Allow in Private Workspaces"
    // grant is how they light it up here.
    let alpha: CGFloat = (entry.isEnabled && !inactiveInPrivate) ? 1.0 : 0.45
    iconView.alphaValue = alpha
    titleLabel.alphaValue = alpha
    subtitleLabel.alphaValue = alpha
    toggle.state = entry.isEnabled ? .on : .off
    toolTip =
      inactiveInPrivate
      ? "\(entry.displayName) — enabled, but not allowed in private workspaces (⋯ to allow)"
      : entry.displayName
  }
}
