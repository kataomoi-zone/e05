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

    @Test("history address resolves to history kind")
    func historyKind() {
        #expect(PaneAddress.history.kind == .history)
        #expect(PaneAddress.history.description == "e05://history")
    }

    @Test("bookmarks address resolves to bookmarks kind")
    func bookmarksKind() {
        #expect(PaneAddress.bookmarks.kind == .bookmarks)
        #expect(PaneAddress.bookmarks.description == "e05://bookmarks")
    }

    @Test("downloads address resolves to downloads kind")
    func downloadsKind() {
        #expect(PaneAddress.downloads.kind == .downloads)
        #expect(PaneAddress.downloads.description == "e05://downloads")
    }

    @Test("fromUserInput resolves e05 special panes")
    func fromUserInputSpecialPanes() {
        #expect(PaneAddress.fromUserInput("e05://history")?.kind == .history)
        #expect(PaneAddress.fromUserInput("e05://bookmarks")?.kind == .bookmarks)
        #expect(PaneAddress.fromUserInput("e05://downloads")?.kind == .downloads)
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
        #expect(PaneAddress.asDirectNavigation(
            "https://httpbin.org/x?q=1;filename=a.txt"
        )?.kind == .browser)
    }

    @Test("asDirectNavigation accepts explicit http")
    func directNavHttp() {
        #expect(PaneAddress.asDirectNavigation("http://example.com")?.kind == .browser)
    }

    @Test("asDirectNavigation accepts e05 internal scheme")
    func directNavE05() {
        #expect(PaneAddress.asDirectNavigation("e05://history")?.kind == .history)
        #expect(PaneAddress.asDirectNavigation("e05://bookmarks")?.kind == .bookmarks)
        #expect(PaneAddress.asDirectNavigation("e05://terminal")?.kind == .terminal)
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

    @Test("asDirectNavigation rejects unknown e05 host")
    func directNavRejectsUnknownE05() {
        #expect(PaneAddress.asDirectNavigation("e05://nonexistent") == nil)
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

    @Test("asDirectNavigation tolerates surrounding whitespace")
    func directNavTrimsWhitespace() {
        #expect(PaneAddress.asDirectNavigation("  https://example.com  ") != nil)
        #expect(PaneAddress.asDirectNavigation("\te05://history\n") != nil)
    }

    // MARK: - Search

    @Test("searchURL builds DuckDuckGo URL with encoded query")
    func searchURLBasic() {
        let addr = PaneAddress.searchURL(query: "swift concurrency")
        #expect(addr != nil)
        #expect(addr?.kind == .browser)
        #expect(addr?.url.absoluteString == "https://duckduckgo.com/?q=swift%20concurrency")
    }

    @Test("searchURL encodes special characters")
    func searchURLSpecialChars() {
        let addr = PaneAddress.searchURL(query: "c++ templates")
        #expect(addr != nil)
        #expect(addr?.url.absoluteString.contains("c%2B%2B%20templates") == true)
    }

    @Test("searchURL handles Japanese input")
    func searchURLJapanese() {
        let addr = PaneAddress.searchURL(query: "日本語検索")
        #expect(addr != nil)
        #expect(addr?.kind == .browser)
        #expect(addr?.url.absoluteString.hasPrefix("https://duckduckgo.com/?q=") == true)
    }
}
