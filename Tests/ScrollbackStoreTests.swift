import Foundation
import Testing

@testable import E05Lib

/// A store pointed at a directory of its own, removed afterwards. `save`
/// and `prune` touch the filesystem, and `prune` deletes — neither may
/// run against the developer's real captures.
private func withTempStore(_ body: (ScrollbackStore, URL) throws -> Void) rethrows {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("e05-scrollback-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: dir) }
  try body(ScrollbackStore(directory: dir), dir)
}

/// POSIX mode of a file or directory, for the permission assertions.
private func mode(of url: URL) throws -> Int16 {
  let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
  return (attrs[.posixPermissions] as? NSNumber)?.int16Value ?? -1
}

/// 2026-08-09 00:12:34, built on the Gregorian calendar explicitly. The
/// store stamps with a fixed `en_US_POSIX` formatter, so a test that
/// built its date on `Calendar.current` would disagree with it on a
/// machine set to a Japanese or Buddhist calendar.
private func gregorianDate() -> Date {
  var components = DateComponents()
  components.year = 2026
  components.month = 8
  components.day = 9
  components.hour = 0
  components.minute = 12
  components.second = 34
  return Calendar(identifier: .gregorian).date(from: components)!
}

@Suite("ScrollbackStore paths")
struct ScrollbackStorePathTests {
  @Test("resolves a uuid id")
  func resolvesUUID() {
    let id = UUID().uuidString
    withTempStore { store, dir in
      #expect(store.fileURL(id: id)?.lastPathComponent == "\(id).txt")
      #expect(store.fileURL(id: id)?.deletingLastPathComponent().path == dir.path)
    }
  }

  @Test("refuses an id that is not a uuid")
  func refusesNonUUID() {
    // The id round-trips through session.json, so a hand-edited or
    // corrupted one must not steer the shell's `cat` — and its `rm -f` —
    // outside the scrollback directory.
    withTempStore { store, _ in
      #expect(store.fileURL(id: "../../../../etc/passwd") == nil)
      #expect(store.fileURL(id: "not-a-uuid") == nil)
      #expect(store.fileURL(id: "") == nil)
    }
  }

  @Test("the default store points at the data directory")
  func defaultStoreLocation() {
    // The seam exists for tests; production must still land in the real
    // per-bundle-id data directory rather than wherever a test left it.
    #expect(ScrollbackStore.default.directory.lastPathComponent == E05Filenames.scrollbackDir)
    #expect(
      ScrollbackStore.default.directory.deletingLastPathComponent().path
        == E05Paths.default.dataDir.path)
  }
}

@Suite("ScrollbackStore.save")
struct ScrollbackStoreSaveTests {
  @Test("writes a capture the recorded id resolves to")
  func writesCapture() throws {
    try withTempStore { store, _ in
      let id = try #require(store.save("hello world"))
      let url = try #require(store.fileURL(id: id))
      let written = try String(contentsOf: url, encoding: .utf8)
      #expect(written.contains("hello world"))
      // The rule the shell replays is part of the file, not something
      // the integration prints, so it must survive the round trip.
      #expect(written.contains("restored from"))
    }
  }

  @Test("keeps the capture private on disk")
  func restrictivePermissions() throws {
    // A capture is the pane's screen verbatim — an echoed token, the
    // output of `env`. A backup would otherwise carry it out
    // world-readable.
    try withTempStore { store, dir in
      let id = try #require(store.save("secret"))
      let url = try #require(store.fileURL(id: id))
      #expect(try mode(of: url) == 0o600)
      #expect(try mode(of: dir) == 0o700)
    }
  }

  @Test("narrows a directory that already exists")
  func tightensExistingDirectory() throws {
    // `createDirectory`'s `attributes:` only apply to what it creates, so
    // a directory left behind by an earlier version — or widened by hand
    // — would keep its mode forever. 0700 is an invariant of the
    // directory, not a fact about the moment it was created.
    try withTempStore { store, dir in
      try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755])
      _ = store.save("secret")
      #expect(try mode(of: dir) == 0o700)
    }
  }

  @Test("leaves the mode of the directory above it alone")
  func doesNotTouchTheParent() throws {
    // The store owns `scrollback/`, not the data directory holding it,
    // which every other store shares and creates at the umask default.
    // Passing the mode to `createDirectory` would apply it to both.
    try withTempStore { _, dir in
      let fm = FileManager.default
      // An existing parent must come out untouched. Deterministic: the
      // mode is set here rather than inherited from the umask.
      let existing = dir.appendingPathComponent("existing")
      try fm.createDirectory(
        at: existing, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755])
      let intoExisting = ScrollbackStore(directory: existing.appendingPathComponent("scrollback"))
      _ = intoExisting.save("secret")
      #expect(try mode(of: existing) == 0o755)
      #expect(try mode(of: intoExisting.directory) == 0o700)

      // A parent `save` creates itself must come out like any other
      // directory would — that is the path on which `createDirectory`'s
      // `attributes:` would have reached it. What "like any other" means
      // is the umask's call, so measure it rather than assume it.
      let control = dir.appendingPathComponent("control/leaf")
      try fm.createDirectory(at: control, withIntermediateDirectories: true)
      let expected = try mode(of: control.deletingLastPathComponent())
      // Under `umask 077` a plain directory is 0700 too, so the two
      // implementations are indistinguishable and this half proves
      // nothing. Bail rather than report a pass it did not earn.
      guard expected != 0o700 else { return }

      let fresh = dir.appendingPathComponent("fresh")
      let intoFresh = ScrollbackStore(directory: fresh.appendingPathComponent("scrollback"))
      _ = intoFresh.save("secret")
      #expect(try mode(of: fresh) == expected)
      #expect(try mode(of: intoFresh.directory) == 0o700)
    }
  }

  @Test("leaves the target of a symlinked directory alone")
  func doesNotChmodThroughASymlink() throws {
    // `setAttributes` follows links. A user who points `scrollback/` at
    // another volume has a directory of their own on the far end, and
    // narrowing it every save is not this store's call.
    try withTempStore { _, dir in
      let fm = FileManager.default
      let target = dir.appendingPathComponent("elsewhere")
      try fm.createDirectory(
        at: target, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755])
      let link = dir.appendingPathComponent("link")
      try fm.createSymbolicLink(at: link, withDestinationURL: target)

      let store = ScrollbackStore(directory: link)
      let id = try #require(store.save("secret"))

      #expect(try mode(of: target) == 0o755)
      // The capture still lands, and is still 0600 — the file's mode is
      // the guarantee, and it is set on the file itself.
      #expect(try mode(of: #require(store.fileURL(id: id))) == 0o600)
    }
  }

  @Test("writes nothing when there is no history worth restoring")
  func refusesEmptyCapture() {
    withTempStore { store, dir in
      #expect(store.save("") == nil)
      #expect(store.save("\n\n   \n") == nil)
      // Not even the directory: an empty capture should leave no trace.
      #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
  }

  @Test("refuses an id that is not a uuid")
  func refusesNonUUIDID() {
    withTempStore { store, dir in
      #expect(store.save("history", id: "../escape") == nil)
      // Rejected before anything reaches the filesystem.
      #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
  }

  @Test("stamps a capture saved without a time with the current one")
  func defaultCaptureTimeIsNow() throws {
    // The production call site passes neither id nor time. A default
    // frozen at some fixed instant would label every restored pane with
    // it, and no other test exercises the defaulted argument.
    try withTempStore { store, _ in
      let id = try #require(store.save("history"))
      let written = try String(contentsOf: try #require(store.fileURL(id: id)), encoding: .utf8)
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
      let afterPrefix = try #require(written.range(of: "restored from "))
      let stamp = String(written[afterPrefix.upperBound...].prefix(19))
      let parsed = try #require(formatter.date(from: stamp), "unparsable stamp: \(stamp)")
      #expect(abs(parsed.timeIntervalSinceNow) < 120)
    }
  }
}

@Suite("ScrollbackStore.prune")
struct ScrollbackStorePruneTests {
  /// `save` is the only writer, so seed through it: a hand-written file
  /// could disagree with the naming `prune` parses.
  private func seed(_ store: ScrollbackStore, count: Int) -> [String] {
    (1...count).compactMap { store.save("capture \($0)") }
  }

  @Test("keeps the ids just written and drops the rest")
  func dropsStaleCaptures() throws {
    try withTempStore { store, _ in
      let ids = seed(store, count: 3)
      #expect(ids.count == 3)
      let urls = try ids.map { try #require(store.fileURL(id: $0)) }
      store.prune(keeping: [ids[0], ids[2]])
      let fm = FileManager.default
      #expect(fm.fileExists(atPath: urls[0].path))
      #expect(!fm.fileExists(atPath: urls[1].path))
      #expect(fm.fileExists(atPath: urls[2].path))
    }
  }

  @Test("an empty keep set clears the directory")
  func emptyKeepSetClearsAll() throws {
    // The contract a quit with no terminal panes relies on. Stated as a
    // test because it is also the shape a bug would take.
    try withTempStore { store, dir in
      // Asserted, not discarded: a `save` that returned nil for every
      // capture would leave the directory empty too, and this test would
      // pass without prune having done anything.
      #expect(seed(store, count: 2).count == 2)
      store.prune(keeping: [])
      let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      #expect(left.isEmpty)
    }
  }

  @Test("leaves entries that are not UUID-named captures alone")
  func ignoresForeignEntries() throws {
    try withTempStore { store, dir in
      let ids = seed(store, count: 1)
      let capture = try #require(store.fileURL(id: ids[0]))
      let fm = FileManager.default
      let notes = dir.appendingPathComponent("notes.md")
      try "keep me".write(to: notes, atomically: true, encoding: .utf8)
      // A `.txt` that is not a capture: the suffix is not proof of
      // authorship, the UUID name is.
      let readme = dir.appendingPathComponent("README.txt")
      try "keep me".write(to: readme, atomically: true, encoding: .utf8)
      // And a directory wearing the suffix — removeItem recurses, so
      // this one takes its contents with it.
      let dirNamedTxt = dir.appendingPathComponent("notes.txt")
      try fm.createDirectory(at: dirNamedTxt, withIntermediateDirectories: true)

      store.prune(keeping: [])

      #expect(fm.fileExists(atPath: notes.path))
      #expect(fm.fileExists(atPath: readme.path))
      #expect(fm.fileExists(atPath: dirNamedTxt.path))
      #expect(!fm.fileExists(atPath: capture.path))
    }
  }

  @Test("the preference decides whether this quit captures")
  func quitPolicyFollowsThePreference() throws {
    // On, and the captures already on disk are left for the shells that
    // are about to replay them. Off, and they go with the setting —
    // keeping screens the user just asked not to keep would answer the
    // wrong half of the question.
    try withTempStore { store, dir in
      let fm = FileManager.default
      #expect(seed(store, count: 2).count == 2)

      #expect(store.capturesThisQuit(per: E05Preferences(restoreTerminalScrollback: true)))
      var left = try fm.contentsOfDirectory(atPath: dir.path)
      #expect(left.count == 2)

      #expect(store.capturesThisQuit(per: E05Preferences(restoreTerminalScrollback: nil)))
      left = try fm.contentsOfDirectory(atPath: dir.path)
      #expect(left.count == 2)

      #expect(!store.capturesThisQuit(per: E05Preferences(restoreTerminalScrollback: false)))
      left = try fm.contentsOfDirectory(atPath: dir.path)
      #expect(left.isEmpty)
    }
  }

  // Named for what it calls, not for launch: nothing here goes through
  // `viewDidLoad`, and no unit test can — the view controller needs a
  // `GhosttyApp`. Deleting the call site leaves this green.
  @Test("pruneOrphans drops the captures a session cannot reach")
  func pruneOrphansDropsUnreachable() throws {
    // The other two callers of `prune` are the quit handler and the
    // Delete button in Settings, so a run that ends in a crash cleans up
    // nothing: the path reaches a shell once, at surface creation.
    try withTempStore { store, dir in
      let ids = seed(store, count: 3)
      #expect(ids.count == 3)
      let urls = try ids.map { try #require(store.fileURL(id: $0)) }

      var pane = SessionState.PaneState(address: "e05://terminal")
      pane.terminalScrollbackID = ids[1]
      let session = SessionState(
        workspaces: [
          SessionState.WorkspaceState(
            name: "one",
            columns: [
              SessionState.ColumnState(
                panes: [pane], focusedPaneIndex: 0, width: 500, heightRatios: [])
            ],
            focusedColumnIndex: 0, scrollX: 0)
        ],
        focusedWorkspaceIndex: 0)

      store.pruneOrphans(against: session)
      let fm = FileManager.default
      #expect(!fm.fileExists(atPath: urls[0].path))
      #expect(fm.fileExists(atPath: urls[1].path))
      #expect(!fm.fileExists(atPath: urls[2].path))

      // No session in hand deletes nothing. `load` returns nil for a
      // file it quarantined as unreadable or too new as well as for one
      // that is absent, and in all of those cases nothing has been
      // restored — so no shell has been handed a path and every capture
      // is still unconsumed. Deleting them would take the history out
      // from under a session the quarantine deliberately kept.
      store.pruneOrphans(against: nil)
      #expect(try fm.contentsOfDirectory(atPath: dir.path).count == 1)
    }
  }

  @Test("does nothing when no capture has ever been written")
  func toleratesMissingDirectory() {
    withTempStore { store, dir in
      store.prune(keeping: [])
      #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
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

  @Test("drops a banner sitting under the screen read's padding")
  func dropsBannerBelowPadding() {
    // The shape a real capture takes: the screen read pads the top with
    // blank rows, so the banner is not the first line and the blanks
    // have to come off before the banner filter can see it.
    let captured = "\n\nLast login: Sat Aug  8 23:44:20 on ttys027\n\nreal output"
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

  @Test("cuts on a line boundary when over the byte cap")
  func byteCapCutsAtLineBoundary() {
    // Long enough that the byte cap bites before the line cap: a
    // mid-line cut would open the replay with a fragment.
    let line = String(repeating: "x", count: 1000)
    let text = (1...500).map { "\($0)-\(line)" }.joined(separator: "\n")
    let result = ScrollbackStore.truncate(text)

    #expect(result.utf8.count <= ScrollbackStore.maxBytes)
    #expect(!result.hasPrefix("x"))
    #expect(result.hasSuffix("500-\(line)"))
  }

  @Test("keeps the cap's worth of a capture that has no line to cut on")
  func byteCapWithoutALineBoundary() {
    // The branch taken when the tail holds no newline at all — a single
    // enormous line, which `cat`ting a binary into the pane produces.
    // Asserted as an equality: a cap that keeps a tenth of its budget
    // also satisfies "no more than the cap".
    let text = String(repeating: "x", count: ScrollbackStore.maxBytes + 5000)
    #expect(ScrollbackStore.truncate(text).utf8.count == ScrollbackStore.maxBytes)
  }

  @Test("bounds a capture whose characters are far larger than a byte")
  func byteCapBoundsWideCharacters() {
    // What a character count does not bound. Each line here is one
    // grapheme cluster carrying a thousand combining marks, so 4,000
    // lines are 4,000 characters — inside a 400,000-character cap — and
    // 7.6 MB on disk, all of which the shell would have to read back.
    let line = "a" + String(repeating: "\u{0301}", count: 1000)
    let text = (1...4000).map { _ in line }.joined(separator: "\n")
    #expect(text.utf8.count > 7_000_000)

    let result = ScrollbackStore.truncate(text)
    #expect(result.utf8.count <= ScrollbackStore.maxBytes)
    // And the same for text that is merely not ASCII, which is the case
    // that turns up without anyone trying: 400,000 characters of CJK is
    // 1.2 MB.
    let cjk = (1...20_000).map { _ in String(repeating: "日本語のテキスト", count: 15) }
      .joined(separator: "\n")
    #expect(ScrollbackStore.truncate(cjk).utf8.count <= ScrollbackStore.maxBytes)
  }

  @Test("the caps are the values the doc comment justifies")
  func capsArePinned() {
    // Pinned literally. Every other cap test states its expectation in
    // terms of these constants, so a typo here would move the tests with
    // it and ship unnoticed.
    #expect(ScrollbackStore.maxLines == 4000)
    #expect(ScrollbackStore.maxBytes == 400_000)
  }

  @Test("stamps the rule with the capture time, not the replay time")
  func replayRuleCarriesCaptureTimestamp() {
    // A restored pane should say when its history is from; reading the
    // clock at replay would instead label everything "just now".
    //
    // The whole payload is compared rather than probed: the layout is a
    // contract with the shell that replays it, and prefix/suffix checks
    // leave the middle — the blank line before the rule — unpinned.
    let result = ScrollbackStore.replayText("real output", capturedAt: gregorianDate())

    #expect(
      result == "\nreal output\n\n\u{1B}[2m──── restored from 2026-08-09 00:12:34 ────\u{1B}[0m\n")
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

  @Test("keeps a line matching only one end of the rule")
  func keepsHalfRuleMatches() {
    // The filter is an AND of prefix and suffix. A line that opens like
    // a rule but does not close like one — or the reverse — is output,
    // and dropping either half of the test would take it with the rules.
    let opensLikeARule = "──── restored from a log I was reading"
    let closesLikeARule = "make: done ────"
    #expect(ScrollbackStore.truncate(opensLikeARule) == opensLikeARule)
    #expect(ScrollbackStore.truncate(closesLikeARule) == closesLikeARule)
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

/// A styled capture differs from a plain one in two ways, and each
/// breaks something that reads it as plain text. Rows are separated by
/// CRLF, which Swift reads as a single Character — so a split on "\n"
/// finds no separator at all and the whole capture arrives as one line.
/// And a run of styled cells is wrapped in SGR, so a line's text is not
/// where a prefix or a blank test looks for it.
///
/// What the formatter does *not* do is wrap indiscriminately: cells in
/// the default style are emitted bare, and style never crosses a
/// newline — it is closed just before one. The rows below are built to
/// that shape rather than to a uniform wrapper, or they would be
/// testing something the capture cannot contain.
@Suite("ScrollbackStore styled captures")
struct ScrollbackStoreStyledTests {
  /// A row carrying a style: opened where the styled cells start,
  /// closed before the row ends.
  private func styled(_ text: String, sgr: String = "\u{1B}[1m") -> String {
    "\(sgr)\(text)\u{1B}[0m"
  }

  /// Rows as they reach a capture file: CRLF between them, none after
  /// the last.
  private func styledCapture(_ rows: [String]) -> String {
    rows.joined(separator: "\r\n")
  }

  @Test("plain text is returned as it stands")
  func visibleTextLeavesPlainAlone() {
    #expect(ScrollbackStore.visibleText(of: "just text") == "just text")
  }

  @Test("SGR comes off")
  func visibleTextStripsStyle() {
    #expect(ScrollbackStore.visibleText(of: Substring(styled("hello"))) == "hello")
  }

  @Test("CRLF rows are separate lines")
  func splitsOnCRLF() {
    // Swift reads "\r\n" as one Character, so a split on "\n" alone finds
    // nothing to split on. Everything downstream then sees a single line:
    // no blank trimming, no banner filter, and a line cap that counts to
    // one. Pinned on the line cap, which is the one that would let a
    // whole session through.
    let rows = (1...(ScrollbackStore.maxLines + 10)).map { styled("line \($0)") }
    let result = ScrollbackStore.truncate(styledCapture(rows))

    #expect(result.split(separator: "\n").count == ScrollbackStore.maxLines)
  }

  @Test("a sequence with no final byte does not leak its bytes")
  func visibleTextHandlesUnterminatedSequence() {
    // The formatter cannot emit one, so this pins the parser's bound
    // rather than a shape a capture takes: running to the end of the
    // line is fine, `[38;5` sitting in front of a prefix test is not.
    #expect(ScrollbackStore.visibleText(of: "text\u{1B}[38;5") == "text")
  }

  @Test("drops the previous replay's rule when it comes back styled")
  func dropsStyledRule() {
    // The regression this all exists for. e05 writes the rule dim, so a
    // styled capture reads it back wrapped in SGR — and a filter looking
    // at the raw line would keep it, leaving one more rule per restart.
    let captured = styledCapture([
      styled("first session"),
      styled(""),
      styled("──── restored from 2026-08-09 23:34:07 ────", sgr: "\u{1B}[2m"),
      styled("second session"),
    ])

    let result = ScrollbackStore.truncate(captured)
    #expect(!result.contains("restored from"))
    #expect(result.contains("first session"))
    #expect(result.contains("second session"))
  }

  @Test("treats a row of styled spaces as blank")
  func stripsStyledPadding() {
    // A row of written spaces carrying a background — the tail of a TUI
    // status bar, a padded prompt — is text as far as the formatter is
    // concerned, so it arrives wrapped in SGR rather than folded into a
    // bare newline. Read raw, it is not blank, and it would be replayed
    // as a stripe of colour above the restored history.
    let bar = styled("   ", sgr: "\u{1B}[48;5;4m")
    let captured = styledCapture(["", bar, styled("real output"), bar, ""])

    let result = ScrollbackStore.truncate(captured)
    #expect(ScrollbackStore.visibleText(of: Substring(result)) == "real output")
  }

  @Test("drops the login banner in a styled capture")
  func dropsStyledLoginBanner() {
    // The banner itself is unstyled — `login` prints it in the default
    // style, and default cells are emitted bare — so this is really the
    // CRLF split carrying the plain-text filters through.
    let captured = styledCapture([
      "Last login: Sat Aug  8 23:44:20 on ttys027",
      "",
      styled("real output"),
    ])

    #expect(!ScrollbackStore.truncate(captured).contains("Last login:"))
  }

  @Test("keeps the styling of the lines it does keep")
  func keepsStyleOnSurvivingLines() {
    // Stripping is for the predicates only. What reaches the file has to
    // still carry its colour, or the whole exercise is a plain capture
    // that took a longer road.
    let captured = styled("coloured output", sgr: "\u{1B}[31m")
    #expect(ScrollbackStore.truncate(captured).contains("\u{1B}[31m"))
  }
}
