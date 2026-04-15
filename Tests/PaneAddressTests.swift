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
}
