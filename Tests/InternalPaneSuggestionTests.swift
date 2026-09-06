import Testing

@testable import E05Lib

/// `PaneContainerViewController.internalPaneMatches` decides which
/// non-web panes a URL-bar query names. The rows it drives are the only
/// way to reach a terminal / finder pane from the URL bar without
/// knowing the `e05://` scheme, so the matching rule is worth pinning:
/// too eager and it displaces real matches on ordinary queries, too shy
/// and the feature is unreachable.
@MainActor
@Suite("PaneContainerViewController.internalPaneMatches")
struct InternalPaneSuggestionTests {
  @Test("a full name matches its own destination only")
  func fullNameMatches() {
    #expect(PaneContainerViewController.internalPaneMatches(query: "terminal") == [.terminal])
    #expect(PaneContainerViewController.internalPaneMatches(query: "finder") == [.finder])
    #expect(PaneContainerViewController.internalPaneMatches(query: "start") == [.start])
  }

  @Test("a prefix of two or more characters matches")
  func prefixMatches() {
    #expect(PaneContainerViewController.internalPaneMatches(query: "te") == [.terminal])
    #expect(PaneContainerViewController.internalPaneMatches(query: "term") == [.terminal])
    #expect(PaneContainerViewController.internalPaneMatches(query: "fi") == [.finder])
    #expect(PaneContainerViewController.internalPaneMatches(query: "st") == [.start])
  }

  @Test("a single character matches nothing")
  func singleCharacterIsIgnored() {
    // One letter prefixes too much of the alphabet to read as intent,
    // and the row would turn up on every first keystroke.
    #expect(PaneContainerViewController.internalPaneMatches(query: "t").isEmpty)
    #expect(PaneContainerViewController.internalPaneMatches(query: "f").isEmpty)
  }

  @Test("the scheme on its own offers every destination")
  func schemeListsEverything() {
    // Typing the scheme is asking what it has, so it lists the set. The
    // punctuation variants are the keystrokes on the way to a full
    // `e05://` address.
    let all = PaneContainerViewController.InternalPaneDestination.allCases
    for query in ["e05", "e05:", "e05:/", "e05://", "E05://"] {
      #expect(PaneContainerViewController.internalPaneMatches(query: query) == all)
    }
  }

  @Test("a name after the scheme narrows, with no length minimum")
  func schemeThenName() {
    // The scheme already said what the user is after, so one character
    // is a real narrowing here where it would be noise on its own.
    #expect(PaneContainerViewController.internalPaneMatches(query: "e05://f") == [.finder])
    #expect(PaneContainerViewController.internalPaneMatches(query: "e05://terminal") == [.terminal])
    #expect(PaneContainerViewController.internalPaneMatches(query: "e05://zz").isEmpty)
  }

  @Test("surrounding whitespace and case do not change the match")
  func normalisesInput() {
    #expect(PaneContainerViewController.internalPaneMatches(query: "  Term ") == [.terminal])
    #expect(PaneContainerViewController.internalPaneMatches(query: "FINDER") == [.finder])
  }

  @Test("a name inside a longer query matches nothing")
  func substringMatchesNothing() {
    // Substring matching would fire on half the web: "terminal" appears
    // mid-phrase in plenty of ordinary queries, and a row that switches
    // the pane's content type is not something to offer on a loose match.
    #expect(PaneContainerViewController.internalPaneMatches(query: "erminal").isEmpty)
    #expect(PaneContainerViewController.internalPaneMatches(query: "my terminal").isEmpty)
    #expect(PaneContainerViewController.internalPaneMatches(query: "terminal emulator").isEmpty)
    #expect(PaneContainerViewController.internalPaneMatches(query: "").isEmpty)
  }
}
