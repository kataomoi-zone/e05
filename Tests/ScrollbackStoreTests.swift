import Foundation
import Testing

@testable import E05Lib

@Suite("ScrollbackStore paths")
struct ScrollbackStorePathTests {
  @Test("resolves a uuid id")
  func resolvesUUID() {
    let id = UUID().uuidString
    #expect(ScrollbackStore.fileURL(id: id)?.lastPathComponent == "\(id).txt")
  }

  @Test("refuses an id that is not a uuid")
  func refusesNonUUID() {
    // The id round-trips through session.json, so a hand-edited or
    // corrupted one must not steer the shell's `cat` — and its `rm -f` —
    // outside the scrollback directory.
    #expect(ScrollbackStore.fileURL(id: "../../../../etc/passwd") == nil)
    #expect(ScrollbackStore.fileURL(id: "not-a-uuid") == nil)
    #expect(ScrollbackStore.fileURL(id: "") == nil)
  }
}

@Suite("ScrollbackStore.truncate")
struct ScrollbackStoreTests {
  @Test("keeps short captures verbatim")
  func shortCaptureUnchanged() {
    let text = "line one\nline two\nline three"
    #expect(ScrollbackStore.truncate(text) == text)
  }

  @Test("strips the blank rows a screen read pads with")
  func stripsSurroundingBlankLines() {
    // A screen read covers the whole grid, so a shell that has produced
    // three lines still yields a capture padded to the row count.
    let padded = "\n\n  \nreal output\n\n   \n\n"
    #expect(ScrollbackStore.truncate(padded) == "real output")
  }

  @Test("drops the login banner so it cannot stack across restarts")
  func dropsLoginBanner() {
    // `login` prints this before the shell exists, so every restart adds
    // one. Replaying the old banner would leave a growing pile of them.
    let captured = """
      Last login: Sat Aug  8 23:44:20 on ttys027

      real output
      """
    #expect(ScrollbackStore.truncate(captured) == "real output")
  }

  @Test("drops a banner that already stacked before this landed")
  func dropsStackedLoginBanners() {
    let captured = """
      Last login: Sat Aug  8 23:44:20 on ttys027
      Last login: Sat Aug  8 23:43:56 on ttys028

      real output
      """
    #expect(ScrollbackStore.truncate(captured) == "real output")
  }

  @Test("keeps a login-like line that is not the banner")
  func keepsInteriorLoginMention() {
    // Only the leading banner goes; the same text further down is
    // ordinary output the user may well want back.
    let captured = "some command\nLast login: whatever\ntail"
    #expect(ScrollbackStore.truncate(captured) == captured)
  }

  @Test("keeps interior blank lines")
  func keepsInteriorBlanks() {
    let text = "first\n\nsecond"
    #expect(ScrollbackStore.truncate(text) == text)
  }

  @Test("keeps the newest lines when over the line cap")
  func lineCapKeepsTail() {
    // The tail is what a restored pane should show — the last thing the
    // user was looking at, not the start of the session.
    let lines = (1...(ScrollbackStore.maxLines + 500)).map { "line \($0)" }
    let result = ScrollbackStore.truncate(lines.joined(separator: "\n"))
    let resultLines = result.split(separator: "\n", omittingEmptySubsequences: false)

    #expect(resultLines.count == ScrollbackStore.maxLines)
    #expect(resultLines.last == "line \(ScrollbackStore.maxLines + 500)")
    #expect(resultLines.first == "line 501")
  }

  @Test("cuts on a line boundary when over the character cap")
  func characterCapCutsAtLineBoundary() {
    // Long enough that the character cap bites before the line cap: a
    // mid-line cut would open the replay with a fragment.
    let line = String(repeating: "x", count: 1000)
    let text = (1...500).map { "\($0)-\(line)" }.joined(separator: "\n")
    let result = ScrollbackStore.truncate(text)

    #expect(result.count <= ScrollbackStore.maxCharacters)
    #expect(!result.hasPrefix("x"))
    #expect(result.hasSuffix("500-\(line)"))
  }

  @Test("stamps the rule with the capture time, not the replay time")
  func replayRuleCarriesCaptureTimestamp() {
    // A restored pane should say when its history is from; reading the
    // clock at replay would instead label everything "just now".
    var components = DateComponents()
    components.year = 2026
    components.month = 8
    components.day = 9
    components.hour = 0
    components.minute = 12
    components.second = 34
    let captured = Calendar.current.date(from: components)!

    let result = ScrollbackStore.replayText("real output", capturedAt: captured)

    // Leading blank line keeps the history off the `Last login:` banner
    // that `login` prints immediately above it.
    #expect(result.hasPrefix("\nreal output"))
    #expect(result.contains("2026-08-09 00:12:34"))
    // Dim, not a background colour: a theme change since the capture
    // could otherwise leave the rule invisible.
    #expect(result.contains("\u{1B}[2m"))
    // Trailing newline, or zsh marks the replay with its `%` glyph for
    // output that does not end on a line boundary.
    #expect(result.hasSuffix("\u{1B}[0m\n"))
  }

  @Test("drops the previous replay's rule so rules cannot stack")
  func dropsPreviousReplayRule() {
    // The rule from the last restore is ordinary scrollback by the time
    // the next capture runs; keeping it would add one per restart.
    let captured = """
      first session

      ──── restored from 2026-08-09 23:34:07 ────
      second session
      """
    #expect(ScrollbackStore.truncate(captured) == "first session\n\nsecond session")
  }

  @Test("keeps a line that merely mentions the rule text")
  func keepsRuleMention() {
    // Only a line that is entirely a rule goes.
    let captured = "grep '──── restored from ' log.txt"
    #expect(ScrollbackStore.truncate(captured) == captured)
  }

  @Test("adds no rule when there is no history")
  func noRuleWithoutHistory() {
    // Otherwise a pane with nothing to restore would open showing only
    // a rule announcing the absence.
    #expect(ScrollbackStore.replayText("", capturedAt: Date()).isEmpty)
  }

  @Test("an all-blank capture reduces to nothing")
  func blankCaptureIsEmpty() {
    // `save` treats empty as "no history worth restoring" and records no
    // id, so a pane that only ever showed a prompt restores clean.
    #expect(ScrollbackStore.truncate("\n\n   \n\n").isEmpty)
  }
}
