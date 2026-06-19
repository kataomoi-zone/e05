import AppKit
import GhosttyKit

/// What a "copy command" affordance pulls from a shell command's OSC 133
/// region. Raw values match the `mode` argument of the libghostty patch.
enum TerminalCommandScope: UInt8 {
  /// The command's output only.
  case output = 0
  /// The command's prompt line(s) — the command as shown, with its prompt
  /// decoration — through the end of its output.
  case commandAndOutput = 1
  /// The typed command only — no prompt decoration, no output. Supported by
  /// the patch but not surfaced in the UI: it needs the OSC 133 B input
  /// mark, which dynamic prompts (starship, p10k) don't emit, so it would
  /// resolve only on some shells.
  case command = 2
}

/// Shell command text via OSC 133 semantic prompt marks, exposed by the
/// local libghostty patch `ghostty_surface_command_text` (see
/// `patches/ghostty-command-text.patch`). Backs the terminal's "Copy
/// Command Output" affordances.
extension GhosttyTerminalView {
  /// Text from a shell command's OSC 133 region per `scope`. `cell` nil
  /// targets the most recently completed command; a cell targets the
  /// command whose region contains it. Returns nil with no surface, no
  /// shell integration, or no such command.
  func commandText(at cell: (column: Int, row: Int)?, scope: TerminalCommandScope) -> String? {
    guard let surface else { return nil }
    let point = ghostty_point_s(
      tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
      x: UInt32(cell?.column ?? 0), y: UInt32(cell?.row ?? 0))
    var out = ghostty_text_s()
    guard ghostty_surface_command_text(surface, point, cell == nil, scope.rawValue, &out) else {
      return nil
    }
    defer { ghostty_surface_free_text(surface, &out) }
    guard let ptr = out.text, out.text_len > 0 else { return nil }
    let raw = ptr.withMemoryRebound(to: UInt8.self, capacity: Int(out.text_len)) {
      String(decoding: UnsafeBufferPointer(start: $0, count: Int(out.text_len)), as: UTF8.self)
    }
    return Self.normalizedCommandText(raw)
  }

  /// Trim the shell's leading / trailing blank lines — a themed prompt pads
  /// itself with empty lines that land in the command region — and end with
  /// a single newline so a pasted command reads cleanly. nil when nothing
  /// substantive remains.
  nonisolated static func normalizedCommandText(_ raw: String) -> String? {
    var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    while let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.removeFirst()
    }
    while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.removeLast()
    }
    guard !lines.isEmpty else { return nil }
    return lines.joined(separator: "\n") + "\n"
  }
}
