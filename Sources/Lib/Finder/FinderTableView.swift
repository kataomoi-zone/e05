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

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result { onFocusChanged?() }
    return result
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

  private var enclosingFinderPane: FinderPaneView? {
    var view: NSView? = self
    while let v = view {
      if let pane = v as? FinderPaneView { return pane }
      view = v.superview
    }
    return nil
  }
}
