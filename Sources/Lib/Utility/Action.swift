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

  /// Compact title used by context menus where space is tighter than
  /// the palette and the conventional menu phrasing differs (e.g.
  /// palette "Reload Page" → menu "Reload", palette "Toggle Web
  /// Inspector" → menu "Web Inspector"). `nil` (default) keeps the
  /// palette `title` as the single source of truth — only set this
  /// when the menu phrasing genuinely needs to diverge.
  public let menuTitle: String?

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
    menuTitle: String? = nil,
    keyEquivalent: String? = nil,
    modifierMask: NSEvent.ModifierFlags = [.command],
    handler: @escaping @MainActor () -> Void,
    validate: (@MainActor () -> (enabled: Bool, title: String?))? = nil,
    separatorBefore: Bool = false
  ) {
    self.id = id
    self.title = title
    self.menuTitle = menuTitle
    self.keyEquivalent = keyEquivalent
    self.modifierMask = modifierMask
    self.handler = handler
    self.validate = validate
    self.separatorBefore = separatorBefore
    self.keyLabel = Self.buildKeyLabel(key: keyEquivalent, mask: modifierMask)
  }

  // MARK: - Key Label

  /// Render `key` + `mask` as the `⌃⌥⇧⌘<KEY>` glyph string the
  /// menu bar already draws. Exposed so the Shortcuts tab can label
  /// recorded overrides through the same path the registry uses for
  /// its baked-in defaults. `nonisolated` because the body touches
  /// only the immutable `specialKeyGlyphs` table — callers in plain
  /// `struct` contexts (SwiftUI Row helpers) need this to be
  /// reachable without an actor hop.
  public nonisolated static func buildKeyLabel(key: String?, mask: NSEvent.ModifierFlags) -> String? {
    // Treat empty string as unbound. A stray "" can land here if a
    // recorder ever persists a blank chord; without this guard the
    // joined label collapses to "" and the row renders empty.
    guard let key, !key.isEmpty else { return nil }
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
  /// label NSMenu draws in the Pane menu. `nonisolated` so
  /// ``buildKeyLabel(key:mask:)`` can read it from a plain
  /// non-MainActor caller (SwiftUI row helpers, see Shortcuts tab).
  private nonisolated static let specialKeyGlyphs: [String: String] = [
    "\u{8}": "⌫",
    "\u{7F}": "⌦",
    "\u{1B}": "⎋",
    "\t": "⇥",
    "\r": "⏎",
    " ": "␣",
  ]

  // MARK: - Overrides

  /// Return a copy of this action with the binding replaced by
  /// `override`. `nil` leaves the static default in place so the
  /// resolver can route every action through the same `.map`
  /// regardless of whether the user has customised it.
  ///
  /// The handler, validator and `separatorBefore` flag carry over
  /// unchanged so dispatch identity and menu layout stay locked to
  /// the registry; only the key chord (and the derived `keyLabel`,
  /// rebuilt by the regular initialiser) differ.
  public func applyingOverride(_ override: ShortcutBinding?) -> Action {
    guard let override else { return self }
    let mask = NSEvent.ModifierFlags(rawValue: override.modifierMask)
      .intersection(.deviceIndependentFlagsMask)
    return Action(
      id: id,
      title: title,
      menuTitle: menuTitle,
      keyEquivalent: override.keyEquivalent,
      modifierMask: mask,
      handler: handler,
      validate: validate,
      separatorBefore: separatorBefore
    )
  }
}
