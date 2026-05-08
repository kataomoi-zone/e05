import AppKit

/// `NSCollectionView` subclass for the finder pane's icon-grid mode.
/// Mirrors `FinderTableView`'s focus-callback wiring so the container
/// learns when keyboard focus moves into the pane through this view,
/// without the pane having to register a separate window observer.
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
}

/// `NSCollectionViewItem` for one icon-grid cell. A 48pt icon sits
/// centered above a 2-line truncating-middle name label, matching
/// Finder's icon-view proportions at the small zoom level. The
/// selection highlight is rendered as a rounded translucent fill on
/// the item's root view rather than via AppKit's default focus ring,
/// since the collection view's inset doesn't compose cleanly with
/// the pane's surrounding chrome.
@MainActor
final class FinderIconItem: NSCollectionViewItem {
  static let identifier = NSUserInterfaceItemIdentifier("finder.iconItem")

  /// Cell box: 96pt wide leaves room for the label + a few px of
  /// breathing room around the icon; 88pt tall fits a 48pt icon, a
  /// 4pt gap, and two text rows at 11pt without truncating common
  /// filenames. Tweaked together with `FinderPaneView+IconView`'s
  /// flow-layout insets — change one and the grid spacing shifts.
  static let itemSize = NSSize(width: 96, height: 88)

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
    label.lineBreakMode = .byTruncatingMiddle
    label.maximumNumberOfLines = 2
    label.cell?.usesSingleLineMode = false
    label.cell?.wraps = true
    label.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(label)
    self.textField = label

    NSLayoutConstraint.activate([
      img.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
      img.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      img.widthAnchor.constraint(equalToConstant: 48),
      img.heightAnchor.constraint(equalToConstant: 48),

      label.topAnchor.constraint(equalTo: img.bottomAnchor, constant: 4),
      label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
      label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
      label.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -2),
    ])
  }

  override var isSelected: Bool {
    didSet { applySelectionAppearance() }
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
  }
}
