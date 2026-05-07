import AppKit

/// `NSTableView` subclass that forwards key events we want to intercept
/// (Space for Quick Look, Return / Right / Left / Backspace for
/// navigation, h/j/k/l for vim-style movement) to the owning
/// `FinderPaneView`, while letting the table's own handling cover
/// arrow-key row movement and native shortcuts.
///
/// The target is resolved via `enclosingFinderPane` (view-ancestor
/// walk) rather than a stored back-reference so the subclass stays
/// free of retain-cycle hazards and can be allocated before the pane
/// root exists in `FinderPaneView.init`.
@MainActor
final class FinderTableView: NSTableView {
  var onFocusChanged: (() -> Void)?

  override var acceptsFirstResponder: Bool { true }

  /// Advertises the operations this pane is willing to perform when a
  /// drag originated here lands on a drop target. Returning
  /// `[.move, .copy]` lets recipients (Finder, editors, other e05
  /// panes) pick whichever applies — Finder uses `.move` within a
  /// volume and `.copy` across volumes, editors typically pick
  /// `.copy` to read the file open. The AppKit default (`[]`) causes
  /// every drop to fail silently.
  override func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    [.move, .copy]
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result { onFocusChanged?() }
    return result
  }

  /// Right-click / control-click entry. Adjusts selection to mirror
  /// Finder before delegating menu construction to the pane:
  /// - row click inside the current selection keeps the selection
  ///   intact (so multi-target actions stay coherent);
  /// - row click outside collapses to a single-row selection on the
  ///   clicked target;
  /// - empty-area click leaves the selection untouched and shows the
  ///   directory-level menu.
  override func menu(for event: NSEvent) -> NSMenu? {
    // Cancel any in-flight rename first so the menu opens against the
    // on-disk filename, not the field editor's unsaved working copy.
    // Finder list-view behaves the same way: right-click during rename
    // reverts the edit before surfacing the context menu.
    enclosingFinderPane?.cancelRenameIfActive()

    let point = convert(event.locationInWindow, from: nil)
    let clickedRow = row(at: point)

    if clickedRow >= 0, !selectedRowIndexes.contains(clickedRow) {
      selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
    }

    return enclosingFinderPane?.buildContextMenu(clickedRow: clickedRow)
  }

  override func keyDown(with event: NSEvent) {
    guard let pane = enclosingFinderPane else {
      super.keyDown(with: event)
      return
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    switch event.keyCode {
    case 49:  // Space
      if flags.isEmpty {
        pane.toggleQuickLook()
        return
      }
    case 36, 76:  // Return / numpad enter — rename, matching Finder list view
      if flags.isEmpty {
        pane.beginRenameEntry()
        return
      }
    case 51:  // Delete / Backspace — go up, matches Finder
      if flags.isEmpty {
        pane.goUp()
        return
      }
    case 124:  // Right arrow — enter selected
      if flags.isEmpty {
        pane.openSelectedRow()
        return
      }
    case 123:  // Left arrow — go up
      if flags.isEmpty {
        pane.goUp()
        return
      }
    default:
      break
    }

    if flags.isEmpty, let chars = event.characters {
      switch chars {
      case "h":
        pane.goUp()
        return
      case "j":
        pane.moveSelectionRelative(by: 1)
        return
      case "k":
        pane.moveSelectionRelative(by: -1)
        return
      case "l":
        pane.openSelectedRow()
        return
      case "g":
        pane.selectAbsoluteRow(0)
        return
      default:
        break
      }
    }

    // `G` always arrives with the shift modifier set (it's the
    // shift-applied form of `g`), so it can't share the
    // `flags.isEmpty` branch above. Match exactly `.shift` so plain
    // shift+G triggers but ⌘⇧G / ⌃⇧G stay free for other handlers.
    if flags == .shift, event.characters == "G" {
      pane.selectAbsoluteRow(pane.lastRowIndex)
      return
    }

    super.keyDown(with: event)
  }

  /// View-ancestor walk back to the `FinderPaneView` that hosts this
  /// table. Internal rather than `private` so drop handlers can map a
  /// drag's `info.draggingSource` (the originating table) back to its
  /// owning pane — needed to restore the source pane's selection
  /// when an undo walks a drag-and-drop move backwards.
  var enclosingFinderPane: FinderPaneView? {
    var view: NSView? = self
    while let v = view {
      if let pane = v as? FinderPaneView { return pane }
      view = v.superview
    }
    return nil
  }
}
