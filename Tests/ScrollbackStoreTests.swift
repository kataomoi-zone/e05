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

  @Test("the shared store points at the data directory")
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

  @Test("leaves anything it did not write alone")
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
