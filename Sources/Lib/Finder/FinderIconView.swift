import AppKit

/// `NSCollectionView` subclass for the finder pane's icon-grid mode.
/// Mirrors `FinderTableView`'s focus-callback / menu / keyDown wiring
/// so the icon grid has the same affordances as the list view: right-
/// click context menu, Space for Quick Look, Return for rename, vim
/// `h` / `l` / `g` / `G` for navigation. The container learns when
/// keyboard focus moves into the pane through this view, without the
/// pane having to register a separate window observer.
///
/// Double-click activation rides the `mouseDown` override rather
/// than an `NSClickGestureRecognizer`. The recogniser interposes on
/// the same event stream `NSCollectionView` itself uses for single-
/// click selection and the rubber-band tracking loop, swallowing the
/// drag entry so empty-area drags don't paint a selection rectangle.
/// Reading `event.clickCount` after `super.mouseDown` returns
/// preserves AppKit's native selection / rubber-band path while
/// still firing on the second click — the same shape `NSTableView`
/// uses for `doubleAction`.
@MainActor
final class FinderIconCollectionView: NSCollectionView {
  var onFocusChanged: (() -> Void)?

  /// Fired after the user releases a double-click sequence so the
  /// owning pane can descend a folder / open a file. `super.mouseDown`
  /// has already applied the first click's selection by the time the
  /// callback runs.
  var onItemDoubleClick: ((IndexPath) -> Void)?

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result { onFocusChanged?() }
    return result
  }

  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
    guard event.clickCount == 2 else { return }
    let point = convert(event.locationInWindow, from: nil)
    if let indexPath = indexPathForItem(at: point) {
      onItemDoubleClick?(indexPath)
    }
  }

  /// Right-click / control-click entry. `NSCollectionView` doesn't
  /// reliably route right-clicks through `menu(for:event:)` (the
  /// override is documented but in practice gets bypassed by the
  /// view's own selection / drag tracking), so we open the context
  /// menu directly from `rightMouseDown` instead. Selection tracking
  /// mirrors the list view's `menu(for:)`:
  /// - click on a cell already selected → keep the selection intact
  ///   (multi-target actions stay coherent);
  /// - click on a cell outside the selection → collapse to a single-
  ///   item selection on the clicked target;
  /// - click on empty area → leave the selection untouched and surface
  ///   the directory-level menu.
  override func rightMouseDown(with event: NSEvent) {
    guard let pane = enclosingFinderPane else {
      super.rightMouseDown(with: event)
      return
    }
    pane.cancelRenameIfActive()

    let point = convert(event.locationInWindow, from: nil)
    var clickedRow = -1
    if let indexPath = indexPathForItem(at: point) {
      clickedRow = indexPath.item
      if !selectionIndexPaths.contains(indexPath) {
        deselectAll(nil)
        selectItems(at: [indexPath], scrollPosition: [])
        pane.handleIconSelectionChange()
      }
    }
    let menu = pane.buildContextMenu(clickedRow: clickedRow)
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }

  /// Forward the same key handling the list view does, minus the
  /// arrow-key bindings: plain ← / → are 2D grid-nav directions in
  /// icon mode and AppKit's default `NSCollectionView` arrow-key
  /// handler already covers them. Linear-step keys (`j` / `k`) fall
  /// through too — they aren't meaningful in a grid without a row
  /// concept, so the list-view convention doesn't translate.
  override func keyDown(with event: NSEvent) {
    guard let pane = enclosingFinderPane else {
      super.keyDown(with: event)
      return
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    switch event.keyCode {
    case 49:  // Space — Quick Look
      if flags.isEmpty {
        pane.toggleQuickLook()
        return
      }
    case 36, 76:  // Return / numpad enter — rename, matching list view
      if flags.isEmpty {
        pane.beginRenameEntry()
        return
      }
    case 51:  // Delete / Backspace — go up
      if flags.isEmpty {
        pane.goUp()
        return
      }
    default:
      break
    }

    // `charactersIgnoringModifiers` is the fallback over `characters`
    // because `NSCollectionView`'s typeahead support can re-interpret
    // an event's `characters` for selection-by-prefix; the unmodified
    // form survives the round-trip and matches what the user actually
    // pressed.
    if flags.isEmpty {
      let chars = event.charactersIgnoringModifiers ?? event.characters ?? ""
      switch chars {
      case "h":
        pane.goUp()
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

    if flags == .shift,
      (event.charactersIgnoringModifiers == "G" || event.characters == "G")
    {
      pane.selectAbsoluteRow(pane.lastRowIndex)
      return
    }

    super.keyDown(with: event)
  }

  /// `NSCollectionView` ships a non-nil `undoManager` of its own
  /// (used internally for the move / delete operations the view
  /// supports natively). That eclipses `FinderPaneView`'s
  /// `undoManager` override so a ⌘Z on the icon view looks at an
  /// empty stack — visible as a greyed-out Edit > Undo menu item.
  /// Forwarding to the enclosing pane re-routes the chain back onto
  /// `FinderUndoCenter.manager` so undo/redo behave the same way they
  /// do under list mode.
  override var undoManager: UndoManager? {
    enclosingFinderPane?.undoManager ?? super.undoManager
  }

  /// Forward the menu-bar Edit > Undo / Redo / Copy / Paste actions
  /// to the enclosing pane. Without these, AppKit walks the responder
  /// chain past `NSCollectionView` (which doesn't implement them) but
  /// the view's own `undoManager` poisoning above leaves the menu
  /// items inert. Defining them here as thin trampolines keeps the
  /// behaviour identical to list mode.
  ///
  /// `@objc` is required so `#selector` can name them and so the
  /// menu validation pass below sees them; AppKit dispatches the
  /// menu's action through the Objective-C runtime.
  @objc func undo(_ sender: Any?) {
    enclosingFinderPane?.undo(sender)
  }

  @objc func redo(_ sender: Any?) {
    enclosingFinderPane?.redo(sender)
  }

  @objc func copy(_ sender: Any?) {
    enclosingFinderPane?.copy(sender)
  }

  @objc func paste(_ sender: Any?) {
    enclosingFinderPane?.paste(sender)
  }

  /// View-ancestor walk back to the `FinderPaneView` that hosts this
  /// collection. Internal so drag-drop / rename hooks can reach the
  /// owning pane the same way `FinderTableView.enclosingFinderPane`
  /// does, without keeping a stored back-reference that would
  /// retain-cycle the pane.
  var enclosingFinderPane: FinderPaneView? {
    var view: NSView? = self
    while let v = view {
      if let pane = v as? FinderPaneView { return pane }
      view = v.superview
    }
    return nil
  }
}

/// Validate the four forwarded action selectors against the enclosing
/// pane so the menu-bar Edit > Undo / Redo / Copy / Paste items pick
/// up `canUndo` / `hasSelection` / `pasteableFileURLCount` from the
/// same source the list view uses. Other selectors (Window menu,
/// app-wide actions) fall through to `true` so we don't accidentally
/// disable unrelated items by claiming validation responsibility.
extension FinderIconCollectionView: NSMenuItemValidation {
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let action = menuItem.action,
      let pane = enclosingFinderPane
    else { return true }
    switch action {
    case #selector(undo(_:)), #selector(redo(_:)),
      #selector(copy(_:)), #selector(paste(_:)):
      return pane.validateMenuItem(menuItem)
    default:
      return true
    }
  }
}

/// `NSCollectionViewItem` for one icon-grid cell. A 48pt icon sits
/// centered above a 2-line truncating-middle name label, matching
/// Finder's icon-view proportions at the small zoom level. The
/// selection highlight is rendered as a rounded translucent fill on
/// the item's root view rather than via AppKit's default focus ring,
/// since the collection view's inset doesn't compose cleanly with
/// the pane's surrounding chrome.
///
/// Two visual states ride on top of selection:
/// - `dimmed` mirrors `FinderRowView`'s alpha tweak — hidden filesystem
///   entries (dotfiles, anything with `isHidden` set) render at 0.5 on
///   rest, snapping back to full intensity while selected so the
///   highlight reads the same for hidden and non-hidden cells.
/// - `inFlight` tags a synthetic placeholder cell whose target file
///   isn't on disk yet (Compress / Paste / Duplicate output). The
///   cell dims like a hidden entry and shows a small spinner over
///   the icon area until the directory monitor's reload swaps the
///   placeholder for the real row.
@MainActor
final class FinderIconItem: NSCollectionViewItem {
  static let identifier = NSUserInterfaceItemIdentifier("finder.iconItem")

  /// Cell box: 96pt wide leaves room for the label + a few px of
  /// breathing room around the icon; 88pt tall fits a 48pt icon, a
  /// 4pt gap, and two text rows at 11pt without truncating common
  /// filenames. Tweaked together with `FinderPaneView+IconView`'s
  /// flow-layout insets — change one and the grid spacing shifts.
  static let itemSize = NSSize(width: 96, height: 88)

  /// Spinner shown over the icon area when `inFlight == true`. Held
  /// as a stored property so the data-source callback can toggle
  /// visibility without rebuilding the view tree on every recycle.
  private var spinner: NSProgressIndicator!

  override func loadView() {
    let root = NSView()
    root.wantsLayer = true
    root.layer?.cornerRadius = 6
    root.translatesAutoresizingMaskIntoConstraints = false
    self.view = root

    let img = NSImageView()
    img.imageScaling = .scaleProportionallyUpOrDown
    img.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(img)
    self.imageView = img

    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 11)
    label.alignment = .center
    // Single-line truncating-middle: NSTextField's `wraps = true` +
    // `lineBreakMode = .byTruncatingMiddle` combination doesn't actually
    // truncate at the middle (wraps wins, the line breaks instead) so
    // long filenames flow off the cell. Match Finder's icon-view
    // baseline by collapsing to one line and middle-truncating, which
    // is what the system surface produces for the same shape.
    label.lineBreakMode = .byTruncatingMiddle
    label.maximumNumberOfLines = 1
    label.cell?.usesSingleLineMode = true
    label.cell?.wraps = false
    label.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(label)
    self.textField = label

    let s = NSProgressIndicator()
    s.style = .spinning
    s.controlSize = .small
    s.isIndeterminate = true
    s.isDisplayedWhenStopped = false
    s.isHidden = true
    s.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(s)
    self.spinner = s

    NSLayoutConstraint.activate([
      img.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
      img.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      img.widthAnchor.constraint(equalToConstant: 48),
      img.heightAnchor.constraint(equalToConstant: 48),

      label.topAnchor.constraint(equalTo: img.bottomAnchor, constant: 4),
      label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
      label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
      label.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -2),

      // Spinner sits centered on the icon artwork rather than on the
      // cell as a whole — the same affordance the list view uses, so
      // a placeholder reads as "this thumbnail slot is the one being
      // worked on".
      s.centerXAnchor.constraint(equalTo: img.centerXAnchor),
      s.centerYAnchor.constraint(equalTo: img.centerYAnchor),
      s.widthAnchor.constraint(equalToConstant: 16),
      s.heightAnchor.constraint(equalToConstant: 16),
    ])
  }

  override var isSelected: Bool {
    didSet { applySelectionAppearance() }
  }

  /// True for hidden filesystem entries. The data-source callback
  /// writes this on every cell recycle, so a recycled cell that just
  /// re-rendered as a hidden entry doesn't carry the previous
  /// occupant's full opacity.
  var dimmed: Bool = false {
    didSet { applyAlpha() }
  }

  /// True when the cell represents a `FinderOperationTracker`
  /// synthetic placeholder. Drives both the dim alpha (so the cell
  /// reads as "not yet on disk") and the spinner overlay.
  var inFlight: Bool = false {
    didSet {
      applyAlpha()
      if inFlight {
        spinner.isHidden = false
        spinner.startAnimation(nil)
      } else {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
      }
    }
  }

  /// Apply the selection fill without the implicit ~0.25s CALayer
  /// fade. Setting `backgroundColor` on a CALayer triggers a default
  /// `kCAMediaTimingFunctionDefault` animation, which reads as a
  /// laggy highlight when the user expects an instant click → fill
  /// response. Wrapping the assignment in a transaction with
  /// actions disabled keeps the change snappy without giving up the
  /// rounded-fill style that AppKit's default selection ring can't
  /// produce inside an NSCollectionViewItem.
  private func applySelectionAppearance() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    view.layer?.backgroundColor =
      isSelected
      ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor
      : NSColor.clear.cgColor
    CATransaction.commit()
    applyAlpha()
  }

  /// Mirror `FinderRowView`'s rule: dim hidden / in-flight cells on
  /// rest, restore full opacity while selected so the highlight tint
  /// doesn't desaturate. Applied to the icon and label only — the
  /// in-flight spinner stays at full opacity so the "operation in
  /// progress" affordance remains legible against a dimmed
  /// placeholder. The selection background (drawn on the root view's
  /// layer in `applySelectionAppearance`) is also unaffected, so the
  /// highlight reads cleanly regardless of dim state.
  private func applyAlpha() {
    let needsDim = (dimmed || inFlight) && !isSelected
    let alpha: CGFloat = needsDim ? Self.dimmedAlpha : 1.0
    imageView?.alphaValue = alpha
    textField?.alphaValue = alpha
  }

  private static let dimmedAlpha: CGFloat = 0.5
}
