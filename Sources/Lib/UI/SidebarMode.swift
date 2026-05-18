/// Content mode of the sidebar's mutable top area. Each mode maps to
/// a dedicated view slot in the overlay — `.tabs` shows the worklane
/// tree; the others host their respective list views. The sidebar is
/// the sole entry point for the history / bookmarks / downloads /
/// extensions features.
///
/// `allCases` order defines the visual row order in the places section.
enum SidebarMode: CaseIterable {
  case tabs
  case bookmarks
  case history
  case downloads
  case extensions

  var title: String {
    switch self {
    case .tabs: return "Tabs"
    case .bookmarks: return "Bookmarks"
    case .history: return "History"
    case .downloads: return "Downloads"
    case .extensions: return "Extensions"
    }
  }

  /// SF Symbol used as the row icon in the places section.
  var symbolName: String {
    switch self {
    case .tabs: return "text.rectangle"
    case .bookmarks: return "bookmark"
    case .history: return "clock"
    case .downloads: return "arrow.down.circle"
    case .extensions: return "puzzlepiece.extension"
    }
  }

  /// Text shown in the placeholder view for modes that don't have a
  /// real content view wired yet. Every current mode ships a real
  /// view so the string is empty, but the placeholder is still
  /// assigned on every mode change so it never carries stale text
  /// from a previous mode (which accessibility tooling or a future
  /// fade animation could expose).
  var placeholderMessage: String {
    switch self {
    case .tabs, .bookmarks, .history, .downloads, .extensions: return ""
    }
  }
}
