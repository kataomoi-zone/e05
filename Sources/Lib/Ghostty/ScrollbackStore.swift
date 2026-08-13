import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "Scrollback")

/// On-disk terminal scrollback, captured at save time and replayed into
/// the shell on restore.
///
/// libghostty has no way to write into a surface's screen — the only
/// output path is the child process's stdout — so a restored pane gets
/// its history back by having the shell `cat` a file before its first
/// prompt. `e05-integration.{zsh,bash,fish}` does that and deletes the file,
/// reading its path from `E05_RESTORE_SCROLLBACK_FILE` in the surface
/// environment. (Terminal.app can restore directly because it owns its
/// emulator; an embedder cannot.)
///
/// Files live in their own directory rather than inside `session.json`
/// because they are large and only one of them is ever wanted at a time.
struct ScrollbackStore: Sendable {
  /// Matches cmux, which arrived at these by shipping the feature. Far
  /// more than a screenful is rarely read back, and an unbounded capture
  /// would put megabytes through the shell on every restore.
  ///
  /// The size cap is in bytes because bytes are what the shell reads. A
  /// character count is not the same bound: 400,000 characters of CJK is
  /// 1.2 MB, and a character built from a thousand combining marks is a
  /// few KB on its own — a capture of 4,000 such lines passed both of
  /// the old caps at 7.6 MB.
  ///
  /// Colour costs about 2.2x: a measured capture carried 45 bytes of SGR
  /// per line on top of 39 of text. Neither cap moved for it, because
  /// the byte cap bounds what the shell reads back and that is the same
  /// 400 KB whatever is in it. The two caps meet at 100 bytes a line, so
  /// that measured session still runs into the line cap first; a denser
  /// one — long lines, colour on every token — hits the byte cap
  /// instead and restores fewer lines than it would have in plain.
  static let maxLines = 4000
  static let maxBytes = 400_000

  /// Process-wide store, backed by the real data directory. Every caller
  /// in the app goes through this.
  static let `default` = ScrollbackStore()

  /// A parameter rather than a computed property so a test can point the
  /// store at a temp directory, per the seam convention ``E05Paths``
  /// documents: `save` and `prune` touch the filesystem, and `prune`
  /// deletes, so neither may run against the user's own captures.
  let directory: URL

  init(directory: URL = E05Paths.default.dataFile(E05Filenames.scrollbackDir)) {
    self.directory = directory
  }

  /// Resolve a capture's path from the id recorded in a `PaneState`.
  /// `nil` unless the id is a UUID: the value round-trips through
  /// session.json, and an id carrying `../` would send the shell's `cat`
  /// — and its `rm -f` — anywhere it can reach.
  func fileURL(id: String) -> URL? {
    guard UUID(uuidString: id) != nil else { return nil }
    return directory.appendingPathComponent("\(id).txt")
  }

  /// Write one pane's capture, returning the id to record in its
  /// `PaneState`. `nil` when there is nothing worth restoring or the
  /// write fails — the caller then simply omits the field and the pane
  /// restores without history.
  func save(
    _ text: String, id: String = UUID().uuidString, capturedAt: Date = Date()
  ) -> String? {
    let trimmed = Self.replayText(Self.truncate(text), capturedAt: capturedAt)
    guard !trimmed.isEmpty, let url = fileURL(id: id) else { return nil }
    do {
      let fm = FileManager.default
      // 0700 / 0600: a capture is the pane's screen verbatim, which can
      // hold an echoed token or the output of `env`. The home directory
      // already restricts it, but a backup would otherwise carry it out
      // world-readable.
      //
      // The mode goes on afterwards rather than through `createDirectory`'s
      // `attributes:`, which applies them to every directory it creates —
      // including the shared data directory above this one, whose mode is
      // no business of this store's — and not at all when the directory
      // already exists. Set here it is what it reads as: an invariant of
      // this directory, re-established on every save.
      //
      // Two limits on that, both because the file's 0600 below is the
      // guarantee and the directory is defence in depth. `try?`: a volume
      // that cannot chmod should still get its capture, rather than the
      // feature dying silently everywhere. And not through a symlink,
      // which `setAttributes` would follow — a directory the user pointed
      // somewhere else is not ours to narrow.
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      let isLink = (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink
      if isLink != true {
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      }
      // An atomic write lands at the umask default and is narrowed a
      // moment later, so a capture is 0644 in between — and stays that
      // way if the process dies there, until the next quit's `prune`
      // drops it as an id nothing recorded. Behind a 0700 directory
      // either way. `createFile` would set the mode up front but give up
      // the atomic replace, and a torn capture is the worse failure.
      try trimmed.write(to: url, atomically: true, encoding: .utf8)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return id
    } catch {
      logger.error("[scrollback] write failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// Whether this quit should capture, and the side effect of it saying
  /// no: turning the setting off has to remove what is already stored,
  /// or the screens the user just asked not to keep stay on disk.
  ///
  /// Here rather than at the call site so it can be tested — the caller
  /// is a view controller a unit test cannot build.
  func capturesThisQuit(per preferences: E05Preferences) -> Bool {
    let enabled = preferences.restoresTerminalScrollback
    if !enabled { prune(keeping: []) }
    return enabled
  }

  /// Drop the captures `session` does not point at, at launch. A
  /// capture's path reaches a shell once, when its pane's surface is
  /// created, so anything the session about to be restored does not name
  /// is already unreachable. The shell that replays a capture deletes it
  /// itself, so in an ordinary run there is little here to find; what
  /// this collects is what a crash left behind, and captures no shell
  /// ever read.
  ///
  /// `nil` deletes nothing. A session that could not be read is not a
  /// session that named no captures: ``SessionState/load()`` returns nil
  /// for a file it quarantined as unreadable or too new as well as for
  /// one that is absent, and in every one of those cases the captures
  /// are still unconsumed — nothing has been restored, so no shell has
  /// been handed a path. Quarantine exists so a session can be recovered
  /// by hand; taking the history out from under it while keeping the
  /// layout would be the wrong half to save. They cost one session and
  /// go at the next clean quit.
  ///
  /// Here rather than at the call site for the same reason as
  /// ``capturesThisQuit(per:)``: the caller is a view controller.
  func pruneOrphans(against session: SessionState?) {
    guard let session else { return }
    prune(keeping: session.scrollbackIDs)
  }

  /// Drop every capture except the ones just written. Panes closed since
  /// the last save would otherwise leave their files behind forever, and
  /// a restored pane's file is consumed by the shell rather than by us.
  func prune(keeping ids: Set<String>) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
    for entry in entries where entry.hasSuffix(".txt") {
      let id = String(entry.dropLast(4))
      // Same check ``fileURL(id:)`` makes on the way in: the only things
      // this ever wrote are UUID-named. The suffix alone would put a
      // hand-placed `README.txt` — or, since removeItem recurses, a
      // directory that happens to end in `.txt` — inside the blast
      // radius of an operation whose whole job is deleting.
      guard UUID(uuidString: id) != nil else { continue }
      if ids.contains(id) { continue }
      try? fm.removeItem(at: directory.appendingPathComponent(entry))
    }
  }

  /// Append the rule that separates restored history from the live
  /// session, stamped with when the capture was taken so it reads as
  /// "this is what the pane held at 23:59" rather than as output that
  /// just scrolled past.
  ///
  /// Built here rather than printed by the shell so the timestamp is the
  /// capture's, not the replay's, and so the whole payload is one file
  /// the integration only has to `cat`.
  ///
  /// Dim (SGR 2) rather than a background colour: the terminal's theme
  /// may have changed since the capture, and any colour chosen here
  /// could land invisible against it.
  static func replayText(_ history: String, capturedAt: Date) -> String {
    guard !history.isEmpty else { return history }
    let stamp = stampFormatter.string(from: capturedAt)
    // Blank line at the front separates the history from the `Last
    // login:` banner `login` printed just above it — the replay cannot
    // precede that line, so it should at least not run into it. The one
    // before the rule is there because a capture ends on the old prompt
    // line, which carries no newline of its own. The trailing newline
    // keeps zsh from marking the replay with its `%` partial-line glyph.
    return "\n\(history)\n\n\u{1B}[2m\(rulePrefix)\(stamp) \(ruleSuffix)\u{1B}[0m\n"
  }

  /// Bracketing text of the restored-from rule, shared by the writer and
  /// by ``truncate(_:)``'s filter so the two cannot drift.
  private static let rulePrefix = "──── restored from "
  private static let ruleSuffix = "────"

  private static let stampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    // Fixed format needs a fixed locale, or the user's calendar leaks in
    // and `yyyy` renders as a Buddhist or Japanese-era year.
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()

  /// Keep the tail: the newest output is what a restored pane should
  /// show. Trimming leading blank lines avoids replaying the empty rows
  /// a screen read pads with when the shell has produced little output.
  ///
  /// The leading `Last login:` banner is dropped as well. macOS's
  /// `login` prints it before the shell exists, so a replay can never
  /// precede it — carrying the old one along would stack a new banner
  /// on top of every previous session's, one line deeper each restart.
  static func truncate(_ text: String) -> String {
    // Bound the input before anything walks it. Everything below works
    // in Characters, and Swift has to decode grapheme clusters to do
    // that — 565 ms on the capture above, on the main thread, at quit.
    // Cutting to the last `maxBytes` first costs one pass over that much
    // and leaves the rest to operate on a bounded string. Only lines are
    // removed after this, so the result stays inside the cap.
    // CRLF as well as LF: a styled capture ends its rows with `\r\n`, and
    // Swift reads that pair as one Character, so splitting on "\n" alone
    // finds no separator at all and hands everything below a single line.
    // Every filter here then matches nothing and the line cap counts one.
    // The CR goes with the separator, leaving LF-terminated rows — which
    // is what the replay wants anyway, since `cat` to a terminal turns
    // each one back into CRLF.
    var lines = Self.lastBytes(of: text)
      .split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
    // A previous replay's rule is now ordinary scrollback, and keeping it
    // would leave one more rule per restart. Unlike the banner these sit
    // mid-history, so the whole capture is filtered rather than just its
    // head. Only the newest rule — appended after this — is wanted.
    lines.removeAll {
      let visible = visibleText(of: $0)
      return visible.hasPrefix(rulePrefix) && visible.hasSuffix(ruleSuffix)
    }
    func dropLeading(while matches: (Substring) -> Bool) {
      while let first = lines.first, matches(first) {
        lines.removeFirst()
      }
    }
    func isBlank(_ line: Substring) -> Bool {
      visibleText(of: line).trimmingCharacters(in: .whitespaces).isEmpty
    }
    dropLeading(while: isBlank)
    dropLeading { visibleText(of: $0).hasPrefix("Last login:") }
    dropLeading(while: isBlank)
    while let last = lines.last, isBlank(last) {
      lines.removeLast()
    }
    if lines.count > maxLines {
      lines.removeFirst(lines.count - maxLines)
    }
    return lines.joined(separator: "\n")
  }

  /// What a line puts on screen, with the escapes that carry no glyphs
  /// removed.
  ///
  /// The rows this exists for are the styled ones made of written
  /// spaces: a TUI's status bar, a selection highlight, a prompt padded
  /// out to the width of the pane. Those cells hold a space and a
  /// background colour, so a styled capture brings them back as SGR
  /// wrapped around blanks, where the raw line is neither empty nor the
  /// text it looks like. Rows the screen was never written to are a
  /// different thing and need no help: they carry no cell text at all,
  /// and the formatter folds them into bare newlines whether the read
  /// is styled or plain. Text in the default style — the `Last login:`
  /// banner, most shell output — comes back unwrapped for the same
  /// reason, so it is only passed through here for uniformity.
  ///
  /// CSI is the whole vocabulary, because it is all a capture can hold.
  /// The formatter runs with no extras, which is what keeps OSC 8,
  /// cursor moves and charset designations out of it, and with a null
  /// palette and no colours, which is what keeps OSC 10/11 out. Those
  /// are ghostty's defaults rather than e05's choices, so the patch in
  /// `patches/ghostty-primary-text.snippet.zig` lists them among the
  /// things to recheck when ghostty is bumped.
  static func visibleText(of line: Substring) -> String {
    guard line.utf8.contains(0x1B) else { return String(line) }
    let bytes = Array(line.utf8)
    var visible: [UInt8] = []
    visible.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
      guard bytes[i] == 0x1B, i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "[") else {
        visible.append(bytes[i])
        i += 1
        continue
      }
      // Parameter and intermediate bytes, then a final byte in
      // 0x40-0x7E. The formatter cannot emit a sequence without one;
      // the loop is bounded so that if anything ever did, it would run
      // to the end of the line rather than leave `[38;5` sitting in
      // front of a prefix test.
      i += 2
      while i < bytes.count, !(0x40...0x7E).contains(bytes[i]) { i += 1 }
      if i < bytes.count { i += 1 }
    }
    return String(decoding: visible, as: UTF8.self)
  }

  /// The last ``maxBytes`` UTF-8 bytes of `text`, opening on a line
  /// boundary. Byte-indexed throughout: `String.suffix` counts grapheme
  /// clusters, which is both the wrong unit for "how much does the shell
  /// have to read" and a full decode of the capture to compute.
  private static func lastBytes(of text: String) -> String {
    guard text.utf8.count > maxBytes else { return text }
    var bytes = Array(text.utf8.suffix(maxBytes))
    if let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) {
      // Drop the partial first line rather than open the replay midway
      // through one. This also discards any scalar the cut landed
      // inside; without a newline there is none to drop, and decoding
      // substitutes U+FFFD for the fragment.
      bytes.removeFirst(newline + 1)
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}
