import Foundation

/// Content mode of the sidebar's mutable top area. Stage 3-A wires the
/// selector and keeps `.tabs` fully functional (showing the worklane);
/// the other three modes display placeholder views until their list
/// implementations land in stages 3-B / 3-C / 3-D. Stage 3-D also
/// removes the corresponding `PaneAddress.Kind.history`/`.bookmarks`/
/// `.downloads` special panes so these sidebar modes become the sole
/// entry points for that functionality.
///
/// `allCases` order defines the visual row order in the places section.
enum SidebarMode: CaseIterable {
    case tabs
    case bookmarks
    case history
    case downloads

    var title: String {
        switch self {
        case .tabs: return "Tabs"
        case .bookmarks: return "Bookmarks"
        case .history: return "History"
        case .downloads: return "Downloads"
        }
    }

    /// SF Symbol used as the row icon in the places section.
    var symbolName: String {
        switch self {
        case .tabs: return "text.rectangle"
        case .bookmarks: return "bookmark"
        case .history: return "clock"
        case .downloads: return "arrow.down.circle"
        }
    }

    /// Text shown in the placeholder view for modes that don't have a
    /// real content view wired yet. Empty for modes backed by a real
    /// view (`.tabs` → worklane, `.bookmarks` → bookmarks list,
    /// `.history` → history list) since the placeholder is hidden in
    /// those cases anyway; the string is still assigned unconditionally
    /// so the placeholder never carries stale text from a previous mode
    /// (which accessibility tooling or future fade animations could
    /// expose).
    var placeholderMessage: String {
        switch self {
        case .tabs, .bookmarks, .history: return ""
        case .downloads: return "Downloads (coming soon)"
        }
    }
}
