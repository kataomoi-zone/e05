import Foundation

/// Pane kind seeded into a freshly created workspace. Resolves
/// through ``E05Preferences/initialPaneKind``.
///
/// - ``terminal`` — a terminal pane (the historical default).
/// - ``browser`` — the home-URL page when set, otherwise a blank
///   browser, via ``PaneAddress/newPaneHome``.
/// - ``finder`` — a native file-browser pane rooted at the home
///   directory.
///
/// Unknown identifiers resolve to ``terminal`` so a hand-edited
/// `preferences.json` carrying a stale name keeps the old default.
/// Workspaces opened by a link ("Open in New Workspace") bypass this
/// preference entirely — they seed the link's browser pane instead.
public enum InitialPaneKindPreset: String, CaseIterable, Identifiable, Sendable {
  case terminal
  case browser
  case finder

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .terminal: "Terminal"
    case .browser: "Browser"
    case .finder: "Finder"
    }
  }

  /// SF Symbol shown next to the label in the picker.
  public var symbol: String {
    switch self {
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
    case .terminal: .terminal
    case .browser: .newPaneHome
    case .finder: .finder(path: "")
    }
  }

  public static func resolve(_ identifier: String?) -> InitialPaneKindPreset {
    guard let identifier else { return .terminal }
    return InitialPaneKindPreset(rawValue: identifier) ?? .terminal
  }
}
