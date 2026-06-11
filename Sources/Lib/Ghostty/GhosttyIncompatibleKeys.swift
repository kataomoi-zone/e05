import Foundation

/// A single ghostty config key that libghostty parses but the e05
/// host ignores. Held in a static catalog used by the Terminal
/// settings tab to warn users when their `config.ghostty` contains
/// settings that will never take effect.
public struct GhosttyIncompatibleKey: Sendable, Equatable, Hashable {
  public let key: String
  public let reason: String

  public init(key: String, reason: String) {
    self.key = key
    self.reason = reason
  }
}

/// A catalog hit produced by ``GhosttyIncompatibleKeys/scan(_:)``.
/// Carries the 1-based line number so the UI can point at the line
/// in the editor.
public struct GhosttyIncompatibleKeyHit: Sendable, Equatable, Hashable {
  public let lineNumber: Int
  public let key: String
  public let reason: String

  public init(lineNumber: Int, key: String, reason: String) {
    self.lineNumber = lineNumber
    self.key = key
    self.reason = reason
  }
}

/// A ghostty config key that works in e05 except for specific
/// comma-list value tokens. Matching is per token (after splitting
/// the value on commas) so a negated form such as `no-ssh-env`
/// does not trip the warning.
public struct GhosttyIncompatibleValueTokens: Sendable {
  public let key: String
  public let tokens: Set<String>
  public let reason: String

  public init(key: String, tokens: Set<String>, reason: String) {
    self.key = key
    self.tokens = tokens
    self.reason = reason
  }
}

/// Ghostty config keys that the e05 host short-circuits because it
/// owns the surrounding behaviour (window chrome, geometry, quick
/// terminal, macOS app shell). libghostty still parses the key
/// without complaint, so a hand-edited config silently has no
/// effect — the Terminal settings tab uses this catalog to surface
/// the silent-no-op as a warning next to the offending line.
@MainActor
public enum GhosttyIncompatibleKeys {
  public static let catalog: [GhosttyIncompatibleKey] = [
    // Window chrome — e05 owns NSWindow shape (titled + transparent
    // + full size content view + sidebar overlay)
    .init(
      key: "window-decoration",
      reason: "e05 manages window chrome; the NSWindow is always titled and frameless."
    ),
    .init(
      key: "macos-titlebar-style",
      reason: "e05 manages the titlebar (transparent + sidebar overlay)."
    ),
    .init(
      key: "macos-titlebar-proxy-icon",
      reason: "e05 does not display a proxy icon in the titlebar."
    ),
    .init(
      key: "macos-window-buttons",
      reason: "e05 drives traffic-light visibility from the sidebar state machine."
    ),
    .init(
      key: "macos-window-shadow",
      reason: "e05 controls the window shadow."
    ),
    .init(
      key: "macos-non-native-fullscreen",
      reason: "e05 uses the native fullscreen path."
    ),
    .init(
      key: "window-titlebar-background",
      reason: "e05 paints the chrome through AppColors; the titlebar tint is host-managed."
    ),
    .init(
      key: "window-titlebar-foreground",
      reason: "e05 paints the chrome through AppColors; the titlebar tint is host-managed."
    ),
    .init(
      key: "window-subtitle",
      reason: "e05 does not surface a subtitle in the titlebar."
    ),
    .init(
      key: "window-title-font-family",
      reason: "e05 hides the title text via `titleVisibility = .hidden`."
    ),

    // Pane / window padding — e05 manages pane frames via Auto Layout
    .init(
      key: "window-padding-x",
      reason: "e05 manages pane padding via Auto Layout; ghostty padding has no effect."
    ),
    .init(
      key: "window-padding-y",
      reason: "e05 manages pane padding via Auto Layout; ghostty padding has no effect."
    ),
    .init(
      key: "window-padding-balance",
      reason: "e05 manages pane padding via Auto Layout."
    ),
    .init(
      key: "window-padding-color",
      reason: "e05 paints the surrounding chrome through AppColors."
    ),

    // Initial window geometry — e05 sizes the window from screen
    // bounds and saves via session.json
    .init(
      key: "window-height",
      reason: "e05 manages window geometry; size is derived from the visible screen frame."
    ),
    .init(
      key: "window-width",
      reason: "e05 manages window geometry; size is derived from the visible screen frame."
    ),
    .init(
      key: "window-position-x",
      reason: "e05 centres the window on the visible screen frame on first launch."
    ),
    .init(
      key: "window-position-y",
      reason: "e05 centres the window on the visible screen frame on first launch."
    ),
    .init(
      key: "window-save-state",
      reason: "e05 persists workspace state through `session.json`."
    ),
    .init(
      key: "window-step-resize",
      reason: "e05 does not constrain resize steps."
    ),

    // Tabs — e05 uses panes / workspaces, not ghostty's tab system
    .init(
      key: "window-new-tab-position",
      reason: "e05 uses panes and workspaces; tabs are not part of the model."
    ),
    .init(
      key: "window-show-tab-bar",
      reason: "e05 has no tab bar; pane navigation goes through the sidebar."
    ),

    // Surface-spawning behaviour — e05 spawns panes from its own
    // session metadata rather than letting ghostty inherit
    .init(
      key: "initial-window",
      reason: "e05 controls window-on-launch through `session.json`."
    ),
    // window-inherit-working-directory is intentionally NOT listed: e05
    // relies on it (left at its default) to seed a fresh pane's CWD from
    // the focused surface — see GhosttyTerminalView.createSurface, which
    // leaves `working_directory` unset for a non-restored pane.
    .init(
      key: "window-inherit-font-size",
      reason: "e05 manages per-pane font size independently of ghostty's inherit setting."
    ),

    // Appearance / focus — e05 hosts these layers itself
    .init(
      key: "window-theme",
      reason: "e05 forwards `ghostty_app_set_color_scheme` directly from the host theme bridge."
    ),
    .init(
      key: "focus-follows-mouse",
      reason: "e05 manages focus through the workspace model and sidebar."
    ),

    // confirm-close-surface — e05 owns close gestures
    .init(
      key: "confirm-close-surface",
      reason: "e05 has its own pane-close confirmation through the toast system."
    ),

    // Quick terminal — a ghostty-app-only dropdown surface
    .init(
      key: "quick-terminal-position",
      reason: "Quick Terminal is a ghostty app feature; not implemented in e05."
    ),
    .init(
      key: "quick-terminal-size",
      reason: "Quick Terminal is a ghostty app feature; not implemented in e05."
    ),
    .init(
      key: "quick-terminal-screen",
      reason: "Quick Terminal is a ghostty app feature; not implemented in e05."
    ),
    .init(
      key: "quick-terminal-animation-duration",
      reason: "Quick Terminal is a ghostty app feature; not implemented in e05."
    ),
    .init(
      key: "quick-terminal-autohide",
      reason: "Quick Terminal is a ghostty app feature; not implemented in e05."
    ),
    .init(
      key: "quick-terminal-space-behavior",
      reason: "Quick Terminal is a ghostty app feature; not implemented in e05."
    ),
    .init(
      key: "quick-terminal-keyboard-interactivity",
      reason: "Quick Terminal is a ghostty app feature; not implemented in e05."
    ),

    // macOS app shell — e05 ships its own icon, menus, and AppleScript surface
    .init(
      key: "macos-icon",
      reason: "e05 ships its own app icon."
    ),
    .init(
      key: "macos-custom-icon",
      reason: "e05 ships its own app icon."
    ),
    .init(
      key: "macos-icon-frame",
      reason: "e05 ships its own app icon."
    ),
    .init(
      key: "macos-icon-ghost-color",
      reason: "e05 ships its own app icon."
    ),
    .init(
      key: "macos-icon-screen-color",
      reason: "e05 ships its own app icon."
    ),
    .init(
      key: "macos-hidden",
      reason: "e05 does not implement a hidden-on-launch mode."
    ),
    .init(
      key: "macos-applescript",
      reason: "e05 does not expose an AppleScript dictionary."
    ),
    .init(
      key: "macos-shortcuts",
      reason: "e05 manages keyboard shortcuts through its own Shortcuts settings tab."
    ),
    .init(
      key: "macos-menu-bar",
      reason: "e05 builds its own menu bar."
    ),
    .init(
      key: "macos-dock-drop-behavior",
      reason: "e05 routes Dock drops through `e05` CLI + IPC, not ghostty."
    ),
    .init(
      key: "macos-auto-secure-input",
      reason: "e05 does not route secure input through libghostty."
    ),
    .init(
      key: "macos-secure-input-indication",
      reason: "e05 does not surface a secure-input indication."
    ),
    .init(
      key: "auto-update",
      reason: "Auto-update is a ghostty app feature; e05 ships without an update channel."
    ),
    .init(
      key: "auto-update-channel",
      reason: "Auto-update is a ghostty app feature; e05 ships without an update channel."
    ),
  ]

  /// Keys that take effect in e05 except for specific value tokens.
  /// The vendored shell-integration ssh wrappers shell out to the
  /// ghostty CLI (`$GHOSTTY_BIN_DIR/ghostty +ssh`), which e05 does
  /// not bundle — opting in replaces `ssh` with a wrapper that can
  /// never resolve its binary, breaking the command outright rather
  /// than degrading.
  public static let valueTokenCatalog: [GhosttyIncompatibleValueTokens] = [
    .init(
      key: "shell-integration-features",
      tokens: ["ssh-env", "ssh-terminfo"],
      reason:
        "e05 does not bundle the ghostty CLI; the ssh-env / ssh-terminfo wrappers would break the ssh command."
    )
  ]

  /// Walk `text` line by line and surface every catalog hit. Lines
  /// starting with `#` (comment) or empty lines are skipped, so
  /// commented-out keys do not produce noise. The matcher reads the
  /// key as everything before the first `=`, mirroring ghostty's own
  /// flat `key = value` lexer. Keys absent from the key catalog are
  /// additionally checked against ``valueTokenCatalog`` for value
  /// tokens that only break with specific opt-ins.
  public static func scan(_ text: String) -> [GhosttyIncompatibleKeyHit] {
    var hits: [GhosttyIncompatibleKeyHit] = []
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for (index, raw) in lines.enumerated() {
      let trimmed = raw.drop(while: { $0 == " " || $0 == "\t" })
      if trimmed.isEmpty || trimmed.first == "#" { continue }
      guard let eq = trimmed.firstIndex(of: "=") else { continue }
      let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
      if let reason = lookupByKey[key] {
        hits.append(.init(lineNumber: index + 1, key: key, reason: reason))
        continue
      }
      for entry in valueTokenCatalog where entry.key == key {
        let valueTokens = trimmed[trimmed.index(after: eq)...]
          .split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespaces) }
        if valueTokens.contains(where: { entry.tokens.contains($0) }) {
          hits.append(.init(lineNumber: index + 1, key: key, reason: entry.reason))
          break
        }
      }
    }
    return hits
  }

  /// Catalog key → reason lookup, built via a manual fold so a
  /// duplicate-key typo in ``catalog`` keeps the first occurrence
  /// rather than tripping `Dictionary(uniqueKeysWithValues:)`'s
  /// runtime precondition and crashing the Settings UI on open.
  private static let lookupByKey: [String: String] = {
    var dict: [String: String] = [:]
    for entry in catalog where dict[entry.key] == nil {
      dict[entry.key] = entry.reason
    }
    return dict
  }()
}
