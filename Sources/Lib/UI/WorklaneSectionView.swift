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

/// Outline-view wrapper for a multi-pane column. Single-pane columns
/// are exposed as their pane directly under the workspace; only
/// columns with two or more panes get this group-style intermediate
/// node, so the column dimension stays out of sight when it isn't
/// load-bearing.
@MainActor
final class WorklaneColumnNode: NSObject {
  let id: ULID
  fileprivate(set) var model: ColumnModel
  fileprivate(set) weak var workspaceNode: WorklaneWorkspaceNode?

  init(model: ColumnModel, workspaceNode: WorklaneWorkspaceNode) {
    self.id = model.id
    self.model = model
    self.workspaceNode = workspaceNode
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? WorklaneColumnNode else { return false }
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
  /// Column wrapper this pane sits inside, when the pane is part of
  /// a multi-pane column. `nil` when the pane is a single-pane
  /// column exposed directly under the workspace.
  fileprivate(set) weak var columnNode: WorklaneColumnNode?

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

/// Sidebar worklane section: a three-level outline view listing every
/// workspace, the columns inside it (only when they hold two or more
/// panes), and the panes themselves. NSOutlineView realises only the
/// visible rows, recycles cell views across reloads, and supplies
/// expand/collapse animations through `expandItem(_:)` /
/// `collapseItem(_:)`.
///
/// Sized to live inside the Liquid Glass sidebar overlay: transparent
/// background, regular selection style with a non-emphasised row view
/// so the focused pane wears a calm translucent highlight.
@MainActor
final class WorklaneSectionView: NSView {
  private let scrollView = NSScrollView()
  private let outlineView = NSOutlineView()

  /// Top-level rows. Outline view asks for these when item is nil.
  private var workspaceNodes: [WorklaneWorkspaceNode] = []
  /// Workspace-level children. Each entry is either a `WorklanePaneNode`
  /// (single-pane column exposed flat) or a `WorklaneColumnNode`
  /// (multi-pane column wrapper). Keyed by workspace id.
  private var topLevelChildrenByWorkspaceId: [ULID: [AnyObject]] = [:]
  /// Panes contained inside each multi-pane column wrapper.
  private var panesByColumnId: [ULID: [WorklanePaneNode]] = [:]
  /// Lookups so targeted state updates (audio / suspended) can
  /// resolve a node from a model id without walking the tree.
  private var nodesByPaneId: [ULID: WorklanePaneNode] = [:]
  private var nodesByColumnId: [ULID: WorklaneColumnNode] = [:]
  private var nodesByWorkspaceId: [ULID: WorklaneWorkspaceNode] = [:]

  /// Most recent reload input. Cell views fetch the live closures
  /// (onClick / onClose / accentColor lookup) from here so the input
  /// doesn't need to be threaded through every cell vend.
  private var lastInput: ReloadInput?

  /// Guards the selection-sync path so programmatic selection during
  /// reload doesn't fire `onPaneClick` and re-enter the focus flow.
  private var isSyncingSelection = false

  /// Snapshot of the previous reload's tree shape, used to compute
  /// the structural diff against the new input. `nil` before the
  /// first reload — the bootstrap reload uses `reloadData` since
  /// there's nothing to animate against an empty starting state.
  private var lastSnapshot: WorklaneSnapshot?

  private struct WorklaneSnapshot {
    let workspaceIds: [ULID]
    /// Workspace-level child ids per workspace. Each id is either a
    /// pane ULID or a column ULID; collisions are ruled out by
    /// ULID's 80 random bits, so a single flat list per workspace
    /// is unambiguous.
    let topLevelChildIdsByWorkspaceId: [ULID: [ULID]]
    /// Pane ids per multi-pane column. Single-pane columns aren't
    /// represented here — their pane appears at workspace top level.
    let panesByColumnId: [ULID: [ULID]]
  }

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
    // Regular selection style for the focused pane (paired with
    // `WorklaneRowView`'s `isEmphasized = false` to render the
    // translucent gray instead of system blue). `.plain` style
    // keeps the outline view's background transparent so the
    // Liquid Glass sidebar remains visible behind the rows.
    outlineView.selectionHighlightStyle = .regular
    outlineView.allowsEmptySelection = true
    outlineView.allowsMultipleSelection = false
    outlineView.style = .plain
    outlineView.indentationPerLevel = 8
    outlineView.indentationMarkerFollowsCell = true
    outlineView.autoresizesOutlineColumn = false
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
    /// Persisted collapse predicate. Receives either a workspace or
    /// a column ULID — NSOutlineView treats both as expandable items
    /// and the persistence layer carries one merged set of ids.
    let isCollapsed: (ULID) -> Bool
    let onWorkspaceClick: (Int) -> Void
    let onPaneClick: (ULID) -> Void
    let onWorkspaceClose: (Int) -> Void
    let onPaneClose: (ULID) -> Void
    let onPaneAudioToggle: (ULID) -> Void
    /// Flip the persisted collapse state for the given item id
    /// (workspace or column).
    let onToggleCollapse: (ULID) -> Void
  }

  func reload(_ input: ReloadInput) {
    lastInput = input
    rebuildNodeTree(from: input)
    let snapshot = currentSnapshot()
    if let previous = lastSnapshot {
      applyDiff(from: previous, to: snapshot)
    } else {
      outlineView.reloadData()
    }
    lastSnapshot = snapshot
    applyPersistedCollapseState(input: input)
    syncSelection(to: input.focusedPaneId)
  }

  private func currentSnapshot() -> WorklaneSnapshot {
    var topLevel: [ULID: [ULID]] = [:]
    for (wsId, children) in topLevelChildrenByWorkspaceId {
      topLevel[wsId] = children.map { topLevelChildId($0) }
    }
    var panes: [ULID: [ULID]] = [:]
    for (columnId, nodes) in panesByColumnId {
      panes[columnId] = nodes.map(\.id)
    }
    return WorklaneSnapshot(
      workspaceIds: workspaceNodes.map(\.id),
      topLevelChildIdsByWorkspaceId: topLevel,
      panesByColumnId: panes
    )
  }

  private func topLevelChildId(_ node: AnyObject) -> ULID {
    if let column = node as? WorklaneColumnNode { return column.id }
    if let pane = node as? WorklanePaneNode { return pane.id }
    fatalError("[worklane] unexpected top-level child type: \(type(of: node))")
  }

  /// Walk the diff between two snapshots and translate it into
  /// `insertItems` / `removeItems` calls so AppKit animates structural
  /// changes. Still-present rows get a follow-up `reloadItem` so
  /// content that depends on position (workspace accent color,
  /// focused-pane dot) stays in sync when a sibling row was added or
  /// removed without changing this row's own identity.
  ///
  /// Pure reorder of survivors (same id set, different order — e.g.
  /// `moveColumnLeft/Right`, `movePaneUp/Down`) bypasses the diff
  /// path and falls back to `reloadData`. The animated route would
  /// need `moveItem(at:inParent:to:inParent:)`, whose batched-update
  /// index semantics around mixed insert/remove are subtle enough
  /// that giving up the animation for this one operation keeps the
  /// data source and AppKit's internal index space in lockstep.
  private func applyDiff(
    from old: WorklaneSnapshot, to new: WorklaneSnapshot
  ) {
    if diffPathUnsafe(old: old, new: new) {
      outlineView.reloadData()
      return
    }
    outlineView.beginUpdates()
    // Root level: workspaces
    diffChildren(
      oldIds: old.workspaceIds, newIds: new.workspaceIds, parent: nil)
    // Workspace level: each workspace's top-level children (mix of
    // pane and column wrappers).
    let stillPresentWs = Set(old.workspaceIds).intersection(new.workspaceIds)
    for wsId in stillPresentWs {
      diffChildren(
        oldIds: old.topLevelChildIdsByWorkspaceId[wsId] ?? [],
        newIds: new.topLevelChildIdsByWorkspaceId[wsId] ?? [],
        parent: nodesByWorkspaceId[wsId]
      )
    }
    // Column level: each surviving multi-pane column's panes.
    let stillPresentColumns =
      Set(old.panesByColumnId.keys).intersection(new.panesByColumnId.keys)
    for columnId in stillPresentColumns {
      diffChildren(
        oldIds: old.panesByColumnId[columnId] ?? [],
        newIds: new.panesByColumnId[columnId] ?? [],
        parent: nodesByColumnId[columnId]
      )
    }
    outlineView.endUpdates()

    // Re-vend the cells for surviving rows so the accent color
    // (derived from workspace index) and the focus dot (derived from
    // focusedPaneId) reflect the latest input. Newly-inserted and
    // newly-removed rows are skipped — the insert path already
    // configures from current state, the remove path leaves nothing
    // behind to refresh.
    for wsId in stillPresentWs {
      if let wsNode = nodesByWorkspaceId[wsId] {
        outlineView.reloadItem(wsNode)
      }
      let survivingTopLevel = Set(old.topLevelChildIdsByWorkspaceId[wsId] ?? [])
      for childId in new.topLevelChildIdsByWorkspaceId[wsId] ?? []
      where survivingTopLevel.contains(childId) {
        if let column = nodesByColumnId[childId] {
          outlineView.reloadItem(column)
        } else if let pane = nodesByPaneId[childId] {
          outlineView.reloadItem(pane)
        }
      }
    }
    for columnId in stillPresentColumns {
      let survivingPanes = Set(old.panesByColumnId[columnId] ?? [])
      for paneId in new.panesByColumnId[columnId] ?? []
      where survivingPanes.contains(paneId) {
        if let pane = nodesByPaneId[paneId] {
          outlineView.reloadItem(pane)
        }
      }
    }
  }

  /// True when the diff path can't faithfully animate the change.
  /// Two conditions trigger the `reloadData` fallback:
  ///
  /// 1. Surviving ids reorder (`insertItems` / `removeItems` can
  ///    only express add and remove, not move).
  /// 2. A surviving pane changes parent — e.g. a column shrinks to
  ///    one pane (column wrapper removed, pane re-parented to the
  ///    workspace) or expands from one to two (pane re-parented
  ///    into a fresh column wrapper). AppKit's batched-update API
  ///    treats the pane's old position as gone and the new position
  ///    as fresh; the same `NSObject` showing up under two parents
  ///    mid-batch is undefined territory.
  private func diffPathUnsafe(
    old: WorklaneSnapshot, new: WorklaneSnapshot
  ) -> Bool {
    if survivorOrderChanged(oldIds: old.workspaceIds, newIds: new.workspaceIds) {
      return true
    }
    let stillPresentWs = Set(old.workspaceIds).intersection(new.workspaceIds)
    for wsId in stillPresentWs {
      if survivorOrderChanged(
        oldIds: old.topLevelChildIdsByWorkspaceId[wsId] ?? [],
        newIds: new.topLevelChildIdsByWorkspaceId[wsId] ?? [])
      {
        return true
      }
    }
    let stillPresentColumns =
      Set(old.panesByColumnId.keys).intersection(new.panesByColumnId.keys)
    for columnId in stillPresentColumns {
      if survivorOrderChanged(
        oldIds: old.panesByColumnId[columnId] ?? [],
        newIds: new.panesByColumnId[columnId] ?? [])
      {
        return true
      }
    }
    return paneParentChanged(old: old, new: new)
  }

  /// True when a pane id present in both snapshots has a different
  /// parent (workspace direct child vs column child, or two
  /// different column ids). Detects the single↔multi column
  /// transition that re-parents the surviving pane.
  private func paneParentChanged(
    old: WorklaneSnapshot, new: WorklaneSnapshot
  ) -> Bool {
    let oldParents = paneParents(snapshot: old)
    let newParents = paneParents(snapshot: new)
    for (paneId, oldParent) in oldParents {
      if let newParent = newParents[paneId], newParent != oldParent {
        return true
      }
    }
    return false
  }

  /// Build a map of pane id → parent id (workspace id when the pane
  /// sits flat under the workspace, column id when it sits inside a
  /// multi-pane column wrapper).
  private func paneParents(snapshot: WorklaneSnapshot) -> [ULID: ULID] {
    var result: [ULID: ULID] = [:]
    let columnIds = Set(snapshot.panesByColumnId.keys)
    for (wsId, childIds) in snapshot.topLevelChildIdsByWorkspaceId {
      for childId in childIds where !columnIds.contains(childId) {
        result[childId] = wsId
      }
    }
    for (columnId, paneIds) in snapshot.panesByColumnId {
      for paneId in paneIds {
        result[paneId] = columnId
      }
    }
    return result
  }

  private func survivorOrderChanged(
    oldIds: [ULID], newIds: [ULID]
  ) -> Bool {
    let oldSet = Set(oldIds)
    let newSet = Set(newIds)
    let survivedInOldOrder = oldIds.filter { newSet.contains($0) }
    let survivedInNewOrder = newIds.filter { oldSet.contains($0) }
    return survivedInOldOrder != survivedInNewOrder
  }

  private func diffChildren(
    oldIds: [ULID], newIds: [ULID], parent: Any?
  ) {
    let oldSet = Set(oldIds)
    let newSet = Set(newIds)

    let removeIndexes = IndexSet(
      oldIds.enumerated().compactMap {
        newSet.contains($0.element) ? nil : $0.offset
      })
    if !removeIndexes.isEmpty {
      outlineView.removeItems(
        at: removeIndexes, inParent: parent,
        withAnimation: .effectFade)
    }

    let insertIndexes = IndexSet(
      newIds.enumerated().compactMap {
        oldSet.contains($0.element) ? nil : $0.offset
      })
    if !insertIndexes.isEmpty {
      outlineView.insertItems(
        at: insertIndexes, inParent: parent,
        withAnimation: .effectFade)
    }
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
    var newTopLevel: [ULID: [AnyObject]] = [:]
    var newColumnLookup: [ULID: WorklaneColumnNode] = [:]
    var newColumnPanes: [ULID: [WorklanePaneNode]] = [:]
    var newPaneLookup: [ULID: WorklanePaneNode] = [:]

    for (idx, model) in input.workspaces.enumerated() {
      let wsNode: WorklaneWorkspaceNode
      if let existing = nodesByWorkspaceId[model.id] {
        existing.model = model
        existing.index = idx
        wsNode = existing
      } else {
        wsNode = WorklaneWorkspaceNode(model: model, index: idx)
      }
      newWorkspaces.append(wsNode)
      newWorkspaceLookup[model.id] = wsNode

      var topLevel: [AnyObject] = []
      for column in model.columns {
        if column.panes.count == 1, let pane = column.panes.first {
          // Single-pane column collapses away — pane sits directly
          // under the workspace as a top-level row.
          let paneNode = reusePaneNode(
            for: pane, workspaceNode: wsNode, columnNode: nil)
          topLevel.append(paneNode)
          newPaneLookup[pane.id] = paneNode
        } else {
          let columnNode: WorklaneColumnNode
          if let existing = nodesByColumnId[column.id] {
            existing.model = column
            existing.workspaceNode = wsNode
            columnNode = existing
          } else {
            columnNode = WorklaneColumnNode(model: column, workspaceNode: wsNode)
          }
          var paneNodes: [WorklanePaneNode] = []
          for pane in column.panes {
            let paneNode = reusePaneNode(
              for: pane, workspaceNode: wsNode, columnNode: columnNode)
            paneNodes.append(paneNode)
            newPaneLookup[pane.id] = paneNode
          }
          topLevel.append(columnNode)
          newColumnLookup[column.id] = columnNode
          newColumnPanes[column.id] = paneNodes
        }
      }
      newTopLevel[model.id] = topLevel
    }

    workspaceNodes = newWorkspaces
    nodesByWorkspaceId = newWorkspaceLookup
    topLevelChildrenByWorkspaceId = newTopLevel
    nodesByColumnId = newColumnLookup
    panesByColumnId = newColumnPanes
    nodesByPaneId = newPaneLookup
  }

  private func reusePaneNode(
    for pane: PaneModel,
    workspaceNode: WorklaneWorkspaceNode,
    columnNode: WorklaneColumnNode?
  ) -> WorklanePaneNode {
    if let existing = nodesByPaneId[pane.id] {
      existing.model = pane
      existing.workspaceNode = workspaceNode
      existing.columnNode = columnNode
      return existing
    }
    let node = WorklanePaneNode(model: pane, workspaceNode: workspaceNode)
    node.columnNode = columnNode
    return node
  }

  /// AppKit defaults every row to expanded after `reloadData`. Walk
  /// the workspace + column nodes and align the outline view's
  /// expansion state to the persisted set so a reload doesn't lose
  /// the user's collapse choices.
  private func applyPersistedCollapseState(input: ReloadInput) {
    for wsNode in workspaceNodes {
      applyCollapseState(wsNode, shouldBeCollapsed: input.isCollapsed(wsNode.id))
      for child in topLevelChildrenByWorkspaceId[wsNode.id] ?? [] {
        guard let columnNode = child as? WorklaneColumnNode else { continue }
        applyCollapseState(
          columnNode, shouldBeCollapsed: input.isCollapsed(columnNode.id))
      }
    }
  }

  private func applyCollapseState(_ item: Any, shouldBeCollapsed: Bool) {
    let isExpanded = outlineView.isItemExpanded(item)
    if shouldBeCollapsed, isExpanded {
      outlineView.collapseItem(item)
    } else if !shouldBeCollapsed, !isExpanded {
      outlineView.expandItem(item)
    }
  }

  /// Mirror the container's focused pane onto the outline view's
  /// selection so the selection highlight stays in sync with focus
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
    if let ws = item as? WorklaneWorkspaceNode {
      return topLevelChildrenByWorkspaceId[ws.id]?.count ?? 0
    }
    if let column = item as? WorklaneColumnNode {
      return panesByColumnId[column.id]?.count ?? 0
    }
    return 0
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
      return workspaceNodes.first as Any? ?? NSNull()
    }
    if let ws = item as? WorklaneWorkspaceNode,
      let children = topLevelChildrenByWorkspaceId[ws.id],
      children.indices.contains(index)
    {
      return children[index]
    }
    if let column = item as? WorklaneColumnNode,
      let panes = panesByColumnId[column.id],
      panes.indices.contains(index)
    {
      return panes[index]
    }
    logger.error(
      """
      [worklane/data] child miss item=\(String(describing: item), privacy: .public) \
      idx=\(index, privacy: .public)
      """)
    assertionFailure("[worklane/data] child miss")
    return (item as? WorklaneWorkspaceNode) ?? NSNull()
  }

  func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
    (item is WorklaneWorkspaceNode) || (item is WorklaneColumnNode)
  }
}

// MARK: - NSOutlineViewDelegate

extension WorklaneSectionView: NSOutlineViewDelegate {
  func outlineView(_: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
    if item is WorklaneWorkspaceNode { return WorklaneWorkspaceCellView.height }
    if item is WorklaneColumnNode { return WorklaneColumnCellView.height }
    return WorklanePaneCellView.height
  }

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
    if let column = item as? WorklaneColumnNode {
      let id = NSUserInterfaceItemIdentifier("WorklaneColumnCell")
      let cell =
        outlineView.makeView(withIdentifier: id, owner: self)
        as? WorklaneColumnCellView
        ?? WorklaneColumnCellView(identifier: id)
      cell.configure(node: column, input: input)
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
    } else if let column = item as? WorklaneColumnNode {
      // Column header click jumps focus onto the column's focused
      // pane — keeps "click a row = focus something concrete" as a
      // uniform rule across workspace / column / pane rows.
      if let focused = column.model.focusedPane {
        input.onPaneClick(focused.id)
      }
    } else if let ws = item as? WorklaneWorkspaceNode {
      input.onWorkspaceClick(ws.index)
    }
  }

  func outlineViewItemDidExpand(_ notification: Notification) {
    guard let input = lastInput,
      let item = notification.userInfo?[outlineViewItemUserInfoKey],
      let id = expandableItemId(item)
    else { return }
    if input.isCollapsed(id) {
      input.onToggleCollapse(id)
    }
  }

  func outlineViewItemDidCollapse(_ notification: Notification) {
    guard let input = lastInput,
      let item = notification.userInfo?[outlineViewItemUserInfoKey],
      let id = expandableItemId(item)
    else { return }
    if !input.isCollapsed(id) {
      input.onToggleCollapse(id)
    }
  }

  private func expandableItemId(_ item: Any) -> ULID? {
    if let ws = item as? WorklaneWorkspaceNode { return ws.id }
    if let column = item as? WorklaneColumnNode { return column.id }
    return nil
  }
}
