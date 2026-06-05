import Foundation

/// One searchable setting surfaced by the cross-tab Settings search.
///
/// `title` is the user-facing label shown as the result's primary
/// line; the owning ``SettingsTab`` renders as the subtitle and is
/// where selecting the result navigates. `keywords` are synonyms that
/// widen matching beyond the visible label so a user typing "dark
/// mode" still finds the row titled "Theme".
struct SettingsSearchEntry: Identifiable, Sendable {
  let id: String
  let title: String
  let tab: SettingsTab
  let keywords: [String]
}

/// Static catalogue backing the cross-tab Settings search field.
///
/// Entries are authored at section granularity (one per visible
/// section or sub-sidebar category) rather than per individual
/// control: section titles plus `keywords` cover the realistic search
/// vocabulary without the upkeep of mirroring every toggle. Selecting
/// a result navigates to the owning tab — section-level scroll/
/// highlight is a deferred follow-up.
enum SettingsSearchIndex {
  static let entries: [SettingsSearchEntry] =
    generalEntries
    + terminalEntries
    + sitesEntries
    + appearanceEntries
    + shortcutEntries
    + contentBlockerEntries
    + aboutEntries

  /// Rank matching entries for `rawQuery`, best match first. Returns
  /// an empty array for a blank query so the caller can fall back to
  /// the full tab list. Whitespace runs (including full-width spaces)
  /// collapse to single spaces so a multi-word keyword such as "dark
  /// mode" still matches sloppy spacing.
  static func search(_ rawQuery: String) -> [SettingsSearchEntry] {
    let query = rawQuery.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !query.isEmpty else { return [] }

    let scored = entries.compactMap { entry -> (entry: SettingsSearchEntry, score: Int)? in
      guard let score = matchScore(entry, query: query) else { return nil }
      return (entry, score)
    }

    return
      scored
      .sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        // Stable tie-break so equal-score rows do not shuffle between
        // keystrokes: title first, then the unique id as a backstop
        // for entries that ever share a title.
        let byTitle = lhs.entry.title.localizedCaseInsensitiveCompare(rhs.entry.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return lhs.entry.id < rhs.entry.id
      }
      .map(\.entry)
  }

  /// Score an entry against an already-normalised (trimmed,
  /// lowercased) query. Title matches outrank keyword matches, which
  /// outrank a match on the tab name alone, so the most specific row
  /// floats to the top. `nil` means no match.
  private static func matchScore(_ entry: SettingsSearchEntry, query: String) -> Int? {
    let title = entry.title.lowercased()
    if title.hasPrefix(query) { return 100 }
    if title.contains(query) { return 80 }

    var keywordScore = 0
    for keyword in entry.keywords {
      let candidate = keyword.lowercased()
      if candidate.hasPrefix(query) {
        keywordScore = max(keywordScore, 60)
      } else if candidate.contains(query) {
        keywordScore = max(keywordScore, 50)
      }
    }
    if keywordScore > 0 { return keywordScore }

    // Typing a tab name ("appearance") lists that tab's rows even
    // when neither the title nor a keyword matches.
    if entry.tab.title.lowercased().contains(query) { return 40 }

    return nil
  }

  // MARK: - Catalogue

  private static let generalEntries: [SettingsSearchEntry] = [
    SettingsSearchEntry(
      id: "general.homepage", title: "Homepage", tab: .general,
      keywords: ["home page", "new pane", "start page", "startup", "blank page", "specific url"]),
    SettingsSearchEntry(
      id: "general.new-workspace", title: "New Workspace", tab: .general,
      keywords: ["initial pane", "default pane", "seed pane", "terminal", "browser", "finder"]),
    SettingsSearchEntry(
      id: "general.search-engine", title: "Search Engine", tab: .general,
      keywords: ["search", "duckduckgo", "google", "bing", "brave", "search template", "query"]),
    SettingsSearchEntry(
      id: "general.downloads", title: "Downloads", tab: .general,
      keywords: ["download", "save location", "download folder", "ask where to save"]),
  ]

  private static let terminalEntries: [SettingsSearchEntry] = [
    SettingsSearchEntry(
      id: "terminal.config", title: "Terminal Configuration", tab: .terminal,
      keywords: [
        "config.ghostty", "ghostty", "terminal config", "font", "terminal theme",
        "terminal colors", "terminal keybindings",
      ])
  ]

  private static let sitesEntries: [SettingsSearchEntry] = [
    SettingsSearchEntry(
      id: "sites.mute", title: "Mute", tab: .sites,
      keywords: ["mute", "audio", "sound", "silence"]),
    SettingsSearchEntry(
      id: "sites.camera", title: "Camera", tab: .sites,
      keywords: ["camera", "permission", "video"]),
    SettingsSearchEntry(
      id: "sites.microphone", title: "Microphone", tab: .sites,
      keywords: ["microphone", "mic", "audio input", "permission"]),
    SettingsSearchEntry(
      id: "sites.location", title: "Location", tab: .sites,
      keywords: ["location", "geolocation", "gps", "permission"]),
    SettingsSearchEntry(
      id: "sites.notifications", title: "Notifications", tab: .sites,
      keywords: ["notifications", "web notifications", "alerts", "permission"]),
    SettingsSearchEntry(
      id: "sites.suspend", title: "Suspend", tab: .sites,
      keywords: ["suspend", "idle", "sleep panes", "inactivity", "keep active", "memory"]),
  ]

  private static let appearanceEntries: [SettingsSearchEntry] = [
    SettingsSearchEntry(
      id: "appearance.theme", title: "Theme", tab: .appearance,
      keywords: ["theme", "dark mode", "light mode", "appearance", "system"]),
    SettingsSearchEntry(
      id: "appearance.accent", title: "Workspace Accent", tab: .appearance,
      keywords: ["accent", "color", "palette", "subway", "metro", "unicorn", "stripes"]),
    SettingsSearchEntry(
      id: "appearance.border", title: "Pane Border", tab: .appearance,
      keywords: ["border", "focus outline", "border width", "thin", "bold"]),
    SettingsSearchEntry(
      id: "appearance.gap", title: "Pane Gap", tab: .appearance,
      keywords: ["gap", "spacing", "padding", "margin"]),
    SettingsSearchEntry(
      id: "appearance.corners", title: "Surface Corners", tab: .appearance,
      keywords: ["corner", "radius", "rounded", "sharp"]),
    SettingsSearchEntry(
      id: "appearance.width-cycle", title: "Cycle Width Presets", tab: .appearance,
      keywords: ["width", "column width", "cycle width", "presets", "points", "fraction"]),
  ]

  /// Built from ``ShortcutCategory/allCases`` so the catalogue stays
  /// in sync with the Shortcuts sub-sidebar; a leading umbrella entry
  /// covers generic terms ("hotkey", "keybinding").
  private static let shortcutEntries: [SettingsSearchEntry] =
    [
      SettingsSearchEntry(
        id: "shortcuts.all", title: "Keyboard Shortcuts", tab: .shortcuts,
        keywords: ["shortcut", "keybinding", "hotkey", "key", "customize keys"])
    ]
    + ShortcutCategory.allCases.map { category in
      SettingsSearchEntry(
        id: "shortcuts.\(category.rawValue)",
        title: category.title,
        tab: .shortcuts,
        keywords: shortcutKeywords[category] ?? [])
    }

  private static let shortcutKeywords: [ShortcutCategory: [String]] = [
    .panes: ["pane", "split", "close pane", "undo close"],
    .focus: ["focus", "move pane", "fold", "cycle width", "align column"],
    .findURL: ["find", "url bar", "find next"],
    .browser: ["reload", "back", "forward", "zoom", "bookmark", "inspector"],
    .finder: ["files", "finder", "trash", "new folder", "hidden files"],
    .window: [
      "settings", "command palette", "sidebar", "tabs", "history", "downloads", "extensions",
    ],
    .workspace: ["workspace", "new workspace", "private", "switch workspace"],
  ]

  private static let contentBlockerEntries: [SettingsSearchEntry] = [
    SettingsSearchEntry(
      id: "contentblocker.overview", title: "Content Blocker", tab: .contentBlocker,
      keywords: ["ad blocker", "adblock", "block ads", "tracker", "privacy"]),
    SettingsSearchEntry(
      id: "contentblocker.filter-lists", title: "Filter Lists", tab: .contentBlocker,
      keywords: [
        "filter lists", "easylist", "easyprivacy", "ublock", "default lists",
        "optional lists", "custom filter",
      ]),
    SettingsSearchEntry(
      id: "contentblocker.whitelist", title: "Whitelist", tab: .contentBlocker,
      keywords: ["whitelist", "allowlist", "exception", "disable blocking"]),
    SettingsSearchEntry(
      id: "contentblocker.auto-update", title: "Auto-Update", tab: .contentBlocker,
      keywords: ["auto-update", "schedule", "refresh", "update filters"]),
  ]

  private static let aboutEntries: [SettingsSearchEntry] = [
    SettingsSearchEntry(
      id: "about.app", title: "About", tab: .about,
      keywords: ["about", "version", "build", "app info"]),
    SettingsSearchEntry(
      id: "about.backup", title: "Backup", tab: .about,
      keywords: ["backup", "export", "import", "preferences file"]),
    SettingsSearchEntry(
      id: "about.reset", title: "Reset", tab: .about,
      keywords: [
        "reset", "clear", "defaults", "clear history", "clear bookmarks",
        "clear cache", "clear downloads",
      ]),
    SettingsSearchEntry(
      id: "about.acknowledgements", title: "Acknowledgements", tab: .about,
      keywords: ["acknowledgements", "license", "open source", "credits", "ghostty"]),
  ]
}
