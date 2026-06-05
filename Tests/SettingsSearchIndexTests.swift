import Testing

@testable import E05Lib

@Suite("SettingsSearchIndex")
struct SettingsSearchIndexTests {
  @Test("a blank query returns no results")
  func blankQuery() {
    #expect(SettingsSearchIndex.search("").isEmpty)
    #expect(SettingsSearchIndex.search("   ").isEmpty)
  }

  @Test("a query matches a visible section title")
  func titleMatch() {
    let results = SettingsSearchIndex.search("theme")
    #expect(results.contains { $0.title == "Theme" })
  }

  @Test("a query matches a keyword synonym absent from the title")
  func keywordMatch() {
    // "dark mode" is a Theme synonym; the visible title is "Theme".
    let results = SettingsSearchIndex.search("dark mode")
    #expect(results.first?.title == "Theme")
  }

  @Test("search is case-insensitive")
  func caseInsensitive() {
    let upper = SettingsSearchIndex.search("THEME")
    let lower = SettingsSearchIndex.search("theme")
    #expect(!upper.isEmpty)
    #expect(upper.map(\.id) == lower.map(\.id))
  }

  @Test("a title-prefix match outranks keyword-only matches")
  func prefixRanking() {
    // "Search Engine" begins with "search"; other rows only reference
    // search via keywords, so the titled row must come first.
    let results = SettingsSearchIndex.search("search")
    #expect(results.first?.title == "Search Engine")
  }

  @Test("typing a tab name surfaces that tab's rows")
  func tabNameMatch() {
    let results = SettingsSearchIndex.search("appearance")
    #expect(results.contains { $0.tab == .appearance && $0.title == "Pane Gap" })
  }

  @Test("a keyword-prefix match outranks a keyword-substring match")
  func keywordPrefixRanking() {
    // "color" prefixes the Workspace Accent keyword "color" (higher
    // score) but only appears mid-keyword in Terminal's "terminal
    // colors"; neither title contains it, so accent ranks first.
    let results = SettingsSearchIndex.search("color")
    #expect(results.first?.title == "Workspace Accent")
    #expect(results.contains { $0.title == "Terminal Configuration" })
  }

  @Test("internal and full-width whitespace in the query collapses")
  func whitespaceNormalisation() {
    // Sloppy spacing still matches the multi-word "dark mode" keyword.
    #expect(SettingsSearchIndex.search("dark   mode").first?.title == "Theme")
    #expect(SettingsSearchIndex.search("dark\u{3000}mode").first?.title == "Theme")
  }

  @Test("a whitespace-only query returns no results")
  func whitespaceOnlyQuery() {
    #expect(SettingsSearchIndex.search("\u{3000}").isEmpty)
    #expect(SettingsSearchIndex.search(" \t \u{3000} ").isEmpty)
  }

  @Test("results are stably ordered across repeated calls")
  func stableOrdering() {
    // Several permission rows share the same keyword score; the
    // tie-break must yield the same order every call.
    let first = SettingsSearchIndex.search("permission").map(\.id)
    let second = SettingsSearchIndex.search("permission").map(\.id)
    #expect(!first.isEmpty)
    #expect(first == second)
  }

  @Test("an unmatched query yields nothing")
  func noMatch() {
    #expect(SettingsSearchIndex.search("zzzznotathing").isEmpty)
  }

  @Test("every tab is reachable from the index")
  func everyTabCovered() {
    let covered = Set(SettingsSearchIndex.entries.map(\.tab))
    #expect(covered == Set(SettingsTab.allCases))
  }

  @Test("entry ids are unique")
  func uniqueIDs() {
    let ids = SettingsSearchIndex.entries.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  @Test("every entry carries at least one keyword")
  func keywordsPresent() {
    for entry in SettingsSearchIndex.entries {
      #expect(!entry.keywords.isEmpty, "\(entry.id) has no keywords")
    }
  }
}
