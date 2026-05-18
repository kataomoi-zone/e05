import AppKit

/// Shared components for the sidebar's list-based modes (bookmarks,
/// history, downloads). The sidebar is mouse-only; keyboard navigation
/// is intentionally absent. Shared infrastructure:
/// - hover-to-select row highlighting with non-emphasized selection
///   color so the list's focus state never flashes blue when
///   first-responder moves between the sidebar and the pane stack
///   (`SidebarListRowView`)
/// - hover-revealed trailing action buttons whose visibility survives
///   scroll-out under a stationary cursor (`SidebarListCellView`)

/// Row view that moves the table selection on hover (unifying mouse
/// and keyboard feedback into a single highlight) and forces the
/// non-key gray selection color so the sidebar's focus state doesn't
/// flash blue when the list steals first-responder momentarily.
@MainActor
final class SidebarListRowView: NSTableRowView {
  private var trackingArea: NSTrackingArea?

  override var isEmphasized: Bool {
    get { false }
    set {}
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let old = trackingArea { removeTrackingArea(old) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with _: NSEvent) {
    guard let tableView = superview as? NSTableView else { return }
    let row = tableView.row(for: self)
    // Skip re-selecting the same row so the table doesn't emit a
    // redundant `selectionDidChange` whenever the cursor crosses a
    // subview boundary inside the already-selected row.
    guard row >= 0, tableView.selectedRow != row else { return }
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
  }

  override func mouseExited(with _: NSEvent) {
    // Drop the hover-driven selection so the gray highlight doesn't
    // linger on the last hovered row after the pointer leaves the
    // list (out of the sidebar, into the mode bar, into a scroll
    // gutter, etc.). Crossing into an adjacent row fires that row's
    // `mouseEntered` immediately, so the highlight migrates rather
    // than blinking off.
    //
    // `cursorIsStillInsideBounds()` filters spurious exits when the
    // pointer crosses into a subview's own tracking area (a
    // HoverIconButton in the trailing slot, etc.) so hover-revealed
    // buttons stay clickable. Same pattern as `SidebarListCellView`.
    guard let tableView = superview as? NSTableView else { return }
    if cursorIsStillInsideBounds() { return }
    tableView.deselectAll(nil)
  }
}

/// Cell view base class that encapsulates the hover-tracking
/// boilerplate every sidebar list cell shares:
/// - `.inVisibleRect` tracking area with cursor updates
/// - mouseExited guard against spurious AppKit events when the pointer
///   moves into a subview's own tracking area and back
/// - pointing-hand cursor on hover
/// - `forceHideHoverActions()` entry point used by the parent list
///   when the clip view scrolls, because `.inVisibleRect` doesn't
///   reliably deliver `mouseExited` when a hovered cell slides out
///   from under a stationary cursor
///
/// Subclasses override `setHoverActionsHidden(_:)` to show or hide
/// their trailing action(s). The default is a no-op, so cells without
/// hover actions can ignore it.
@MainActor
class SidebarListCellView: NSView {
  private var trackingArea: NSTrackingArea?

  /// True while the pointer is inside the cell's bounds (modulo
  /// AppKit's spurious mouseExited filtering). Exposed so subclasses
  /// that rebuild their action buttons under the cursor can sync
  /// visibility to the current hover state.
  private(set) var isHovered: Bool = false

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let old = trackingArea { removeTrackingArea(old) }
    let area = NSTrackingArea(
      rect: bounds,
      // `.cursorUpdate` lets AppKit call `cursorUpdate(with:)`
      // while the pointer is inside the cell so rows advertise
      // their clickability (hover highlight alone looks passive).
      options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with _: NSEvent) {
    isHovered = true
    setHoverActionsHidden(false)
  }

  override func mouseExited(with _: NSEvent) {
    // AppKit delivers a spurious mouseExited when the cursor moves
    // from this cell's tracking area into a subview's own tracking
    // area (e.g. a HoverIconButton in the trailing slot) and back —
    // ignore those so the hover-reveal doesn't flicker off mid-aim.
    if cursorIsStillInsideBounds() { return }
    isHovered = false
    setHoverActionsHidden(true)
  }

  override func cursorUpdate(with _: NSEvent) {
    NSCursor.pointingHand.set()
  }

  /// Force-hide the hover-revealed action button(s) regardless of
  /// tracking state. Used by the parent list when the clip view
  /// scrolls.
  func forceHideHoverActions() {
    isHovered = false
    setHoverActionsHidden(true)
  }

  /// Override in subclasses to toggle hover-revealed action
  /// visibility. Default is a no-op so cells without hover actions
  /// don't need to implement it.
  func setHoverActionsHidden(_ hidden: Bool) {}
}
