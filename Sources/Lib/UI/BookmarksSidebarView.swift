import AppKit
import UniformTypeIdentifiers

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
  /// Pasteboard type carried while dragging a bookmark row inside
  /// the sidebar. Scoped to this app so a stray drag from another
  /// `.string`-emitting source doesn't trip the validate path; the
  /// payload is the row's id as a decimal `String`.
  fileprivate static let dragPasteboardType = NSPasteboard.PasteboardType(
    "com.kawarimidoll.e05.bookmark.row")

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
    outlineView.registerForDraggedTypes([Self.dragPasteboardType])
    // Only internal moves: the sidebar doesn't synthesise URLs for
    // external apps yet, and forbidding the cross-app vector makes
    // the source check in `acceptDrop` redundant rather than load-
    // bearing.
    outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
    outlineView.setDraggingSourceOperationMask([], forLocal: false)
    installContextMenu()
    scrollView.documentView = outlineView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scrollView)

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

  /// Right-click context menu on the outline view. Populated on
  /// each open so the items match the row under the cursor: bookmark
  /// rows get open / copy / edit / delete; folder rows get
  /// new-folder-here / rename / delete; clicks in empty area get
  /// `New Folder` at the root.
  ///
  /// All row actions live in this menu — there is no trailing
  /// ellipsis button in the cells. Consolidating here matches the
  /// macOS convention used by Finder and Safari's bookmark sidebar,
  /// and frees the cell's trailing edge so a future per-row
  /// affordance (drag handle, badge) has somewhere to land.
  private func installContextMenu() {
    let menu = NSMenu()
    menu.delegate = self
    outlineView.menu = menu
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

  func outlineView(
    _: NSOutlineView, pasteboardWriterForItem item: Any
  ) -> NSPasteboardWriting? {
    guard let node = item as? BookmarkNode else { return nil }
    let pb = NSPasteboardItem()
    pb.setString(String(node.id), forType: Self.dragPasteboardType)
    return pb
  }

  func outlineView(
    _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
    proposedItem item: Any?, proposedChildIndex index: Int
  ) -> NSDragOperation {
    guard let draggedId = draggedRowId(from: info),
      let draggedNode = nodesById[draggedId]
    else { return [] }
    let target = item as? BookmarkNode

    // Self-drop and folder-into-own-descendant would either no-op
    // or create a cycle in the tree, so reject up front.
    if let target, target.id == draggedId { return [] }
    if draggedNode.entry.isFolder, let target,
      isDescendant(candidate: target.id, of: draggedNode.id)
    {
      return []
    }

    // "Drop on a row" is only meaningful for folders. When the user
    // points at a leaf bookmark, retarget the drop to between
    // siblings — visually that drop indicator lines up with the
    // bookmark row's bottom edge.
    let (retargetParent, retargetIndex) = resolveLeafDrop(
      item: target, childIndex: index)
    if retargetParent !== target || retargetIndex != index {
      outlineView.setDropItem(retargetParent, dropChildIndex: retargetIndex)
    }

    return .move
  }

  func outlineView(
    _: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex: Int
  ) -> Bool {
    guard let draggedId = draggedRowId(from: info) else { return false }
    // Re-run the leaf-bookmark retarget here too: AppKit's docs only
    // promise the validateDrop `setDropItem` retarget applies to
    // "subsequent calls", which leaves acceptDrop a gray area. If
    // the retarget didn't carry through we'd be asked to set
    // `parent_id` to a bookmark row's id, producing a leaf-as-parent
    // state that nothing else in the schema rejects.
    let resolvedTarget = resolveLeafDrop(item: item as? BookmarkNode, childIndex: childIndex)
    let newParentId = resolvedTarget.parent?.id

    // Build the post-drop ordered id list for the new parent: drop
    // the moved row out of its current position (which may be in
    // this same parent or elsewhere) and slot it in at the requested
    // child index. `bookmarks.reorder` then renumbers every sibling
    // sort_order in one transaction.
    var newOrder: [Int64] = currentChildren(of: newParentId)
      .map(\.id)
      .filter { $0 != draggedId }
    let insertIndex: Int
    if resolvedTarget.childIndex == NSOutlineViewDropOnItemIndex
      || resolvedTarget.childIndex < 0
    {
      insertIndex = newOrder.count
    } else {
      insertIndex = min(resolvedTarget.childIndex, newOrder.count)
    }
    newOrder.insert(draggedId, at: insertIndex)
    bookmarks.reorder(parentId: newParentId, orderedIds: newOrder)
    return true
  }

  /// When a drop is proposed onto a leaf bookmark row (only folders
  /// are valid drop-on targets), rewrite the target to "between
  /// siblings of that row, immediately after it" so the parent_id
  /// stays a folder. Returns the input unchanged for folder or
  /// background drops.
  private func resolveLeafDrop(
    item: BookmarkNode?, childIndex: Int
  ) -> (parent: BookmarkNode?, childIndex: Int) {
    guard let leaf = item, !leaf.entry.isFolder,
      childIndex == NSOutlineViewDropOnItemIndex
    else { return (item, childIndex) }
    let parent: BookmarkNode? = leaf.entry.parentId.flatMap { nodesById[$0] }
    let siblings = currentChildren(of: parent?.id)
    let rowIndex = siblings.firstIndex(where: { $0.id == leaf.id }) ?? siblings.count
    return (parent, rowIndex + 1)
  }

  private func currentChildren(of parentId: Int64?) -> [BookmarkNode] {
    guard let parentId else { return rootChildren }
    return childrenByParentId[parentId] ?? []
  }

  private func draggedRowId(from info: NSDraggingInfo) -> Int64? {
    guard let items = info.draggingPasteboard.pasteboardItems else { return nil }
    for item in items {
      if let raw = item.string(forType: Self.dragPasteboardType),
        let id = Int64(raw)
      {
        return id
      }
    }
    return nil
  }

  /// Walks `parent_id` chains in the in-memory cache to decide
  /// whether `candidate` lives somewhere under `ancestor`. Reads
  /// only `nodesById` so it can fire from inside validateDrop
  /// without a SQLite round-trip per drag tick.
  private func isDescendant(candidate: Int64, of ancestor: Int64) -> Bool {
    var current = candidate
    while let node = nodesById[current] {
      guard let parentId = node.entry.parentId else { return false }
      if parentId == ancestor { return true }
      current = parentId
    }
    return false
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
      return cell
    }
    let id = NSUserInterfaceItemIdentifier("BookmarksSidebarCell")
    let cell =
      outlineView.makeView(withIdentifier: id, owner: self)
      as? BookmarksSidebarBookmarkCellView
      ?? BookmarksSidebarBookmarkCellView(identifier: id)
    cell.configure(with: node.entry)
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

// MARK: - Context menu

extension BookmarksSidebarView: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    // `clickedRow` reflects the row under the cursor at right-click
    // time; reading it inside the action closures (which fire after
    // the menu closes) would lose the target. Snapshot the node up
    // front and capture it in the closures' selectors via stored
    // ivars on the targets.
    menu.removeAllItems()
    let row = outlineView.clickedRow
    let node = row >= 0 ? outlineView.item(atRow: row) as? BookmarkNode : nil

    if let node, !node.entry.isFolder, let url = node.entry.url {
      append(menu, title: "Open", selector: #selector(menuOpen)) { url }
      append(menu, title: "Open in New Workspace", selector: #selector(menuOpenInNew)) { url }
      menu.addItem(.separator())
      append(menu, title: "Copy URL", selector: #selector(menuCopyURL)) { url }
      append(menu, title: "Edit…", selector: #selector(menuEditBookmark)) { node.id }
      menu.addItem(.separator())
      append(menu, title: "Delete", selector: #selector(menuDelete)) { node.id }
      return
    }

    if let node {
      // Folder row.
      append(menu, title: "New Folder Here", selector: #selector(menuNewFolder)) { node.id }
      menu.addItem(.separator())
      append(menu, title: "Rename…", selector: #selector(menuRenameFolder)) { node.id }
      append(menu, title: "Delete", selector: #selector(menuDelete)) { node.id }
      menu.addItem(.separator())
      // Import lands as a subtree under the clicked folder so the
      // user can scope a one-shot import to a specific section
      // without dumping it at the root. Export mirrors the scoping:
      // only the clicked folder's subtree ends up in the file.
      append(menu, title: "Import…", selector: #selector(menuImport)) { node.id }
      append(menu, title: "Export Folder…", selector: #selector(menuExport)) { node.id }
      return
    }

    // Empty area: top-level actions only.
    append(menu, title: "New Folder", selector: #selector(menuNewFolder)) { Optional<Int64>.none as Any }
    menu.addItem(.separator())
    append(menu, title: "Import…", selector: #selector(menuImport)) { Optional<Int64>.none as Any }
    append(menu, title: "Export All…", selector: #selector(menuExport)) { Optional<Int64>.none as Any }
  }

  /// Build and append a menu item bound to `self` whose
  /// `representedObject` carries the per-row payload the selector
  /// needs to act on (url string / row id / parent id). Stashing
  /// the payload on the item avoids the "re-read clickedRow inside
  /// the action" race where the menu has already closed and the
  /// outline view's click state is gone.
  private func append(
    _ menu: NSMenu, title: String, selector: Selector,
    payload: () -> Any
  ) {
    let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
    item.target = self
    item.representedObject = payload()
    menu.addItem(item)
  }

  @objc private func menuOpen(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? String else { return }
    onOpen?(url)
  }
  @objc private func menuOpenInNew(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? String else { return }
    onOpenInNewWorkspace?(url)
  }
  @objc private func menuCopyURL(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? String else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(url, forType: .string)
  }
  @objc private func menuEditBookmark(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? Int64,
      let node = nodesById[id], let url = node.entry.url
    else { return }
    presentEditSheet(for: node.entry, url: url)
  }
  @objc private func menuDelete(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? Int64 else { return }
    bookmarks.remove(id: id)
  }
  @objc private func menuRenameFolder(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? Int64,
      let node = nodesById[id]
    else { return }
    presentRenameFolderSheet(for: node.entry)
  }
  @objc private func menuNewFolder(_ sender: NSMenuItem) {
    let parentId = sender.representedObject as? Int64
    presentNewFolderSheet(parentId: parentId)
  }
  @objc private func menuImport(_ sender: NSMenuItem) {
    let parentId = sender.representedObject as? Int64
    presentImportPanel(parentId: parentId)
  }
  @objc private func menuExport(_ sender: NSMenuItem) {
    let parentId = sender.representedObject as? Int64
    presentExportPanel(parentId: parentId)
  }
}

// MARK: - Sheet presenters

extension BookmarksSidebarView {

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

  /// File picker + post-import summary toast for `Import…`. The
  /// panel filters to `.html` (and the legacy `.htm`) since the
  /// Netscape Bookmark File Format is the only thing this code path
  /// understands. Files outside that filter are still selectable via
  /// the panel's `Open Any File` toggle, but the parser will return
  /// an empty array for anything that isn't a `<DL>`-based document.
  fileprivate func presentImportPanel(parentId: Int64?) {
    guard let window else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.html]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.title = "Import Bookmarks"
    panel.prompt = "Import"
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .OK, let url = panel.url else { return }
      MainActor.assumeIsolated {
        self.runImport(from: url, parentId: parentId)
      }
    }
  }

  private func runImport(from url: URL, parentId: Int64?) {
    // UTF-8 only — Latin-1 would silently "succeed" on any byte
    // sequence and mojibake Shift_JIS / EUC-JP exports into the
    // store with no visible failure. Every modern browser emits
    // UTF-8 by default and stamps `<META charset=UTF-8>` into the
    // preamble; an exotic legacy encoding falls outside what this
    // importer covers.
    guard let data = try? Data(contentsOf: url),
      let html = String(data: data, encoding: .utf8)
    else {
      presentImportError(
        message: "The selected file couldn't be read or wasn't UTF-8 encoded.")
      return
    }
    let parsed = NetscapeBookmarksParser.parse(html)
    if parsed.isEmpty {
      presentImportError(
        message: "No bookmarks were found in the file. The Netscape "
          + "Bookmark File Format (\u{201C}Export Bookmarks\u{201D} from a "
          + "browser) is the only format supported.")
      return
    }
    let result = BookmarksImporter.importDocument(
      parsed, into: bookmarks, underParent: parentId)
    presentImportSummary(result: result)
  }

  private func presentImportSummary(result: BookmarksImporter.Result) {
    guard let window else { return }
    let alert = NSAlert()
    alert.messageText = "Bookmarks imported"
    var message =
      "Added \(result.bookmarks) bookmark\(result.bookmarks == 1 ? "" : "s") "
      + "in \(result.folders) folder\(result.folders == 1 ? "" : "s")."
    if result.skipped > 0 {
      // Skips fold together two distinct cases — entries the importer
      // rejected up front (disallowed `javascript:` / `data:` URLs)
      // and entries the store refused (prepare/step failures). Point
      // the user at Console.app so the unified-log entries from
      // `Bookmarks` and `BookmarksImport` are findable.
      message += " \(result.skipped) skipped (see Console.app for details)."
    }
    alert.informativeText = message
    alert.beginSheetModal(for: window, completionHandler: nil)
  }

  private func presentImportError(message: String) {
    guard let window else { return }
    let alert = NSAlert()
    alert.messageText = "Could not import bookmarks"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.beginSheetModal(for: window, completionHandler: nil)
  }

  /// Save panel for `Export…`. The default filename derives from
  /// the clicked folder's title (or `bookmarks.html` for a root
  /// export) so a multi-folder workflow doesn't collide on every
  /// save. The actual write writes the rendered HTML as UTF-8.
  fileprivate func presentExportPanel(parentId: Int64?) {
    guard let window else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.html]
    panel.canCreateDirectories = true
    panel.title = "Export Bookmarks"
    panel.prompt = "Export"
    panel.nameFieldStringValue = defaultExportFilename(parentId: parentId)
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .OK, let url = panel.url else { return }
      MainActor.assumeIsolated {
        self.runExport(to: url, parentId: parentId)
      }
    }
  }

  private func defaultExportFilename(parentId: Int64?) -> String {
    // Date-stamped filename so successive exports stack up in the
    // user's Downloads / chosen folder instead of overwriting each
    // other. When the user exports a specific subtree, the folder's
    // title (sanitised) is woven in so multiple per-folder exports
    // on the same day don't collide. `en_US_POSIX` keeps the format
    // stable across the user's locale settings.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd"
    let date = formatter.string(from: Date())
    if let parentId, let folder = nodesById[parentId] {
      let slug = filenameSlug(folder.entry.title)
      if !slug.isEmpty { return "bookmarks_\(slug)_\(date).html" }
    }
    return "bookmarks_\(date).html"
  }

  /// Make a folder title safe to embed in a save-panel default
  /// filename. Replaces filesystem-hostile characters (`/`, `\`, `:`,
  /// NUL) with `_`, collapses runs of `_`, and trims edge underscores.
  /// Unicode (CJK, accented letters) passes through — macOS HFS+ /
  /// APFS accept it, and a `Daily_Reports` vs `日報` distinction is
  /// the whole point of weaving the title in.
  private func filenameSlug(_ s: String) -> String {
    var out = ""
    var lastWasUnderscore = false
    for char in s {
      if char == "/" || char == "\\" || char == ":" || char == "\0" {
        if !out.isEmpty, !lastWasUnderscore {
          out.append("_")
          lastWasUnderscore = true
        }
        continue
      }
      out.append(char)
      lastWasUnderscore = char == "_"
    }
    return out.trimmingCharacters(
      in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "_")))
  }

  private func runExport(to url: URL, parentId: Int64?) {
    let html = NetscapeBookmarksWriter.render(bookmarks, underParent: parentId)
    do {
      try html.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      presentExportError(message: error.localizedDescription)
    }
  }

  private func presentExportError(message: String) {
    guard let window else { return }
    let alert = NSAlert()
    alert.messageText = "Could not export bookmarks"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.beginSheetModal(for: window, completionHandler: nil)
  }
}

// MARK: - Bookmark cell

/// Compact two-line cell for a leaf bookmark: title on top (label
/// color) and host on the bottom (secondary). Transparent
/// background so the Liquid Glass sidebar remains visible through
/// the row. Per-row actions live on the parent view's context menu.
private final class BookmarksSidebarBookmarkCellView: SidebarListCellView {
  static let height: CGFloat = 40
  static let iconSize: CGFloat = 16

  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let hostLabel = NSTextField(labelWithString: "")

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

    addSubview(iconView)
    addSubview(titleLabel)
    addSubview(hostLabel)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

      hostLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
      hostLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      hostLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
    ])
  }

  func configure(with entry: Bookmarks.Entry) {
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
}

// MARK: - Folder cell

/// Single-line cell for a folder row: folder icon + title. The
/// outline view draws its own disclosure triangle on the leading
/// edge, and per-folder actions live on the parent view's context
/// menu.
private final class BookmarksSidebarFolderCellView: SidebarListCellView {
  static let height: CGFloat = 28
  static let iconSize: CGFloat = 14

  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")

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

    addSubview(iconView)
    addSubview(titleLabel)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

      titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  func configure(with entry: Bookmarks.Entry) {
    titleLabel.stringValue = entry.title.isEmpty ? "Untitled folder" : entry.title
    titleLabel.toolTip = entry.title.isEmpty ? nil : entry.title
  }
}
