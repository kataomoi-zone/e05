import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "Scrollback")

/// On-disk terminal scrollback, captured at save time and replayed into
/// the shell on restore.
///
/// libghostty has no way to write into a surface's screen — the only
/// output path is the child process's stdout — so a restored pane gets
/// its history back by having the shell `cat` a file before its first
/// prompt. `e05-integration.{zsh,bash}` does that and deletes the file,
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
  /// could land invisible against it — the failure mode that makes
  /// replaying a styled capture unattractive in the first place.
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
    var lines = Self.lastBytes(of: text).split(separator: "\n", omittingEmptySubsequences: false)
    // A previous replay's rule is now ordinary scrollback, and keeping it
    // would leave one more rule per restart. Unlike the banner these sit
    // mid-history, so the whole capture is filtered rather than just its
    // head. Only the newest rule — appended after this — is wanted.
    lines.removeAll { $0.hasPrefix(rulePrefix) && $0.hasSuffix(ruleSuffix) }
    func dropLeading(while matches: (Substring) -> Bool) {
      while let first = lines.first, matches(first) {
        lines.removeFirst()
      }
    }
    dropLeading { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    dropLeading { $0.hasPrefix("Last login:") }
    dropLeading { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      lines.removeLast()
    }
    if lines.count > maxLines {
      lines.removeFirst(lines.count - maxLines)
    }
    return lines.joined(separator: "\n")
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
