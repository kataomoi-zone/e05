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

/// Outline view subclass that swallows clicks landing on the empty
/// gutter below the last row (and the 2pt inter-row gap from
/// `intercellSpacing`) so the focused-pane highlight survives stray
/// clicks outside any row.
///
/// Why not `allowsEmptySelection = false`: that flag also turns
/// `deselectAll(_:)` into a no-op (documented AppKit behaviour),
/// which would defeat the drag-start path that clears the selection
/// to keep the drop indicator from compositing under a gray
/// selection halo. Keep empty selection allowed at the AppKit
/// level and intercept the click here instead.
///
/// Skipping `super.mouseDown` also stops responder-chain
/// propagation, so the swallowed click never reaches parent views
/// and never triggers a first-responder transfer. Worklane rows
/// route focus through `outlineViewSelectionDidChange`, so the
/// outline view doesn't need to claim first responder on a gutter
/// click anyway.
@MainActor
final class WorklaneOutlineView: NSOutlineView {
  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if row(at: point) < 0 {
      // Empty gutter or inter-row gap click. Suppress so AppKit's
      // default handler doesn't drop the selection; a real row's
      // `mouseDown` forwards through `super` as usual.
      return
    }
    super.mouseDown(with: event)
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
  /// Pasteboard type for a workspace row dragged inside the
  /// worklane. App-scoped so a stray drag from another `.string`
  /// source doesn't trip the validate path; the payload is the
  /// workspace's ULID string.
  fileprivate static let workspaceDragType = NSPasteboard.PasteboardType(
    "com.kawarimidoll.e05.worklane.workspace")

  /// Pasteboard type for a pane row dragged inside the worklane.
  /// Cross-workspace drag only — same-workspace reorder is not
  /// supported yet because the worklane's column dimension would
  /// need column-aware drop semantics (insert into column vs new
  /// column adjacent to it) that aren't fleshed out. Payload is
  /// the pane's ULID string.
  fileprivate static let paneDragType = NSPasteboard.PasteboardType(
    "com.kawarimidoll.e05.worklane.pane")

  private let scrollView = NSScrollView()
  private let outlineView = WorklaneOutlineView()

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

  /// True while a drag session originates from this outline view.
  /// Used to suppress spring-loaded expansion of collapsed
  /// workspaces during a workspace drag — auto-expand-on-hover is
  /// the standard Finder folder behaviour, but here it surprises
  /// the user (their collapse state silently flips while they're
  /// just reordering workspaces) and also fires our
  /// `outlineViewItemDidExpand` notification, polluting the
  /// persisted collapse set.
  private var isDragging = false

  /// True while `applyPersistedCollapseState` is mid-walk. Lets the
  /// bookkeeping `expandItem` calls through even when the drag
  /// session is still technically open: AppKit fires
  /// `draggingSession:endedAt:` *after* `acceptDrop` returns, so
  /// the post-drop reload runs with `isDragging` still true and
  /// would otherwise see every workspace forced collapsed.
  ///
  /// Assumes `expandItem` fires `outlineViewItemDidExpand`
  /// synchronously — true for the un-animated form we use here.
  /// Switch to `NSAnimationContext`-wrapped expansion and the flag
  /// would need to live across the animation completion instead.
  private var isApplyingPersistedCollapse = false

  /// True after `acceptDrop` actually commits a reorder. Drives the
  /// selection-restore branch of `endedAt`: a committed reorder
  /// triggers a reload that re-runs `syncSelection` itself, so the
  /// endedAt path skips it. A cancelled drag (no acceptDrop, or a
  /// no-op drop that didn't change order) needs `endedAt` to
  /// restore the highlight the willBeginAt path cleared.
  private var didCommitReorderInLastDrag = false

  /// True once the current drag session has surfaced the
  /// cross-private-boundary toast. `validateDrop` fires for every
  /// cursor move, so the flag de-duplicates the notification down
  /// to one toast per drag.
  private var didNotifyPrivateBoundaryInLastDrag = false

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
    // Empty selection stays *allowed* at the AppKit level so
    // `deselectAll(_:)` keeps working for the drag-start clear
    // (see `willBeginAt`) and the `syncSelection` nil branch.
    // Stray clicks in the empty gutter below the last row are
    // intercepted by `WorklaneOutlineView.mouseDown` instead,
    // which preserves the focused-pane highlight without
    // crippling programmatic deselection.
    outlineView.allowsEmptySelection = true
    outlineView.allowsMultipleSelection = false
    outlineView.style = .plain
    outlineView.indentationPerLevel = 8
    outlineView.indentationMarkerFollowsCell = true
    outlineView.autoresizesOutlineColumn = false
    outlineView.floatsGroupRows = false
    outlineView.dataSource = self
    outlineView.delegate = self
    outlineView.registerForDraggedTypes(
      [Self.workspaceDragType, Self.paneDragType])
    // Internal-only drag: dragging a workspace row out of the app
    // shouldn't synthesise anything for external receivers, and the
    // local-only mask makes the source check in `acceptDrop`
    // redundant rather than load-bearing.
    outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
    outlineView.setDraggingSourceOperationMask([], forLocal: false)

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
    /// Close every pane in a multi-pane column at once. The cell
    /// view's hover-revealed × button fires this; single-pane
    /// columns expose their pane directly so they go through
    /// `onPaneClose` instead.
    let onColumnClose: (ULID) -> Void
    let onPaneAudioToggle: (ULID) -> Void
    /// Flip the persisted collapse state for the given item id
    /// (workspace or column).
    let onToggleCollapse: (ULID) -> Void
    /// Commit a workspace reorder. The closure receives the new
    /// ordering as workspace ULIDs in display order; the container
    /// rewrites `workspaces` / `workspaceVCs` in parallel and
    /// keeps `focusedWorkspaceIndex` pointing at the same identity.
    let onReorderWorkspaces: ([ULID]) -> Void
    /// Commit a pane move that creates a fresh single-pane column.
    /// `position` is the column index in the target workspace
    /// where the moved pane should land (`nil` = append at the
    /// trailing edge). Used for both cross-workspace moves and
    /// in-place column splits within the same workspace.
    let onMovePaneToWorkspace: (
      _ paneId: ULID, _ workspaceId: ULID, _ position: Int?
    ) -> Void
    /// Commit a pane move into an existing column. `position` is
    /// the pane index inside the target column (`nil` = append at
    /// the trailing edge). Covers in-column reorder (source column
    /// == target column) and column merge (different columns).
    let onMovePaneToColumn: (
      _ paneId: ULID, _ columnId: ULID, _ position: Int?
    ) -> Void
    /// Fired once per drag session when the user hovers a pane
    /// over a workspace whose private flag differs from the
    /// source's. The container surfaces a toast explaining the
    /// rejection — `validateDrop` itself returns `[]` (no
    /// indicator), so the toast is the only feedback the user
    /// gets about why their drop won't land.
    let onCrossPrivateBoundaryAttempt: () -> Void
    /// Add a blank-browser column to the given workspace. The
    /// container resolves the "switch first if non-current" branch
    /// internally so callers can stay workspace-agnostic.
    let onAddPaneToWorkspace: (ULID) -> Void
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
    isApplyingPersistedCollapse = true
    defer { isApplyingPersistedCollapse = false }
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
  ///
  /// Cascade: when the focused pane lives inside a collapsed column
  /// or workspace, its own row isn't realised in the outline view
  /// (`row(forItem:) == -1`). Fall back to the nearest visible
  /// ancestor so the highlight still tells the user where focus
  /// lives instead of disappearing entirely. The selection is only
  /// a visual indicator — `outlineViewSelectionDidChange` is gated
  /// by `isSyncingSelection` so the cascade can't re-enter the
  /// click handlers.
  private func syncSelection(to focusedPaneId: ULID?) {
    guard let focusedPaneId, let node = nodesByPaneId[focusedPaneId]
    else {
      isSyncingSelection = true
      outlineView.deselectAll(nil)
      isSyncingSelection = false
      return
    }
    let targetItem: AnyObject = ancestorForCascade(of: node) ?? node
    let row = outlineView.row(forItem: targetItem)
    guard row >= 0 else { return }
    isSyncingSelection = true
    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    outlineView.scrollRowToVisible(row)
    isSyncingSelection = false
  }

  /// Pick the highlight target when `pane`'s own row is hidden.
  /// Walks column → workspace and returns the first ancestor whose
  /// row is currently realised in the outline view. Returns nil
  /// when the pane itself is visible (caller uses the pane node
  /// directly in that case).
  private func ancestorForCascade(of pane: WorklanePaneNode) -> AnyObject? {
    if outlineView.row(forItem: pane) >= 0 { return nil }
    if let column = pane.columnNode,
      outlineView.row(forItem: column) >= 0
    {
      return column
    }
    if let workspace = pane.workspaceNode,
      outlineView.row(forItem: workspace) >= 0
    {
      return workspace
    }
    return nil
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

  // MARK: - Drag-drop (workspace reorder)

  func outlineView(
    _ outlineView: NSOutlineView, draggingSession _: NSDraggingSession,
    willBeginAt _: NSPoint, forItems _: [Any]
  ) {
    isDragging = true
    didCommitReorderInLastDrag = false
    didNotifyPrivateBoundaryInLastDrag = false
    // Clear the focused-pane selection for the duration of the
    // drag. AppKit's drop indicator composes on top of the
    // selection highlight layer, and the overlap renders as a
    // stray white halo around the blue insertion line. With
    // selection cleared the indicator stands alone.
    isSyncingSelection = true
    outlineView.deselectAll(nil)
    isSyncingSelection = false
  }

  func outlineView(
    _: NSOutlineView, draggingSession _: NSDraggingSession,
    endedAt _: NSPoint, operation _: NSDragOperation
  ) {
    isDragging = false
    // A committed reorder triggers a reload whose own `syncSelection`
    // restores the highlight. A cancelled or no-op drag never
    // reaches that path, so endedAt is the only place that can
    // undo the willBeginAt deselect.
    if !didCommitReorderInLastDrag {
      syncSelection(to: lastInput?.focusedPaneId)
    }
    didCommitReorderInLastDrag = false
  }

  func outlineView(
    _: NSOutlineView, pasteboardWriterForItem item: Any
  ) -> NSPasteboardWriting? {
    let pb = NSPasteboardItem()
    if let ws = item as? WorklaneWorkspaceNode {
      pb.setString(ws.id.string, forType: Self.workspaceDragType)
      return pb
    }
    if let pane = item as? WorklanePaneNode {
      pb.setString(pane.id.string, forType: Self.paneDragType)
      return pb
    }
    // Column wrapper rows aren't draggable yet — pane / workspace
    // are the two units we support reordering for. Returning nil
    // cancels the drag for everything else.
    return nil
  }

  func outlineView(
    _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
    proposedItem item: Any?, proposedChildIndex index: Int
  ) -> NSDragOperation {
    if let workspaceDrag = validateWorkspaceDrop(
      info: info, outlineView: outlineView, item: item, index: index)
    {
      return workspaceDrag
    }
    if let paneDrag = validatePaneDrop(
      info: info, outlineView: outlineView, item: item, index: index)
    {
      return paneDrag
    }
    return []
  }

  func outlineView(
    _: NSOutlineView, acceptDrop info: NSDraggingInfo,
    item: Any?, childIndex: Int
  ) -> Bool {
    if draggedWorkspaceId(from: info) != nil {
      return acceptWorkspaceDrop(info: info, item: item, childIndex: childIndex)
    }
    if draggedPaneId(from: info) != nil {
      return acceptPaneDrop(info: info, item: item, childIndex: childIndex)
    }
    return false
  }

  // MARK: Workspace drag

  private func validateWorkspaceDrop(
    info: NSDraggingInfo, outlineView: NSOutlineView,
    item: Any?, index: Int
  ) -> NSDragOperation? {
    guard draggedWorkspaceId(from: info) != nil else { return nil }
    let retarget = retargetToRootGap(item: item, childIndex: index)
    guard retarget.index != NSOutlineViewDropOnItemIndex else { return [] }
    // Tell AppKit about the retarget so the gap indicator lands
    // between workspace headers — without this, dropping in the
    // area below an expanded workspace's panes gets reported as
    // "child of that workspace" and AppKit refuses to draw an
    // insertion indicator at the root level. `itemChanged` flips
    // exactly when retarget hit (the same-item path returns the
    // original index unchanged), so a single condition covers both
    // pane / column / workspace drops.
    if retarget.itemChanged {
      outlineView.setDropItem(nil, dropChildIndex: retarget.index)
    }
    return .move
  }

  private func acceptWorkspaceDrop(
    info: NSDraggingInfo, item: Any?, childIndex: Int
  ) -> Bool {
    guard let input = lastInput,
      let draggedId = draggedWorkspaceId(from: info)
    else {
      logger.warning(
        """
        [worklane/drag] workspace drop guard failed \
        item=\(String(describing: item), privacy: .public) \
        childIndex=\(childIndex, privacy: .public)
        """)
      return false
    }
    // Re-run the retarget so a drop landed via the cell area inside
    // an expanded workspace still maps to a root-level insertion.
    // `validateDrop` already calls `setDropItem`, so AppKit should
    // hand us the retargeted index here — but the docs only promise
    // that for "subsequent calls to validateDrop", leaving accept a
    // grey area; matching the resolver in both paths is the same
    // pattern the bookmarks sidebar uses.
    let retarget = retargetToRootGap(item: item, childIndex: childIndex)
    guard retarget.index != NSOutlineViewDropOnItemIndex else { return false }

    let liveOrder = workspaceNodes.map(\.id)
    // `draggedWorkspaceId` filters against live nodes already, so a
    // missing id here means the snapshot drifted between
    // `pasteboardWriterForItem` and the drop — surface it rather
    // than silently treating the drop as "append at end".
    guard let oldIndex = liveOrder.firstIndex(of: draggedId) else {
      logger.error(
        "[worklane/drag] drop with id no longer in liveOrder id=\(draggedId.string, privacy: .public)")
      return false
    }
    var newOrder = liveOrder
    newOrder.remove(at: oldIndex)
    // `childIndex` from AppKit indexes into the current data model
    // (where the dragged workspace still sits in its old slot). After
    // filtering the dragged id out, an index past the old slot needs
    // a -1 shift; an index before stays put.
    let adjusted = oldIndex < retarget.index ? retarget.index - 1 : retarget.index
    let clamped = min(max(adjusted, 0), newOrder.count)
    newOrder.insert(draggedId, at: clamped)
    if newOrder != liveOrder {
      input.onReorderWorkspaces(newOrder)
      didCommitReorderInLastDrag = true
    }
    return true
  }

  // MARK: Pane drag

  /// Resolved drop destination for a pane drag. `.newColumn` puts
  /// the moved pane into a brand-new single-pane column at the
  /// given top-level position; `.insertIntoColumn` lands it inside
  /// an existing column at the given pane-array position. Carries
  /// node references directly so the validate / accept paths don't
  /// have to re-look up by id and re-prove the existence the
  /// resolver already established.
  private enum PaneDropAction {
    case newColumn(workspace: WorklaneWorkspaceNode, position: Int)
    case insertIntoColumn(column: WorklaneColumnNode, position: Int)
  }

  private func validatePaneDrop(
    info: NSDraggingInfo, outlineView: NSOutlineView,
    item: Any?, index: Int
  ) -> NSDragOperation? {
    guard let paneId = draggedPaneId(from: info),
      let sourcePaneNode = nodesByPaneId[paneId],
      let sourceWsNode = sourcePaneNode.workspaceNode,
      let action = paneDropAction(item: item, childIndex: index)
    else { return nil }

    let targetWsNode: WorklaneWorkspaceNode
    switch action {
    case .newColumn(let ws, _):
      targetWsNode = ws
    case .insertIntoColumn(let column, _):
      guard let wsNode = column.workspaceNode else { return nil }
      targetWsNode = wsNode
    }

    // Cross-private-boundary block at validateDrop: returning []
    // skips the gap indicator entirely, signalling the rejection
    // visually. AppKit's "no drop" cursor isn't reachable through
    // public API, so back the signal up with a one-shot toast
    // (the container holds the alert; we just kick the closure
    // once per drag session).
    if sourceWsNode.model.isPrivate != targetWsNode.model.isPrivate {
      if !didNotifyPrivateBoundaryInLastDrag,
        let input = lastInput
      {
        didNotifyPrivateBoundaryInLastDrag = true
        input.onCrossPrivateBoundaryAttempt()
      }
      return []
    }

    // Drop is a no-op when it would land the pane exactly where it
    // already lives. Two shapes to catch:
    //   1. In-column reorder onto the pane's own position
    //      (drop above or below = index oldIdx or oldIdx+1).
    //   2. New-column drop adjacent to a single-pane column that
    //      contains this pane (drop before or after that slot).
    // Returning [] suppresses the indicator so the user sees that
    // the cursor location won't accept.
    if isNoOpAction(action, sourcePane: sourcePaneNode) {
      return []
    }

    // Retarget the drop indicator so its gap visualises exactly
    // what's about to happen — workspace-level for new columns,
    // column wrapper for column merges. `setDropItem` is what
    // makes a hit on a pane row resolve as "between siblings"
    // instead of "into the pane".
    switch action {
    case .newColumn(let ws, let position):
      outlineView.setDropItem(ws, dropChildIndex: position)
    case .insertIntoColumn(let column, let position):
      outlineView.setDropItem(column, dropChildIndex: position)
    }
    return .move
  }

  private func acceptPaneDrop(
    info: NSDraggingInfo, item: Any?, childIndex: Int
  ) -> Bool {
    guard let input = lastInput,
      let paneId = draggedPaneId(from: info),
      let sourcePaneNode = nodesByPaneId[paneId],
      let action = paneDropAction(item: item, childIndex: childIndex),
      !isNoOpAction(action, sourcePane: sourcePaneNode)
    else {
      logger.warning(
        """
        [worklane/drag] pane drop guard failed \
        item=\(String(describing: item), privacy: .public) \
        childIndex=\(childIndex, privacy: .public)
        """)
      return false
    }
    switch action {
    case .newColumn(let ws, let position):
      input.onMovePaneToWorkspace(paneId, ws.id, position)
    case .insertIntoColumn(let column, let position):
      input.onMovePaneToColumn(paneId, column.id, position)
    }
    didCommitReorderInLastDrag = true
    return true
  }

  /// Resolve where a pane drop should land. Returns the action
  /// describing the destination, or `nil` for hits the worklane
  /// can't interpret (root-level gaps between workspaces, or a hit
  /// on a node whose parent chain doesn't lead back to a known
  /// workspace).
  private func paneDropAction(
    item: Any?, childIndex: Int
  ) -> PaneDropAction? {
    guard let item else { return nil }
    if let ws = item as? WorklaneWorkspaceNode {
      // Drop directly on the workspace header (childIndex == -1):
      // insert at the leading edge so the moved pane lands as the
      // workspace's first column. Reads more naturally than the
      // trailing-edge default, where dropping on a workspace title
      // would silently put the pane at the far right of an
      // existing chain.
      //
      // Drop between top-level children (childIndex >= 0): the
      // worklane's top-level child count matches
      // `workspaces.columns.count` (single-pane columns surface
      // their pane directly, multi-pane columns surface their
      // `WorklaneColumnNode`), so the index passes through unchanged.
      if childIndex == NSOutlineViewDropOnItemIndex {
        return .newColumn(workspace: ws, position: 0)
      }
      return .newColumn(workspace: ws, position: childIndex)
    }
    if let column = item as? WorklaneColumnNode {
      // Drop on the column wrapper itself (`childIndex == -1`)
      // inserts at the leading edge, matching the workspace-header
      // shape. Drop between its panes uses the proposed child
      // index directly.
      if childIndex == NSOutlineViewDropOnItemIndex {
        return .insertIntoColumn(column: column, position: 0)
      }
      return .insertIntoColumn(column: column, position: childIndex)
    }
    if let pane = item as? WorklanePaneNode,
      let wsNode = pane.workspaceNode
    {
      // AppKit reports `proposedItem = pane, proposedChildIndex
      // = -1` for hover near a row's centre. Resolve those hits
      // to the slot **before** the pane: the user sees the drop
      // indicator above the row and reads it as "insert here".
      // Resolving to `paneIdx + 1` (below) silently shifted the
      // commit down by one whenever the hit landed on the row's
      // mid-band, even though the visible indicator sat above
      // the next row. Hover over a row's top or bottom edge
      // still falls through to AppKit's column+childIndex
      // resolution path, so explicit before / after intent stays
      // expressible.
      if let columnNode = pane.columnNode,
        let paneIdx =
          panesByColumnId[columnNode.id]?.firstIndex(where: { $0.id == pane.id })
      {
        return .insertIntoColumn(column: columnNode, position: paneIdx)
      }
      // Workspace direct child = single-pane column. Same
      // before-the-hit convention: new column lands to the left
      // of the row's column slot.
      if let columnIdx = wsNode.model.columns.firstIndex(where: { column in
        column.panes.contains(where: { $0.id == pane.id })
      }) {
        return .newColumn(workspace: wsNode, position: columnIdx)
      }
    }
    return nil
  }

  /// True when `action` would put the dragged pane back where it
  /// already is. Lets `validateDrop` suppress the indicator and
  /// `acceptDrop` reject the commit so the moved pane never gets
  /// pulled out and re-inserted into the exact same slot.
  private func isNoOpAction(
    _ action: PaneDropAction, sourcePane: WorklanePaneNode
  ) -> Bool {
    switch action {
    case .newColumn(let ws, let position):
      guard sourcePane.workspaceNode?.id == ws.id,
        let columnIdx = ws.model.columns.firstIndex(where: { column in
          column.panes.contains(where: { $0.id == sourcePane.id })
        })
      else { return false }
      // Only the source's own column counts as "same slot": the
      // pane has to be alone in that column (otherwise removing
      // it changes the column structure) and the drop has to land
      // at columnIdx or columnIdx + 1 (both sides of the source).
      let sourceColumn = ws.model.columns[columnIdx]
      guard sourceColumn.panes.count == 1 else { return false }
      return position == columnIdx || position == columnIdx + 1
    case .insertIntoColumn(let column, let position):
      guard sourcePane.columnNode?.id == column.id,
        let paneIdx =
          panesByColumnId[column.id]?.firstIndex(where: { $0.id == sourcePane.id })
      else { return false }
      // In-column reorder: drop above (position = paneIdx) or
      // below (position = paneIdx + 1) the source itself collapses
      // into a no-op once the source pane is removed first.
      return position == paneIdx || position == paneIdx + 1
    }
  }

  /// AppKit reports a drop inside an expanded workspace (between
  /// its panes / on its column wrapper / on the workspace row
  /// itself) with that workspace as the proposed parent. Workspace
  /// reorder only supports root-level moves, so any non-root proposal
  /// retargets to the gap immediately after the containing
  /// workspace — that's the visual position a user would expect
  /// when they aim at the bottom of workspace N's children.
  private func retargetToRootGap(
    item: Any?, childIndex: Int
  ) -> (index: Int, itemChanged: Bool) {
    if item == nil { return (childIndex, false) }
    guard let wsIdx = containingWorkspaceIndex(of: item) else {
      return (NSOutlineViewDropOnItemIndex, true)
    }
    return (wsIdx + 1, true)
  }

  private func containingWorkspaceIndex(of item: Any?) -> Int? {
    if let ws = item as? WorklaneWorkspaceNode { return ws.index }
    if let column = item as? WorklaneColumnNode {
      return column.workspaceNode?.index
    }
    if let pane = item as? WorklanePaneNode {
      return pane.workspaceNode?.index
    }
    return nil
  }

  private func draggedPaneId(from info: NSDraggingInfo) -> ULID? {
    guard let items = info.draggingPasteboard.pasteboardItems else { return nil }
    for item in items {
      guard let raw = item.string(forType: Self.paneDragType) else { continue }
      guard raw.count == 26 else {
        logger.warning(
          "[worklane/drag] reject pane ULID payload of length \(raw.count, privacy: .public)")
        continue
      }
      let id = ULID(raw)
      if nodesByPaneId[id] != nil { return id }
    }
    return nil
  }

  private func draggedWorkspaceId(from info: NSDraggingInfo) -> ULID? {
    guard let items = info.draggingPasteboard.pasteboardItems else { return nil }
    for item in items {
      guard let raw = item.string(forType: Self.workspaceDragType)
      else { continue }
      // ULID's `init(_:)` doesn't validate, so check the canonical
      // 26-char Crockford-Base32 length up front. The full
      // alphabet check is implicit in the live-id filter below
      // (no live workspace can have an off-spec id) but the
      // length cheap-rejects bogus payloads and the warning makes
      // a future foreign-source bug obvious in Console.app.
      guard raw.count == 26 else {
        logger.warning(
          "[worklane/drag] reject ULID payload of length \(raw.count, privacy: .public)")
        continue
      }
      let id = ULID(raw)
      if workspaceNodes.contains(where: { $0.id == id }) {
        return id
      }
    }
    return nil
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

  func outlineView(_: NSOutlineView, shouldExpandItem _: Any) -> Bool {
    // Reject spring-loaded auto-expansion during a drag session.
    // The user is reordering workspaces, not drilling into them —
    // silently flipping their collapse state on a drag-hover would
    // surprise on completion and also fires our didExpand
    // notification, which would write the change to session.json.
    // The post-drop reload calls `expandItem` from our own
    // bookkeeping path, which the `isApplyingPersistedCollapse`
    // flag lets through: `draggingSession:endedAt:` fires after
    // `acceptDrop`, so the reload happens with `isDragging` still
    // true.
    isApplyingPersistedCollapse || !isDragging
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
