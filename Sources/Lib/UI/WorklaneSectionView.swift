import AppKit
import os.log

private let logger = Logger(
  subsystem: "com.kawarimidoll.e05", category: "Worklane")

/// userInfo key AppKit ships in the
/// `NSOutlineViewItemDidExpand/Collapse` notifications. Hard-coded as
/// a raw string in AppKit headers; pulled out into a constant so a
/// future SDK rename surfaces as a single compile-time fix rather
/// than a silent state-sync break.
private let outlineViewItemUserInfoKey = "NSObject"

/// Item identity for the worklane outline view. NSOutlineView tracks
/// expansion / selection state by `isEqual:`, so wrapping each row in
/// a reference type with id-based equality lets reload reuse the same
/// objects without losing AppKit's per-item state. Mutable fields
/// (`model`, `index`) let an in-place model swap land without
/// invalidating outline-view bookkeeping.
@MainActor
final class WorklaneWorkspaceNode: NSObject {
  let id: ULID
  fileprivate(set) var model: WorkspaceModel
  /// Position in the container's `workspaces` array. Drives the
  /// accent color and the "Workspace N" label. Updates on reload
  /// rather than being treated as immutable so workspace deletion
  /// in the middle of the list doesn't drop the wrong row.
  fileprivate(set) var index: Int

  init(model: WorkspaceModel, index: Int) {
    self.id = model.id
    self.model = model
    self.index = index
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? WorklaneWorkspaceNode else { return false }
    return id == other.id
  }
  override var hash: Int { id.hashValue }
}

@MainActor
final class WorklanePaneNode: NSObject {
  let id: ULID
  fileprivate(set) var model: PaneModel
  /// Workspace this pane lives in. Looked up by the cell view to
  /// resolve accent color and the workspace's private flag without
  /// re-querying the container.
  fileprivate(set) weak var workspaceNode: WorklaneWorkspaceNode?

  init(model: PaneModel, workspaceNode: WorklaneWorkspaceNode) {
    self.id = model.id
    self.model = model
    self.workspaceNode = workspaceNode
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? WorklanePaneNode else { return false }
    return id == other.id
  }
  override var hash: Int { id.hashValue }
}

/// Row view that pins `isEmphasized` to `false` so the selection
/// highlight stays its calm translucent gray instead of flashing
/// system blue whenever the sidebar holds first responder. Matches
/// the visual idiom of the other sidebar modes (`SidebarListRowView`)
/// without inheriting the hover-to-select behaviour those modes use.
@MainActor
final class WorklaneRowView: NSTableRowView {
  override var isEmphasized: Bool {
    get { false }
    set {}
  }
}

/// Sidebar worklane section: an outline view listing every workspace
/// (group rows) and its panes (child rows). Replaces the earlier
/// NSStackView-with-rebuild design — `NSOutlineView` realises only the
/// visible rows, recycles cell views across reloads, and supplies free
/// expand/collapse animations through `expandItem(_:)` /
/// `collapseItem(_:)`.
///
/// Sized to live inside the Liquid Glass sidebar overlay: transparent
/// background, source-list selection style so the focused pane wears
/// AppKit's native sidebar highlight.
@MainActor
final class WorklaneSectionView: NSView {
  private let scrollView = NSScrollView()
  private let outlineView = NSOutlineView()

  /// Top-level rows. Outline view asks for these when item is nil.
  private var workspaceNodes: [WorklaneWorkspaceNode] = []
  /// Children of each workspace keyed by workspace id.
  private var panesByWorkspaceId: [ULID: [WorklanePaneNode]] = [:]
  /// Lookup so targeted state updates (audio / suspended) can resolve
  /// a node from a pane id without walking the tree.
  private var nodesByPaneId: [ULID: WorklanePaneNode] = [:]
  private var nodesByWorkspaceId: [ULID: WorklaneWorkspaceNode] = [:]

  /// Most recent reload input. Cell views fetch the live closures
  /// (onClick / onClose / accentColor lookup) from here so the input
  /// doesn't need to be threaded through every cell vend.
  private var lastInput: ReloadInput?

  /// Guards the selection-sync path so programmatic selection during
  /// reload doesn't fire `onPaneClick` and re-enter the focus flow.
  private var isSyncingSelection = false

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setupLayout() {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("worklane"))
    column.resizingMask = .autoresizingMask
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column
    outlineView.headerView = nil
    outlineView.backgroundColor = .clear
    outlineView.rowSizeStyle = .custom
    outlineView.intercellSpacing = NSSize(width: 0, height: 2)
    // Regular selection style for the focused pane (AppKit paints a
    // system accent fill on selection). Group rows (workspace
    // headers) are still non-selectable via our `shouldSelectItem`
    // delegate, so workspace clicks fall through to the cell view's
    // own mouseDown handler. `.plain` style keeps the outline view's
    // background transparent so the Liquid Glass sidebar remains
    // visible behind the rows.
    outlineView.selectionHighlightStyle = .regular
    outlineView.allowsEmptySelection = true
    outlineView.allowsMultipleSelection = false
    outlineView.style = .plain
    outlineView.indentationPerLevel = 8
    outlineView.indentationMarkerFollowsCell = true
    outlineView.autoresizesOutlineColumn = false
    // Group rows shouldn't stick to the top during scroll — the
    // worklane is short enough that fixed-position headers compete
    // with the "Workspace N" labels reading as part of the flat list.
    outlineView.floatsGroupRows = false
    outlineView.dataSource = self
    outlineView.delegate = self

    scrollView.documentView = outlineView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.verticalScrollElasticity = .allowed
    scrollView.horizontalScrollElasticity = .none
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scrollView)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  /// Input bundle for `reload(_:)`. All closures are expected to run
  /// on the main actor synchronously — `ReloadInput` is not Sendable
  /// and should not be stashed across actor hops.
  struct ReloadInput {
    let workspaces: [WorkspaceModel]
    let focusedWorkspaceIndex: Int
    let focusedPaneId: ULID?
    let accentColor: (Int) -> NSColor
    let paneTitle: (PaneModel) -> String
    let paneIcon: (PaneModel) -> NSImage?
    let paneAudioState:
      (PaneModel) -> (isMuted: Bool, isPlayingAudio: Bool, hasActiveMedia: Bool)
    let paneIsSuspended: (PaneModel) -> Bool
    let isWorkspaceCollapsed: (ULID) -> Bool
    let onWorkspaceClick: (Int) -> Void
    let onPaneClick: (ULID) -> Void
    let onWorkspaceClose: (Int) -> Void
    let onPaneClose: (ULID) -> Void
    let onPaneAudioToggle: (ULID) -> Void
    let onWorkspaceToggleCollapse: (ULID) -> Void
  }

  func reload(_ input: ReloadInput) {
    lastInput = input
    rebuildNodeTree(from: input)
    outlineView.reloadData()
    applyPersistedCollapseState(input: input)
    syncSelection(to: input.focusedPaneId)
  }

  /// Per-pane audio update without a full reload. Looks up the row's
  /// currently-mounted cell, if any, and forwards. Off-screen rows
  /// pick up the latest state from the next `viewFor:` vend.
  func updatePaneAudioState(
    paneId: ULID, isMuted: Bool, isPlayingAudio: Bool, hasActiveMedia: Bool
  ) {
    guard let cell = visibleCell(forPaneId: paneId) else { return }
    cell.applyAudioState(
      isMuted: isMuted, isPlayingAudio: isPlayingAudio,
      hasActiveMedia: hasActiveMedia)
  }

  /// Per-pane suspended-state flip without a full reload.
  func updatePaneSuspendedState(paneId: ULID, isSuspended: Bool) {
    visibleCell(forPaneId: paneId)?.applySuspendedState(isSuspended)
  }

  private func visibleCell(forPaneId paneId: ULID) -> WorklanePaneCellView? {
    guard let node = nodesByPaneId[paneId] else { return nil }
    let row = outlineView.row(forItem: node)
    guard row >= 0 else { return nil }
    return outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
      as? WorklanePaneCellView
  }

  // MARK: - Node tree

  private func rebuildNodeTree(from input: ReloadInput) {
    var newWorkspaces: [WorklaneWorkspaceNode] = []
    var newWorkspaceLookup: [ULID: WorklaneWorkspaceNode] = [:]
    var newPanes: [ULID: [WorklanePaneNode]] = [:]
    var newPaneLookup: [ULID: WorklanePaneNode] = [:]

    for (idx, model) in input.workspaces.enumerated() {
      let node: WorklaneWorkspaceNode
      if let existing = nodesByWorkspaceId[model.id] {
        existing.model = model
        existing.index = idx
        node = existing
      } else {
        node = WorklaneWorkspaceNode(model: model, index: idx)
      }
      newWorkspaces.append(node)
      newWorkspaceLookup[model.id] = node

      var paneNodes: [WorklanePaneNode] = []
      for column in model.columns {
        for pane in column.panes {
          let paneNode: WorklanePaneNode
          if let existing = nodesByPaneId[pane.id] {
            existing.model = pane
            existing.workspaceNode = node
            paneNode = existing
          } else {
            paneNode = WorklanePaneNode(model: pane, workspaceNode: node)
          }
          paneNodes.append(paneNode)
          newPaneLookup[pane.id] = paneNode
        }
      }
      newPanes[model.id] = paneNodes
    }

    workspaceNodes = newWorkspaces
    nodesByWorkspaceId = newWorkspaceLookup
    panesByWorkspaceId = newPanes
    nodesByPaneId = newPaneLookup
  }

  /// AppKit defaults every row to expanded after `reloadData`. Walk
  /// the workspace list and align the outline view's expansion state
  /// to the persisted set so a reload doesn't lose the user's
  /// collapse choices.
  private func applyPersistedCollapseState(input: ReloadInput) {
    for node in workspaceNodes {
      let shouldBeCollapsed = input.isWorkspaceCollapsed(node.id)
      let isExpanded = outlineView.isItemExpanded(node)
      if shouldBeCollapsed, isExpanded {
        outlineView.collapseItem(node)
      } else if !shouldBeCollapsed, !isExpanded {
        outlineView.expandItem(node)
      }
    }
  }

  /// Mirror the container's focused pane onto the outline view's
  /// selection so the source-list highlight stays in sync with focus
  /// changes driven from outside the worklane (palette, keyboard
  /// shortcuts, IPC).
  private func syncSelection(to focusedPaneId: ULID?) {
    guard let focusedPaneId, let node = nodesByPaneId[focusedPaneId]
    else {
      isSyncingSelection = true
      outlineView.deselectAll(nil)
      isSyncingSelection = false
      return
    }
    let row = outlineView.row(forItem: node)
    guard row >= 0 else { return }
    isSyncingSelection = true
    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    outlineView.scrollRowToVisible(row)
    isSyncingSelection = false
  }
}

// MARK: - NSOutlineViewDataSource

extension WorklaneSectionView: NSOutlineViewDataSource {
  func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    if item == nil { return workspaceNodes.count }
    guard let ws = item as? WorklaneWorkspaceNode else { return 0 }
    return panesByWorkspaceId[ws.id]?.count ?? 0
  }

  func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    if item == nil {
      if workspaceNodes.indices.contains(index) {
        return workspaceNodes[index]
      }
      logger.error(
        """
        [worklane/data] root child miss idx=\(index, privacy: .public) \
        count=\(self.workspaceNodes.count, privacy: .public)
        """)
      assertionFailure("[worklane/data] root child miss")
      // Release-mode fallback: hand back the closest existing node so
      // AppKit doesn't crash mid-batch. The cell will render in the
      // wrong slot but the app survives until the next reload.
      return workspaceNodes.first as Any? ?? NSNull()
    }
    if let ws = item as? WorklaneWorkspaceNode,
      let panes = panesByWorkspaceId[ws.id],
      panes.indices.contains(index)
    {
      return panes[index]
    }
    logger.error(
      """
      [worklane/data] pane child miss item=\(String(describing: item), privacy: .public) \
      idx=\(index, privacy: .public)
      """)
    assertionFailure("[worklane/data] pane child miss")
    return (item as? WorklaneWorkspaceNode) ?? NSNull()
  }

  func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
    item is WorklaneWorkspaceNode
  }
}

// MARK: - NSOutlineViewDelegate

extension WorklaneSectionView: NSOutlineViewDelegate {
  func outlineView(_: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
    if item is WorklaneWorkspaceNode { return WorklaneWorkspaceCellView.height }
    return WorklanePaneCellView.height
  }

  /// Substitute a non-emphasised row view so the selection highlight
  /// stays its calm translucent gray instead of flashing system blue
  /// while the sidebar holds first responder. Mirrors the row view
  /// the bookmarks / history / downloads modes already use; declared
  /// separately so worklane doesn't inherit those modes' hover-select
  /// behaviour.
  func outlineView(_: NSOutlineView, rowViewForItem _: Any) -> NSTableRowView? {
    WorklaneRowView()
  }

  func outlineView(
    _ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any
  ) -> NSView? {
    guard let input = lastInput else { return nil }
    if let ws = item as? WorklaneWorkspaceNode {
      let id = NSUserInterfaceItemIdentifier("WorklaneWorkspaceCell")
      let cell =
        outlineView.makeView(withIdentifier: id, owner: self)
        as? WorklaneWorkspaceCellView
        ?? WorklaneWorkspaceCellView(identifier: id)
      cell.configure(node: ws, input: input)
      return cell
    }
    if let pane = item as? WorklanePaneNode {
      let id = NSUserInterfaceItemIdentifier("WorklanePaneCell")
      let cell =
        outlineView.makeView(withIdentifier: id, owner: self)
        as? WorklanePaneCellView
        ?? WorklanePaneCellView(identifier: id)
      cell.configure(
        node: pane, input: input, focusedPaneId: input.focusedPaneId)
      return cell
    }
    return nil
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    guard !isSyncingSelection, let input = lastInput else { return }
    let row = outlineView.selectedRow
    guard row >= 0, let item = outlineView.item(atRow: row) else { return }
    if let pane = item as? WorklanePaneNode {
      input.onPaneClick(pane.id)
    } else if let ws = item as? WorklaneWorkspaceNode {
      // Workspace selection is transient: the upcoming
      // switchWorkspace reload re-targets selection to the new
      // workspace's focused pane, so the highlight flashes off the
      // header and lands on a pane row in a single visual tick.
      input.onWorkspaceClick(ws.index)
    }
  }

  func outlineViewItemDidExpand(_ notification: Notification) {
    guard let input = lastInput,
      let node = notification.userInfo?[outlineViewItemUserInfoKey]
        as? WorklaneWorkspaceNode
    else { return }
    if input.isWorkspaceCollapsed(node.id) {
      input.onWorkspaceToggleCollapse(node.id)
    }
  }

  func outlineViewItemDidCollapse(_ notification: Notification) {
    guard let input = lastInput,
      let node = notification.userInfo?[outlineViewItemUserInfoKey]
        as? WorklaneWorkspaceNode
    else { return }
    if !input.isWorkspaceCollapsed(node.id) {
      input.onWorkspaceToggleCollapse(node.id)
    }
  }
}
