import Foundation

/// Pane opened below the focused one by `Split Vertical`. Resolves
/// through ``E05Preferences/splitPaneKind``.
///
/// - ``terminal`` — a terminal pane (the historical split, cwd from
///   ``E05Preferences/newTerminalDirectory``).
/// - ``browser`` — the start page / configured home URL, via
///   ``PaneAddress/newPaneHome``.
/// - ``finder`` — a finder pane rooted at
///   ``E05Preferences/newFinderDirectory`` (home by default).
/// - ``duplicate`` — a copy of the focused pane: same URL (with its
///   back/forward + scroll state) for a browser, same cwd for a
///   terminal, same path for a finder. The default.
///
/// An unset / unknown identifier resolves to ``duplicate`` — splitting
/// usually means "another of what I'm looking at".
public enum SplitPaneKindPreset: String, CaseIterable, Identifiable, Sendable {
  case terminal
  case browser
  case finder
  case duplicate

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .terminal: "Terminal"
    case .browser: "Browser"
    case .finder: "Finder"
    case .duplicate: "Duplicate focused pane"
    }
  }

  /// SF Symbol shown next to the label in the picker.
  public var symbol: String {
    switch self {
    case .terminal: "apple.terminal"
    case .browser: "globe"
    case .finder: "folder"
    case .duplicate: "plus.square.on.square"
    }
  }

  public static func resolve(_ identifier: String?) -> SplitPaneKindPreset {
    guard let identifier else { return .duplicate }
    return SplitPaneKindPreset(rawValue: identifier) ?? .duplicate
  }
}
