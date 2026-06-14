import Foundation

/// Pane kind seeded into a freshly created workspace. Resolves
/// through ``E05Preferences/initialPaneKind``.
///
/// - ``start`` — the native start page (`e05://start`) launcher. The
///   default: a new workspace opens on the new-pane launcher.
/// - ``terminal`` — a terminal pane.
/// - ``browser`` — the home-URL page when set, otherwise a blank
///   browser, via ``PaneAddress/newPaneHome``.
/// - ``finder`` — a native file-browser pane rooted at the home
///   directory.
///
/// Unknown identifiers resolve to ``start`` so a hand-edited
/// `preferences.json` carrying a stale name lands on the default.
/// Workspaces opened by a link ("Open in New Workspace") bypass this
/// preference entirely — they seed the link's browser pane instead.
public enum InitialPaneKindPreset: String, CaseIterable, Identifiable, Sendable {
  case start
  case terminal
  case browser
  case finder

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .start: "Start page"
    case .terminal: "Terminal"
    case .browser: "Browser"
    case .finder: "Finder"
    }
  }

  /// SF Symbol shown next to the label in the picker.
  public var symbol: String {
    switch self {
    case .start: "sparkles"
    case .terminal: "apple.terminal"
    case .browser: "globe"
    case .finder: "folder"
    }
  }

  /// Address used to seed the workspace's first pane. ``browser``
  /// resolves the home-URL preference at call time (so toggling the
  /// setting takes effect on the next new workspace). ``finder`` roots
  /// at the home directory by leaving the path empty; the workspace
  /// seed path overrides this with the configured new-finder default
  /// (see `configuredInitialPaneAddress`).
  @MainActor
  public var address: PaneAddress {
    switch self {
    case .start: .start
    case .terminal: .terminal
    case .browser: .newPaneHome
    case .finder: .finder(path: "")
    }
  }

  public static func resolve(_ identifier: String?) -> InitialPaneKindPreset {
    guard let identifier else { return .start }
    return InitialPaneKindPreset(rawValue: identifier) ?? .start
  }
}
