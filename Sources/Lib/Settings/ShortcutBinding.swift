import Foundation

/// Per-action override for the default key chord baked into the
/// ``Action`` registry. Stored as the value type of
/// ``E05Preferences/keyboardShortcuts`` keyed by ``Action/id``; the
/// menu and palette consume the merged result so a Settings change
/// reaches every dispatch surface through one path.
///
/// `keyEquivalent == nil` is the explicit "unbound" form so the user
/// can free up a chord they prefer to invoke from the palette only —
/// the menu item then renders without an accelerator and
/// `performKeyEquivalent` no longer claims the keystroke.
public struct ShortcutBinding: Codable, Equatable, Sendable {
  /// Lowercase key character or one of the special-key strings the
  /// ``Action`` registry already uses (e.g. `"l"`, `"\u{8}"`,
  /// `"\t"`). `nil` means the action is explicitly unbound.
  public var keyEquivalent: String?

  /// Raw value of an `NSEvent.ModifierFlags` set, expected to be
  /// masked to `.deviceIndependentFlagsMask`. Storing the raw `UInt`
  /// keeps the JSON shape compact and side-steps `OptionSet`
  /// `Sendable` lint chatter while still round-tripping cleanly
  /// through the `NSEvent.ModifierFlags(rawValue:)` initialiser.
  public var modifierMask: UInt

  public init(keyEquivalent: String?, modifierMask: UInt) {
    self.keyEquivalent = keyEquivalent
    self.modifierMask = modifierMask
  }
}
