import AppKit

/// `NSTableRowView` subclass that dims its cells when the row belongs
/// to a hidden filesystem entry, and restores full opacity while the
/// row is selected. Overriding `isSelected`'s didSet keeps the alpha
/// in lockstep with AppKit's selection state without needing an
/// explicit `tableViewSelectionDidChange` sweep — AppKit writes
/// selection changes directly via the setter on each row view.
///
/// Nothing else is overridden, so the default selection highlight
/// (blue fill in list-view inset style) draws as normal; we only
/// ride on top of it with the alpha tweak.
@MainActor
final class FinderRowView: NSTableRowView {
  var dimmed: Bool = false {
    didSet { applyAlpha() }
  }

  override var isSelected: Bool {
    didSet { applyAlpha() }
  }

  private func applyAlpha() {
    alphaValue = (dimmed && !isSelected) ? Self.dimmedAlpha : 1.0
  }

  private static let dimmedAlpha: CGFloat = 0.5
}
