import AppKit

/// Item identity for the outline view. NSOutlineView tracks
/// expansion / selection state by `isEqual:`, so wrapping each row
/// in a reference type with id-based equality lets us rebuild rows
/// on every reload while keeping the user's expand/collapse state.
/// The mutable `entry` lets folder rename / move land without
/// invalidating the surrounding outline-view bookkeeping.
@MainActor
final class BookmarkNode: NSObject {
  let id: Int64
  fileprivate(set) var entry: Bookmarks.Entry
  init(_ entry: Bookmarks.Entry) {
    self.id = entry.id
    self.entry = entry
  }
  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? BookmarkNode else { return false }
    return id == other.id
  }
  override var hash: Int { Int(id) }
}

/// Bookmarks tree rendered inside the sidebar's `bookmarks` mode.
/// Subscribes to the shared `Bookmarks` store so external mutations
/// (URL bar Cmd+D, command palette Toggle Bookmark, folder ops on
/// this view) reflect live without a manual reload.
///
/// Sized for the 260pt sidebar: transparent background (Liquid Glass
/// stays visible), no header (the mode name is already in the places
/// section), compact bookmark rows (40pt) and folder rows (28pt),
/// hover-revealed per-row action menu.
@MainActor
final class BookmarksSidebarView: NSView {
  /// Fired on single click of a bookmark row. UX policy: always open
  /// in a new browser column in the current workspace.
  var onOpen: ((String) -> Void)?

  /// Fired on Cmd+click of a bookmark row. UX policy: always open in
  /// a newly created workspace. The container is responsible for the
  /// `createWorkspace()` + `addColumn` orchestration.
  var onOpenInNewWorkspace: ((String) -> Void)?

  private let bookmarks: Bookmarks
  private var listenerToken: BookmarksListenerToken?
  private let scrollView = NSScrollView()
  private let outlineView = NSOutlineView()
  private let emptyLabel = NSTextField(labelWithString: "No bookmarks yet")

  /// Item objects keyed by id so reloads can reuse the instances that
  /// the outline view already knows about. Without reuse, the
  /// expand/collapse state would reset every time a row is added or
  /// removed.
  private var nodesById: [Int64: BookmarkNode] = [:]
  /// Top-level rows. Outline view asks for these when item is nil.
  private var rootChildren: [BookmarkNode] = []
  /// Children of every folder, keyed by folder id.
  private var childrenByParentId: [Int64: [BookmarkNode]] = [:]

  nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?
  nonisolated(unsafe) private var faviconObserver: NSObjectProtocol?

  init(bookmarks: Bookmarks) {
    self.bookmarks = bookmarks
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    setupLayout()
    reload()
    listenerToken = bookmarks.addListener { [weak self] in self?.reload() }
    // Re-render every cell when a favicon fetch settles so rows
    // showing the `globe` placeholder for the newly-cached host
    // upgrade in place. A single reloadData is cheap — the row
    // count is bounded by user-saved bookmarks and fits in one
    // scroll view.
    faviconObserver = NotificationCenter.default.addObserver(
      forName: FaviconCache.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.outlineView.reloadData() }
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  deinit {
    // Block-based observers keep their closure retained inside
    // NotificationCenter until the token is passed to
    // `removeObserver`, so a `[weak self]` capture alone does not
    // free the subscription. The `Bookmarks` listener is left
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
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bookmark"))
    column.resizingMask = .autoresizingMask
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column
    outlineView.headerView = nil
    outlineView.backgroundColor = .clear
    outlineView.rowSizeStyle = .custom
    outlineView.intercellSpacing = NSSize(width: 0, height: 1)
    outlineView.selectionHighlightStyle = .regular
    outlineView.allowsMultipleSelection = false
    outlineView.style = .plain
    outlineView.indentationPerLevel = 12
    outlineView.indentationMarkerFollowsCell = true
    outlineView.target = self
    outlineView.action = #selector(handleClick)
    outlineView.dataSource = self
    outlineView.delegate = self
    installContextMenu()
    scrollView.documentView = outlineView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scrollView)

    // Hover-revealed action buttons rely on NSTrackingArea with
    // `.inVisibleRect`, which doesn't deliver `mouseExited` when a
    // hovered cell scrolls out from under a stationary cursor. Watch
    // the clip view's bounds change so the parent can force-hide
    // every cell's hover affordance on any scroll.
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
    // Snapshot the full tree in one pass so the outline-view data
    // source can answer `numberOfChildrenOfItem` / `child:ofItem:`
    // from in-memory dictionaries instead of re-querying SQLite for
    // every node.
    let allEntries = bookmarks.all()
    var newNodes: [Int64: BookmarkNode] = [:]
    // Reuse the existing node instance when an id survives a reload.
    // Outline view tracks expansion state by `isEqual:`; reusing the
    // same object short-circuits the equality check and also keeps
    // selection / hover bookkeeping pointed at the right rows.
    for entry in allEntries {
      if let existing = nodesById[entry.id] {
        existing.entry = entry
        newNodes[entry.id] = existing
      } else {
        newNodes[entry.id] = BookmarkNode(entry)
      }
    }
    nodesById = newNodes

    var rootBuckets: [BookmarkNode] = []
    var byParent: [Int64: [BookmarkNode]] = [:]
    for entry in allEntries {
      guard let node = newNodes[entry.id] else { continue }
      if let parentId = entry.parentId {
        byParent[parentId, default: []].append(node)
      } else {
        rootBuckets.append(node)
      }
    }
    // Bucket order is undefined from a single `all()` (which returns
    // most-recent-first across the whole tree). Sort each bucket by
    // the store's authoritative `sort_order` so siblings render in
    // the intended sequence.
    rootChildren = rootBuckets.sorted { $0.entry.sortOrder < $1.entry.sortOrder }
    childrenByParentId = byParent.mapValues { bucket in
      bucket.sorted { $0.entry.sortOrder < $1.entry.sortOrder }
    }

    outlineView.reloadData()
    emptyLabel.isHidden = !rootChildren.isEmpty
  }

  private func hideAllActionButtons() {
    outlineView.enumerateAvailableRowViews { _, row in
      if let cell = self.outlineView.view(
        atColumn: 0, row: row, makeIfNecessary: false
      ) as? SidebarListCellView {
        cell.forceHideHoverActions()
      }
    }
  }

  /// Right-click context menu on the outline view background or any
  /// row. Currently exposes "New Folder" only; later substages will
  /// extend the menu with rename / open-all / etc. depending on the
  /// row under the cursor.
  private func installContextMenu() {
    let menu = NSMenu()
    let newFolder = NSMenuItem(
      title: "New Folder", action: #selector(menuNewFolder), keyEquivalent: "")
    newFolder.target = self
    menu.addItem(newFolder)
    outlineView.menu = menu
  }

  @objc private func menuNewFolder() {
    // Right-click in a folder row creates the new folder inside it
    // ("New Folder Here" semantics). Right-click on a bookmark row
    // or empty area creates it at the same level as the clicked row,
    // falling back to the root when nothing is clicked.
    let parentId: Int64? = {
      let row = outlineView.clickedRow
      guard row >= 0, let node = outlineView.item(atRow: row) as? BookmarkNode else {
        return nil
      }
      return node.entry.isFolder ? node.id : node.entry.parentId
    }()
    presentNewFolderSheet(parentId: parentId)
  }

  private func presentNewFolderSheet(parentId: Int64?) {
    guard let window else { return }

    let alert = NSAlert()
    alert.messageText = "New Folder"
    alert.informativeText = "Name the folder."
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")

    let nameField = NSTextField(string: "")
    nameField.placeholderString = "Folder name"
    nameField.translatesAutoresizingMaskIntoConstraints = false
    // Seed the frame for the same reason as the bookmark edit
    // sheet — without an initial size, NSAlert collapses the
    // accessory view to a sliver before Auto Layout resolves the
    // text-field width.
    nameField.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
    NSLayoutConstraint.activate([
      nameField.widthAnchor.constraint(equalToConstant: 280),
    ])

    alert.accessoryView = nameField
    alert.window.initialFirstResponder = nameField

    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .alertFirstButtonReturn else { return }
      let title = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let resolved = title.isEmpty ? "New Folder" : title
      // The new folder lands at the end of its parent's sibling
      // list (see `Bookmarks.createFolder`). Expand the parent so
      // the new row is visible without the user having to chase it.
      _ = self.bookmarks.createFolder(title: resolved, parentId: parentId)
      if let parentId, let parentNode = self.nodesById[parentId] {
        self.outlineView.expandItem(parentNode)
      }
    }
  }

  @objc private func handleClick() {
    let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
    guard row >= 0, let node = outlineView.item(atRow: row) as? BookmarkNode else { return }
    if node.entry.isFolder {
      // Body click toggles expansion. The user can also drag the OS
      // disclosure triangle on the leading edge for the same effect;
      // mirroring that gesture on the row makes the affordance work
      // without needing to hit the small triangle exactly.
      if outlineView.isItemExpanded(node) {
        outlineView.collapseItem(node)
      } else {
        outlineView.expandItem(node)
      }
      return
    }
    guard let url = node.entry.url else { return }
    let cmdHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
    if cmdHeld {
      onOpenInNewWorkspace?(url)
    } else {
      onOpen?(url)
    }
  }
}

// MARK: - NSOutlineViewDataSource

extension BookmarksSidebarView: NSOutlineViewDataSource {
  func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    children(of: item).count
  }

  func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    children(of: item)[index]
  }

  func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
    guard let node = item as? BookmarkNode else { return false }
    return node.entry.isFolder
  }

  private func children(of item: Any?) -> [BookmarkNode] {
    guard let node = item as? BookmarkNode else { return rootChildren }
    return childrenByParentId[node.id] ?? []
  }
}

// MARK: - NSOutlineViewDelegate

extension BookmarksSidebarView: NSOutlineViewDelegate {
  func outlineView(
    _ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any
  ) -> NSView? {
    guard let node = item as? BookmarkNode else { return nil }
    if node.entry.isFolder {
      let id = NSUserInterfaceItemIdentifier("BookmarksSidebarFolderCell")
      let cell =
        outlineView.makeView(withIdentifier: id, owner: self)
        as? BookmarksSidebarFolderCellView
        ?? BookmarksSidebarFolderCellView(identifier: id)
      cell.configure(with: node.entry)
      cell.onRowAction = { [weak self] id, action in
        self?.handleFolderAction(id: id, action: action)
      }
      return cell
    }
    let id = NSUserInterfaceItemIdentifier("BookmarksSidebarCell")
    let cell =
      outlineView.makeView(withIdentifier: id, owner: self)
      as? BookmarksSidebarBookmarkCellView
      ?? BookmarksSidebarBookmarkCellView(identifier: id)
    cell.configure(with: node.entry)
    cell.onRowAction = { [weak self] id, action in
      self?.handleRowAction(id: id, action: action)
    }
    return cell
  }

  func outlineView(_: NSOutlineView, rowViewForItem _: Any) -> NSTableRowView? {
    SidebarListRowView()
  }

  func outlineView(_: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
    guard let node = item as? BookmarkNode else { return BookmarksSidebarBookmarkCellView.height }
    return node.entry.isFolder
      ? BookmarksSidebarFolderCellView.height
      : BookmarksSidebarBookmarkCellView.height
  }
}

// MARK: - Row action routing

extension BookmarksSidebarView {
  fileprivate func handleRowAction(id: Int64, action: BookmarkRowAction) {
    guard let node = nodesById[id], let url = node.entry.url else { return }
    switch action {
    case .edit:
      presentEditSheet(for: node.entry, url: url)
    case .delete:
      bookmarks.remove(id: id)
    case .copyURL:
      let pb = NSPasteboard.general
      pb.clearContents()
      pb.setString(url, forType: .string)
    case .openInCurrentWorkspace:
      onOpen?(url)
    case .openInNewWorkspace:
      onOpenInNewWorkspace?(url)
    }
  }

  /// Folder-specific actions. The schema's `ON DELETE CASCADE`
  /// removes descendants for us so the delete path is a single
  /// store call rather than a recursive walk on the view side.
  fileprivate func handleFolderAction(id: Int64, action: FolderRowAction) {
    switch action {
    case .rename:
      guard let node = nodesById[id] else { return }
      presentRenameFolderSheet(for: node.entry)
    case .delete:
      bookmarks.remove(id: id)
    }
  }

  private func presentRenameFolderSheet(for entry: Bookmarks.Entry) {
    guard let window else { return }

    let alert = NSAlert()
    alert.messageText = "Rename Folder"
    alert.informativeText = "Choose a new name."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")

    let nameField = NSTextField(string: entry.title)
    nameField.placeholderString = "Folder name"
    nameField.translatesAutoresizingMaskIntoConstraints = false
    nameField.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
    NSLayoutConstraint.activate([
      nameField.widthAnchor.constraint(equalToConstant: 280),
    ])

    alert.accessoryView = nameField
    alert.window.initialFirstResponder = nameField
    // Select the existing text so a single keystroke replaces it,
    // matching Finder's rename affordance.
    nameField.selectText(nil)

    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .alertFirstButtonReturn else { return }
      let title = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      // Empty title would leave a blank, hard-to-find row in the
      // tree. Drop the rename instead of silently substituting a
      // placeholder, mirroring the bookmark edit sheet's policy on
      // empty URLs.
      guard !title.isEmpty else { return }
      _ = self.bookmarks.setTitle(id: entry.id, title: title)
    }
  }

  /// Present a modal sheet with Name and URL fields pre-populated
  /// from the bookmark. Save commits via `Bookmarks.update`; a
  /// UNIQUE collision (URL already bookmarked) surfaces a follow-up
  /// warning alert instead of silently swallowing the edit. Folder
  /// entries have no URL, so callers pre-resolve the unwrap.
  private func presentEditSheet(for entry: Bookmarks.Entry, url: String) {
    guard let window else { return }

    let alert = NSAlert()
    alert.messageText = "Edit Bookmark"
    alert.informativeText = "Update the name or URL."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")

    let nameField = NSTextField(string: entry.title)
    nameField.placeholderString = "Name"
    nameField.translatesAutoresizingMaskIntoConstraints = false

    let urlField = NSTextField(string: url)
    urlField.placeholderString = "URL"
    urlField.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [nameField, urlField])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    // NSAlert sizes its accessoryView from a combination of the
    // initial frame and Auto Layout's fittingSize. Seeding the
    // frame is not dead code: without it, the accessoryView is
    // installed at NSRect.zero and collapses to a sliver before
    // the layout pass resolves the text-field width constraints.
    // Keep both the frame seed and the constraint to get a sheet
    // that's sized correctly on its first appearance.
    stack.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
    NSLayoutConstraint.activate([
      nameField.widthAnchor.constraint(equalToConstant: 320),
      urlField.widthAnchor.constraint(equalToConstant: 320),
    ])

    alert.accessoryView = stack
    alert.window.initialFirstResponder = nameField

    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .alertFirstButtonReturn else { return }
      let newTitle = nameField.stringValue
      let newURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      // Empty URL would leave a ghost row impossible to focus —
      // surface it as an error instead of silently no-op'ing.
      guard !newURL.isEmpty else {
        self.presentEditError(message: "URL cannot be empty.")
        return
      }
      let ok = self.bookmarks.update(id: entry.id, title: newTitle, url: newURL)
      if !ok {
        self.presentEditError(
          message: "That URL is already bookmarked — changes were not saved."
        )
      }
    }
  }

  private func presentEditError(message: String) {
    guard let window else { return }
    let alert = NSAlert()
    alert.messageText = "Could not save bookmark"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.beginSheetModal(for: window, completionHandler: nil)
  }
}

// MARK: - Cell actions

/// Per-row action surfaced via the bookmark cell's trailing ellipsis
/// menu. A single callback on the cell dispatches on this enum so
/// the parent view can own all the orchestration (store mutation,
/// pasteboard writes, workspace routing, edit sheet presentation)
/// in one place.
enum BookmarkRowAction {
  case edit
  case delete
  case copyURL
  case openInCurrentWorkspace
  case openInNewWorkspace
}

/// Folder-row analogue of `BookmarkRowAction`. Drag-into-folder
/// reordering lands in a separate commit; the menu so far covers
/// the destructive and rename paths.
enum FolderRowAction {
  case rename
  case delete
}

// MARK: - Bookmark cell

/// Compact two-line cell for a leaf bookmark: title on top (label
/// color) and host on the bottom (secondary). Hovering reveals a
/// trailing ellipsis (…) button that opens an action menu.
/// Transparent background so the Liquid Glass sidebar remains
/// visible through the row.
private final class BookmarksSidebarBookmarkCellView: SidebarListCellView {
  static let height: CGFloat = 40
  static let iconSize: CGFloat = 16

  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let hostLabel = NSTextField(labelWithString: "")
  private let actionButton = HoverIconButton()
  private var currentID: Int64 = 0

  var onRowAction: ((Int64, BookmarkRowAction) -> Void)?

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

    hostLabel.font = .systemFont(ofSize: 10)
    hostLabel.textColor = .secondaryLabelColor
    hostLabel.lineBreakMode = .byTruncatingTail
    hostLabel.drawsBackground = false
    hostLabel.translatesAutoresizingMaskIntoConstraints = false

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
    actionButton.isHidden = true

    addSubview(iconView)
    addSubview(titleLabel)
    addSubview(hostLabel)
    addSubview(actionButton)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
      titleLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -6),

      hostLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
      hostLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      hostLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

      actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      actionButton.widthAnchor.constraint(equalToConstant: 18),
      actionButton.heightAnchor.constraint(equalToConstant: 18),
    ])
  }

  override func setHoverActionsHidden(_ hidden: Bool) {
    actionButton.isHidden = hidden
  }

  func configure(with entry: Bookmarks.Entry) {
    currentID = entry.id
    // Folder rows have a nil url and never reach this cell (the
    // delegate routes them to the folder cell), but unwrap
    // defensively so a future regression renders an empty
    // placeholder rather than crashing.
    let url = entry.url ?? ""
    titleLabel.stringValue = entry.title.isEmpty ? url : entry.title
    let host = URL(string: url)?.host(percentEncoded: false)
    // Fall back to the full URL if the host can't be parsed — rare
    // but possible for entries stored with an atypical scheme.
    hostLabel.stringValue = host ?? url
    if let host, !host.isEmpty, let image = FaviconCache.shared.image(for: host) {
      iconView.image = image
    } else {
      iconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    }
    // Tooltips surface the full text when the compact 260pt sidebar
    // width truncates either label.
    titleLabel.toolTip =
      entry.title.isEmpty
      ? nil
      : "\(entry.title)\n\(url)"
    hostLabel.toolTip = url
  }

  @objc private func actionTapped() {
    let menu = NSMenu()

    let editItem = NSMenuItem(title: "Edit…", action: #selector(menuEdit), keyEquivalent: "")
    editItem.target = self
    menu.addItem(editItem)

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

  @objc private func menuEdit() { onRowAction?(currentID, .edit) }
  @objc private func menuDelete() { onRowAction?(currentID, .delete) }
  @objc private func menuCopyURL() { onRowAction?(currentID, .copyURL) }
  @objc private func menuOpenInCurrent() { onRowAction?(currentID, .openInCurrentWorkspace) }
  @objc private func menuOpenInNew() { onRowAction?(currentID, .openInNewWorkspace) }
}

// MARK: - Folder cell

/// Single-line cell for a folder row: folder icon + title with a
/// hover-revealed trailing ellipsis menu. The outline view draws
/// its own disclosure triangle on the leading edge.
private final class BookmarksSidebarFolderCellView: SidebarListCellView {
  static let height: CGFloat = 28
  static let iconSize: CGFloat = 14

  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let actionButton = HoverIconButton()
  private var currentID: Int64 = 0

  var onRowAction: ((Int64, FolderRowAction) -> Void)?

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
    iconView.contentTintColor = .secondaryLabelColor
    iconView.image = NSImage(
      systemSymbolName: "folder", accessibilityDescription: "Folder")
    iconView.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
    titleLabel.textColor = .labelColor
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.drawsBackground = false
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

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
    actionButton.isHidden = true

    addSubview(iconView)
    addSubview(titleLabel)
    addSubview(actionButton)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

      titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
      titleLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -6),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      actionButton.widthAnchor.constraint(equalToConstant: 18),
      actionButton.heightAnchor.constraint(equalToConstant: 18),
    ])
  }

  override func setHoverActionsHidden(_ hidden: Bool) {
    actionButton.isHidden = hidden
  }

  func configure(with entry: Bookmarks.Entry) {
    currentID = entry.id
    titleLabel.stringValue = entry.title.isEmpty ? "Untitled folder" : entry.title
    titleLabel.toolTip = entry.title.isEmpty ? nil : entry.title
  }

  @objc private func actionTapped() {
    let menu = NSMenu()
    let renameItem = NSMenuItem(
      title: "Rename…", action: #selector(menuRename), keyEquivalent: "")
    renameItem.target = self
    menu.addItem(renameItem)
    menu.addItem(.separator())
    let deleteItem = NSMenuItem(title: "Delete", action: #selector(menuDelete), keyEquivalent: "")
    deleteItem.target = self
    menu.addItem(deleteItem)
    let origin = NSPoint(x: 0, y: actionButton.bounds.height)
    menu.popUp(positioning: nil, at: origin, in: actionButton)
  }

  @objc private func menuRename() { onRowAction?(currentID, .rename) }
  @objc private func menuDelete() { onRowAction?(currentID, .delete) }
}
