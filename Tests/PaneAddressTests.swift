import Testing

@testable import E05Lib

@Suite("PaneAddress")
struct PaneAddressTests {
  @Test("terminal address resolves to terminal kind")
  func terminalKind() {
    #expect(PaneAddress.terminal.kind == .terminal)
  }

  @Test("settings address resolves to settings kind")
  func settingsKind() {
    #expect(PaneAddress.settings.kind == .settings)
  }

  // MARK: - Finder

  @Test("bare e05://finder resolves to finder kind with empty path")
  func finderBareKind() {
    let addr = PaneAddress("e05://finder")!
    #expect(addr.kind == .finder)
    #expect(addr.currentPath.isEmpty)
  }

  @Test("e05://finder with path resolves to finder kind and exposes the path")
  func finderWithPath() {
    let addr = PaneAddress("e05://finder/Users/kawarimidoll")!
    #expect(addr.kind == .finder)
    #expect(addr.currentPath == "/Users/kawarimidoll")
  }

  @Test("e05://finder trailing slash preserves the root path")
  func finderRootPath() {
    let addr = PaneAddress("e05://finder/")!
    #expect(addr.kind == .finder)
    #expect(addr.currentPath == "/")
  }

  @Test("PaneAddress.finder(path:) round-trips through the URL string")
  func finderBuilderRoundTrip() {
    let built = PaneAddress.finder(path: "/Users/kawarimidoll")
    let parsed = PaneAddress(built.description)!
    #expect(parsed.kind == .finder)
    #expect(parsed.currentPath == "/Users/kawarimidoll")
  }

  @Test("PaneAddress.finder(path:) percent-encodes non-ASCII characters")
  func finderBuilderEncodesUnicode() {
    // Japanese, spaces, and other non-ASCII bytes must survive a round
    // trip so session.json entries referencing directories like
    // `~/Documents/日本語フォルダ/` restore without corruption.
    let original = "/Users/kawarimidoll/日本語 フォルダ"
    let built = PaneAddress.finder(path: original)
    let parsed = PaneAddress(built.description)!
    #expect(parsed.kind == .finder)
    #expect(parsed.currentPath == original)
  }

  @Test("finder displayString shows non-ASCII paths decoded for the URL bar")
  func finderDisplayStringDecodes() {
    // The URL bar should show `e05://finder/Users/you/日本語フォルダ`
    // rather than the percent-encoded form; that form makes the URL
    // bar the authoritative cwd display for a non-technical user.
    let built = PaneAddress.finder(path: "/Users/kawarimidoll/日本語フォルダ")
    #expect(built.displayString == "e05://finder/Users/kawarimidoll/日本語フォルダ")
    // Round-trip: parsing the display string should land back on the
    // same decoded path so typing the decoded URL into the URL bar
    // navigates as expected.
    let parsed = PaneAddress(built.displayString)!
    #expect(parsed.kind == .finder)
    #expect(parsed.currentPath == "/Users/kawarimidoll/日本語フォルダ")
  }

  @Test("displayString falls back to absoluteString for non-finder addresses")
  func displayStringBrowserFallback() {
    let https = PaneAddress("https://example.com/path")!
    #expect(https.displayString == https.url.absoluteString)
    #expect(PaneAddress.terminal.displayString == "e05://terminal")
    // Bare `e05://finder` (no path) also falls back so the URL bar
    // shows exactly what's in the address rather than inventing a
    // trailing slash.
    let bareFinder = PaneAddress("e05://finder")!
    #expect(bareFinder.displayString == "e05://finder")
  }

  @Test("PaneAddress accepts raw non-ASCII URL strings")
  func initAcceptsRawUnicode() {
    // Users typing `e05://finder/.../日本語フォルダ` into the URL bar
    // must reach the same address they would from parsing the encoded
    // form; the encodingInvalidCharacters init is what makes this
    // round-trip symmetric.
    let addr = PaneAddress("e05://finder/Users/kawarimidoll/日本語フォルダ")
    #expect(addr?.kind == .finder)
    #expect(addr?.currentPath == "/Users/kawarimidoll/日本語フォルダ")
  }

  @Test("PaneAddress.finder(path:) falls back to bare host for non-absolute input")
  func finderBuilderFallsBackToRoot() {
    // A relative path (missing leading slash) can't be embedded as a
    // URL path component without inventing semantics. Fall back to the
    // bare `e05://finder` URL so the pane's init can substitute the
    // home directory, matching how Finder opens when no folder is
    // specified.
    let empty = PaneAddress.finder(path: "")
    let relative = PaneAddress.finder(path: "relative/path")
    #expect(empty.description == "e05://finder")
    #expect(relative.description == "e05://finder")
    #expect(empty.kind == .finder)
    #expect(relative.kind == .finder)
  }

  @Test("requiresContentSwitch is false between two finder addresses with different paths")
  func finderNoSwitchBetweenPaths() {
    let home = PaneAddress.finder(path: "/Users/kawarimidoll")
    let tmp = PaneAddress.finder(path: "/tmp")
    #expect(!home.requiresContentSwitch(to: tmp))
  }

  @Test("requiresContentSwitch is true between finder and browser")
  func finderBrowserSwitch() {
    let finder = PaneAddress.finder(path: "/Users/kawarimidoll")
    let browser = PaneAddress("https://example.com")!
    #expect(finder.requiresContentSwitch(to: browser))
    #expect(browser.requiresContentSwitch(to: finder))
  }

  @Test("retired special-pane hosts resolve to unknown kind")
  func retiredSpecialPanesAreUnknown() {
    // The history / bookmarks / downloads hosts used to have their
    // own kinds, but those panes were folded into the sidebar. Any
    // URL still pointing at them (old session entries, hand-typed
    // input) parses but resolves to `.unknown` so it falls through
    // to the blank-browser fallback rather than a missing case.
    #expect(PaneAddress("e05://history")?.kind == .unknown)
    #expect(PaneAddress("e05://bookmarks")?.kind == .unknown)
    #expect(PaneAddress("e05://downloads")?.kind == .unknown)
  }

  @Test("https URL resolves to browser kind")
  func httpsKind() {
    let addr = PaneAddress("https://example.com")!
    #expect(addr.kind == .browser)
  }

  @Test("http URL resolves to browser kind")
  func httpKind() {
    let addr = PaneAddress("http://example.com")!
    #expect(addr.kind == .browser)
  }

  @Test("about:blank resolves to browser kind")
  func aboutBlankKind() {
    #expect(PaneAddress.blankBrowser.kind == .browser)
    let addr = PaneAddress("about:blank")!
    #expect(addr.kind == .browser)
  }

  @Test("webkit-extension URLs resolve to browser kind")
  func extensionSchemeKind() {
    // Extension-owned resources (options pages, popup.html, etc.)
    // need to land in a browser pane so the existing URL-bar / find /
    // close machinery applies. PaneModel.init resolves the matching
    // WKWebExtensionContext to seed the pane with the right
    // webViewConfiguration; PaneAddress only commits to "this is a
    // browser-shaped address".
    let addr = PaneAddress("webkit-extension://abc123/options.html")!
    #expect(addr.kind == .browser)
  }

  @Test("fromUserInput accepts webkit-extension scheme")
  func fromUserInputExtensionScheme() {
    let addr = PaneAddress.fromUserInput("webkit-extension://abc123/options.html")
    #expect(addr?.kind == .browser)
  }

  @Test("requiresContentSwitch is true crossing the extension boundary")
  func extensionBoundarySwitch() {
    // Both addresses classify as `.browser`, but the extension URL
    // is bound to a context-owned WKWebViewConfiguration. Reusing
    // the same WKWebView for an external URL would mix extension
    // content world / scheme handlers into non-extension origins,
    // so the URL bar must trigger a pane rebuild in either
    // direction.
    let extPage = PaneAddress("webkit-extension://abc123/options.html")!
    let httpsPage = PaneAddress("https://example.com")!
    #expect(extPage.requiresContentSwitch(to: httpsPage))
    #expect(httpsPage.requiresContentSwitch(to: extPage))
  }

  @Test("requiresContentSwitch is false between two extension URLs")
  func extensionToExtensionNoSwitch() {
    // Two URLs inside the same extension share the configuration
    // (the in-pane webView already owns the right context), so
    // navigating between them should stay in place. Different
    // extensions live behind different uniqueIdentifiers and so
    // also share the boundary bit, but they would hit a navigation
    // failure rather than a rebuild — same fallback shape as a
    // disabled extension.
    let a = PaneAddress("webkit-extension://abc/options.html")!
    let b = PaneAddress("webkit-extension://abc/popup.html")!
    #expect(!a.requiresContentSwitch(to: b))
  }

  @Test("unknown e05 host resolves to unknown kind")
  func unknownInternalKind() {
    let addr = PaneAddress("e05://nonexistent")!
    #expect(addr.kind == .unknown)
  }

  @Test("unknown scheme resolves to unknown kind")
  func unknownScheme() {
    let addr = PaneAddress("ftp://example.com")!
    #expect(addr.kind == .unknown)
  }

  @Test("fromUserInput adds https to bare hostname")
  func fromUserInputBareHost() {
    let addr = PaneAddress.fromUserInput("example.com")
    #expect(addr?.kind == .browser)
    #expect(addr?.url.absoluteString == "https://example.com")
  }

  @Test("fromUserInput preserves e05 scheme")
  func fromUserInputInternalScheme() {
    let addr = PaneAddress.fromUserInput("e05://terminal")
    #expect(addr?.kind == .terminal)
  }

  @Test("fromUserInput returns nil for empty input")
  func fromUserInputEmpty() {
    #expect(PaneAddress.fromUserInput("") == nil)
    #expect(PaneAddress.fromUserInput("   ") == nil)
  }

  @Test("fromUserInput returns nil for bare words without dot or slash")
  func fromUserInputBareWord() {
    #expect(PaneAddress.fromUserInput("hello") == nil)
    #expect(PaneAddress.fromUserInput("swift concurrency") == nil)
  }

  @Test("fromUserInput accepts about: scheme")
  func fromUserInputAboutScheme() {
    let addr = PaneAddress.fromUserInput("about:blank")
    #expect(addr?.kind == .browser)
  }

  @Test("fromUserInput rejects disallowed schemes")
  func fromUserInputDisallowedScheme() {
    #expect(PaneAddress.fromUserInput("ftp://example.com") == nil)
    #expect(PaneAddress.fromUserInput("javascript://alert(1)") == nil)
  }

  @Test("requiresContentSwitch detects type change")
  func contentSwitch() {
    let term = PaneAddress.terminal
    let browser = PaneAddress("https://example.com")!
    #expect(term.requiresContentSwitch(to: browser))
    #expect(browser.requiresContentSwitch(to: term))
  }

  @Test("requiresContentSwitch is false for same type")
  func noContentSwitch() {
    let a = PaneAddress("https://example.com")!
    let b = PaneAddress("https://other.com")!
    #expect(!a.requiresContentSwitch(to: b))
  }

  @Test("description matches URL string")
  func description() {
    let addr = PaneAddress.terminal
    #expect(addr.description == "e05://terminal")
  }

  // MARK: - asDirectNavigation

  @Test("asDirectNavigation accepts explicit https")
  func directNavHttps() {
    #expect(PaneAddress.asDirectNavigation("https://example.com") != nil)
    #expect(
      PaneAddress.asDirectNavigation(
        "https://httpbin.org/x?q=1;filename=a.txt"
      )?.kind == .browser)
  }

  @Test("asDirectNavigation accepts explicit http")
  func directNavHttp() {
    #expect(PaneAddress.asDirectNavigation("http://example.com")?.kind == .browser)
  }

  @Test("asDirectNavigation accepts e05 internal scheme, keeping unknown hosts navigable")
  func directNavE05() {
    #expect(PaneAddress.asDirectNavigation("e05://terminal")?.kind == .terminal)
    // Unknown e05 hosts — retired special panes, typos, or future
    // additions — stay navigable so the URL bar offers a direct-open
    // row. `PaneModel.init(.unknown)` handles the display by falling
    // back to a blank browser, mirroring how mainstream browsers
    // respond to typed-but-unreachable URLs.
    #expect(PaneAddress.asDirectNavigation("e05://history")?.kind == .unknown)
    #expect(PaneAddress.asDirectNavigation("e05://bookmarks")?.kind == .unknown)
    #expect(PaneAddress.asDirectNavigation("e05://downloads")?.kind == .unknown)
  }

  @Test("asDirectNavigation accepts about scheme")
  func directNavAbout() {
    #expect(PaneAddress.asDirectNavigation("about:blank")?.kind == .browser)
  }

  @Test("asDirectNavigation accepts bare hostname with valid TLD")
  func directNavAcceptsBareHost() {
    // Brave/Chromium-style: bare hostnames that look like
    // domains should direct-open. We only assert the kind here —
    // https:// prefix synthesis is fromUserInput's responsibility
    // and has its own tests.
    #expect(PaneAddress.asDirectNavigation("example.com")?.kind == .browser)
    #expect(PaneAddress.asDirectNavigation("github.com/kawarimidoll")?.kind == .browser)
    #expect(PaneAddress.asDirectNavigation("httpbin.org")?.kind == .browser)
    // Two-level ccTLD.
    #expect(PaneAddress.asDirectNavigation("example.co.jp")?.kind == .browser)
  }

  @Test("asDirectNavigation accepts IPv4 literal")
  func directNavAcceptsIPv4() {
    #expect(PaneAddress.asDirectNavigation("192.168.1.1")?.kind == .browser)
    #expect(PaneAddress.asDirectNavigation("192.168.1.1:8080")?.kind == .browser)
  }

  @Test("asDirectNavigation accepts README.md too (matches Chromium)")
  func directNavAcceptsMdTLD() {
    // .md is a real ccTLD (Moldova). Chromium has the same
    // behavior — a purely heuristic check can't disambiguate
    // filename intent from hostname intent.
    #expect(PaneAddress.asDirectNavigation("README.md")?.kind == .browser)
  }

  @Test("asDirectNavigation rejects single-label host")
  func directNavRejectsSingleLabel() {
    // Plain "hello" or "localhost" has no dot — fall through to
    // search. (localhost support can be added later if wanted.)
    #expect(PaneAddress.asDirectNavigation("localhost") == nil)
  }

  @Test("asDirectNavigation rejects trailing-dot fragment")
  func directNavRejectsTrailingDot() {
    // Sentence-like fragments shouldn't promote to URLs.
    #expect(PaneAddress.asDirectNavigation("Hello.") == nil)
    #expect(PaneAddress.asDirectNavigation(".com") == nil)
  }

  @Test("asDirectNavigation rejects bare word with single-char suffix")
  func directNavRejectsShortSuffix() {
    // "a.b" — TLD must be 2+ chars.
    #expect(PaneAddress.asDirectNavigation("a.b") == nil)
  }

  @Test("asDirectNavigation rejects trailing-dot FQDN")
  func directNavRejectsTrailingDotFQDN() {
    // Diverges from Chromium, which accepts "example.com." as a
    // rooted FQDN. We reject to keep sentence-fragment intents
    // ("See example.com.") flowing to search. Revisit if users
    // actually type trailing-dot URLs.
    #expect(PaneAddress.asDirectNavigation("example.com.") == nil)
  }

  @Test("asDirectNavigation accepts host with port")
  func directNavAcceptsHostPort() {
    #expect(PaneAddress.asDirectNavigation("example.com:8080")?.kind == .browser)
  }

  @Test("asDirectNavigation accepts user-info prefix")
  func directNavAcceptsUserInfo() {
    // user@host.com — Brave opens this directly; the split path
    // still reaches a TLD-ish last label.
    #expect(PaneAddress.asDirectNavigation("user@host.com")?.kind == .browser)
  }

  @Test("asDirectNavigation rejects IPv6 bracketed literal")
  func directNavRejectsIPv6() {
    // Known gap vs Chromium. `[::1]` would need bracket-aware
    // parsing; not worth the complexity until someone needs it.
    #expect(PaneAddress.asDirectNavigation("[::1]") == nil)
    #expect(PaneAddress.asDirectNavigation("[fe80::1]") == nil)
  }

  @Test("asDirectNavigation rejects protocol-relative URL")
  func directNavRejectsProtocolRelative() {
    // `//example.com` — ambiguous and rarely typed by users.
    // The prefix-until-`/` host extraction strips everything, so
    // the result is empty and falls through to reject.
    #expect(PaneAddress.asDirectNavigation("//example.com") == nil)
  }

  @Test("asDirectNavigation rejects disallowed schemes")
  func directNavRejectsDisallowed() {
    #expect(PaneAddress.asDirectNavigation("ftp://example.com") == nil)
    #expect(PaneAddress.asDirectNavigation("javascript://alert(1)") == nil)
  }

  @Test("asDirectNavigation rejects bare word and empty")
  func directNavRejectsBareWord() {
    #expect(PaneAddress.asDirectNavigation("") == nil)
    #expect(PaneAddress.asDirectNavigation("   ") == nil)
    #expect(PaneAddress.asDirectNavigation("hello") == nil)
  }

  @Test("asDirectNavigation rejects a slashed path with no dotted host")
  func directNavRejectsSlashWithoutHost() {
    // A path separator but no dotted/IP host: not direct navigation, so
    // the URL bar surfaces it as a search row. `fromUserInput` is
    // deliberately looser (it prepends https://), which is why the URL
    // bar's Enter path builds the search URL from the live query for a
    // selected search row instead of handing the bare text back to the
    // navigation heuristic — otherwise these would navigate, not search.
    #expect(PaneAddress.asDirectNavigation("foo/bar") == nil)
    #expect(PaneAddress.asDirectNavigation("path/to/thing") == nil)
    #expect(PaneAddress.fromUserInput("foo/bar") != nil)
  }

  @Test("asDirectNavigation tolerates surrounding whitespace")
  func directNavTrimsWhitespace() {
    #expect(PaneAddress.asDirectNavigation("  https://example.com  ") != nil)
    #expect(PaneAddress.asDirectNavigation("\te05://terminal\n") != nil)
  }

  // MARK: - Search

  // `searchURL` reads from the @MainActor `PreferencesStore.shared`,
  // so these three exercises run on the main actor and reset the
  // shared template back to the shipped default first. Without the
  // reset, a developer who edits their local preferences (Google /
  // Brave / Custom) would see assertions fail against an
  // unrelated template — the file lives at
  // `~/Library/Application Support/<bundle>/preferences.json` so
  // `inMemory:` test instances do not isolate by themselves.
  @Test("searchURL builds DuckDuckGo URL with encoded query")
  @MainActor
  func searchURLBasic() {
    PreferencesStore.shared.update { $0 = .default }
    let addr = PaneAddress.searchURL(query: "swift concurrency")
    #expect(addr != nil)
    #expect(addr?.kind == .browser)
    #expect(addr?.url.absoluteString == "https://duckduckgo.com/?q=swift%20concurrency")
  }

  @Test("searchURL encodes special characters")
  @MainActor
  func searchURLSpecialChars() {
    PreferencesStore.shared.update { $0 = .default }
    let addr = PaneAddress.searchURL(query: "c++ templates")
    #expect(addr != nil)
    #expect(addr?.url.absoluteString.contains("c%2B%2B%20templates") == true)
  }

  @Test("searchURL handles Japanese input")
  @MainActor
  func searchURLJapanese() {
    PreferencesStore.shared.update { $0 = .default }
    let addr = PaneAddress.searchURL(query: "日本語検索")
    #expect(addr != nil)
    #expect(addr?.kind == .browser)
    #expect(addr?.url.absoluteString.hasPrefix("https://duckduckgo.com/?q=") == true)
  }
}
