import AppKit

/// A user-facing command that can be invoked from the menu bar or the
/// command palette (`:` prefix in the URL bar).
///
/// Actions are the single source of truth for the app's top-level
/// operations. Both `AppDelegate.setupMenuKeyBindings()` and the upcoming
/// command-palette dispatcher iterate over the same `[Action]` array,
/// so menu items and palette entries can never drift out of sync.
@MainActor
public struct Action {
  /// Stable identifier used for fuzzy matching and menu-item reuse
  /// (e.g. `"focus_right"`).
  public let id: String

  /// Human-readable title displayed in the menu bar and palette
  /// (e.g. "Focus Right").
  public let title: String

  /// Key equivalent for the menu item (e.g. "l"). `nil` means no
  /// keyboard shortcut bound through the menu.
  public let keyEquivalent: String?

  /// Modifier mask paired with `keyEquivalent`. Defaults to `.command`.
  public let modifierMask: NSEvent.ModifierFlags

  /// Short human-readable representation of the key binding for display
  /// in the command palette accessory label (e.g. "⌥⌃L"). Computed from
  /// `keyEquivalent` + `modifierMask` at init time.
  public let keyLabel: String?

  /// The operation to perform. Captured `[weak paneContainer]` to avoid
  /// retain cycles.
  public let handler: @MainActor () -> Void

  /// Optional validator called by `NSMenuItemValidation`. Returns
  /// `(enabled, titleOverride)`. When `nil`, the menu item is always
  /// enabled and uses the original `title`.
  public let validate: (@MainActor () -> (enabled: Bool, title: String?))?

  /// Whether this action creates a separator *before* itself in the
  /// menu. Layout-only metadata — the action registry is order-sensitive
  /// and separators are encoded inline rather than as standalone entries.
  public let separatorBefore: Bool

  public init(
    id: String,
    title: String,
    keyEquivalent: String? = nil,
    modifierMask: NSEvent.ModifierFlags = [.command],
    handler: @escaping @MainActor () -> Void,
    validate: (@MainActor () -> (enabled: Bool, title: String?))? = nil,
    separatorBefore: Bool = false
  ) {
    self.id = id
    self.title = title
    self.keyEquivalent = keyEquivalent
    self.modifierMask = modifierMask
    self.handler = handler
    self.validate = validate
    self.separatorBefore = separatorBefore
    self.keyLabel = Self.buildKeyLabel(key: keyEquivalent, mask: modifierMask)
  }

  // MARK: - Key Label

  private static func buildKeyLabel(key: String?, mask: NSEvent.ModifierFlags) -> String? {
    guard let key else { return nil }
    var parts: [String] = []
    if mask.contains(.control) { parts.append("⌃") }
    if mask.contains(.option) { parts.append("⌥") }
    if mask.contains(.shift) { parts.append("⇧") }
    if mask.contains(.command) { parts.append("⌘") }
    parts.append(specialKeyGlyphs[key] ?? key.uppercased())
    return parts.joined()
  }

  /// Translate unprintable control characters into the Apple menu
  /// glyphs they represent. Without this, a palette row bound to
  /// `"\u{8}"` (NSBackspaceCharacter) would render as `⌘` followed by
  /// an invisible BS byte; with the map it reads as `⌘⌫` — the same
  /// label NSMenu draws in the Pane menu.
  private static let specialKeyGlyphs: [String: String] = [
    "\u{8}": "⌫",
    "\u{7F}": "⌦",
    "\u{1B}": "⎋",
    "\t": "⇥",
    "\r": "⏎",
    " ": "␣",
  ]
}
