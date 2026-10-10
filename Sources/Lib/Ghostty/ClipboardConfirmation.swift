import AppKit
import GhosttyKit

/// One representation of clipboard contents, owned by Swift. libghostty
/// lends its representations only for the duration of a callback, and a
/// confirmation outlives that: it is answered when the user decides.
struct ClipboardContent: Equatable {
  let mime: String
  let data: [UInt8]

  init(mime: String, data: [UInt8]) {
    self.mime = mime
    self.data = data
  }

  init(_ content: ghostty_clipboard_content_s) {
    mime = content.mime.map { String(cString: $0) } ?? ""
    data =
      content.data.map {
        Array(UnsafeRawBufferPointer(start: $0, count: content.len))
      } ?? []
  }

  /// The MIME names ghostty's `terminal.clipboard.isTextMime` treats as
  /// text. A Kitty clipboard write keeps the program's own name for its
  /// text, so all of them have to be recognised.
  static let textMimes: Set<String> = [
    "text/plain", "text/plain;charset=utf-8", "UTF8_STRING", "TEXT", "STRING",
  ]

  var isText: Bool { Self.textMimes.contains(mime) }
}

/// Answer a clipboard read request. libghostty borrows the buffers only
/// for the duration of the call, so they are C copies freed on return.
/// A copy rather than strdup for the data: its length is explicit, and
/// text holding a NUL would make strdup stop short of it.
func completeClipboardRequest(
  _ surface: ghostty_surface_t,
  contents: [ClipboardContent],
  available: [String],
  state: UnsafeMutableRawPointer?,
  confirmed: Bool = false,
  remember: Bool = false
) {
  var allocations: [UnsafeMutableRawPointer] = []
  defer {
    for pointer in allocations { free(pointer) }
  }
  func cString(_ string: String) -> UnsafePointer<CChar>? {
    guard let pointer = strdup(string) else { return nil }
    allocations.append(pointer)
    return UnsafePointer(pointer)
  }
  let cContents = contents.compactMap { content -> ghostty_clipboard_content_s? in
    // Never zero bytes, so even an empty representation has a pointer.
    guard let mime = cString(content.mime),
      let data = malloc(max(content.data.count, 1))
    else { return nil }
    allocations.append(data)
    content.data.withUnsafeBytes { bytes in
      if let base = bytes.baseAddress { data.copyMemory(from: base, byteCount: bytes.count) }
    }
    return ghostty_clipboard_content_s(
      mime: mime, data: data.assumingMemoryBound(to: CChar.self), len: content.data.count)
  }
  let cAvailable = available.map(cString)
  cContents.withUnsafeBufferPointer { contentsBuf in
    cAvailable.withUnsafeBufferPointer { availableBuf in
      var complete = ghostty_clipboard_complete_s(
        contents: contentsBuf.baseAddress,
        contents_len: contentsBuf.count,
        available: availableBuf.baseAddress,
        available_len: availableBuf.count,
        confirmed: confirmed,
        remember: remember)
      ghostty_surface_complete_clipboard_request(surface, &complete, state)
    }
  }
}

/// Put the first text representation on the general pasteboard, which
/// stands in for every clipboard location. LIMITATION: a write with no
/// text in it (an image alone) leaves the pasteboard as it was.
func writeClipboard(_ contents: [ClipboardContent]) {
  guard let text = contents.first(where: \.isText) else { return }
  let pasteboard = NSPasteboard.general
  pasteboard.clearContents()
  pasteboard.setString(String(decoding: text.data, as: UTF8.self), forType: .string)
}

/// What a clipboard confirmation asks the user, worded for the request
/// that raised it. libghostty decides whether to ask (its
/// `clipboard-read`, `clipboard-write` and `clipboard-paste-protection`
/// config); this only says what is being asked.
struct ClipboardConfirmation: Equatable {
  enum Kind: Equatable {
    /// The user's own paste, held back because it looks like it would
    /// run commands.
    case paste
    /// A program in the pane asks to read the clipboard.
    case read
    /// A program in the pane asks to write the clipboard.
    case write
  }

  let kind: Kind

  /// The contents shown for review: the text when there is any, a
  /// summary of each representation otherwise.
  let preview: String

  /// Whether an approval can be kept for the rest of the session. Only
  /// a Kitty clipboard request that carries a password can be.
  let canRemember: Bool

  /// The name a Kitty clipboard request gives itself, if any.
  let name: String?

  /// `nil` for a request there is nothing to ask about: a listing of
  /// the available types, which never asks, and a write with no text,
  /// which ``writeClipboard(_:)`` would drop whatever the answer.
  init?(
    request: ghostty_clipboard_request_e, contents: [ClipboardContent], canRemember: Bool,
    name: String? = nil
  ) {
    switch request {
    case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
      kind = .paste
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ:
      kind = .read
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE:
      kind = .write
    default:
      return nil
    }
    if kind == .write && !contents.contains(where: \.isText) { return nil }
    preview = Self.preview(of: contents)
    self.canRemember = canRemember
    self.name = name.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// How much text the preview shows. The sheet lays the whole preview
  /// out on the main thread before it appears, and a clipboard can hold
  /// megabytes; past this the rest is counted rather than shown.
  static let previewLimit = 64 * 1024

  static func preview(of contents: [ClipboardContent]) -> String {
    guard let text = contents.first(where: \.isText) else {
      return contents.map { "\($0.mime) (\($0.data.count) bytes)" }.joined(separator: "\n")
    }
    guard text.data.count > previewLimit else {
      return String(decoding: text.data, as: UTF8.self)
    }
    let rest = text.data.count - previewLimit
    return String(decoding: text.data.prefix(previewLimit), as: UTF8.self)
      + "\n… \(rest) more bytes"
  }

  var messageText: String {
    switch kind {
    case .paste: "Paste text that may run commands?"
    case .read: "Allow a program to read the clipboard?"
    case .write: "Allow a program to write to the clipboard?"
    }
  }

  var informativeText: String {
    switch kind {
    case .paste:
      "Pasting this text into the terminal may be dangerous, as it looks like some commands may be run."
    case .read:
      "A program in this pane\(requester) asked for the current clipboard contents, shown below."
    case .write:
      "A program in this pane\(requester) asked to put the contents below on the clipboard."
    }
  }

  private var requester: String { name.map { ", calling itself “\($0)”," } ?? "" }

  var confirmTitle: String { kind == .paste ? "Paste" : "Allow" }
  var cancelTitle: String { kind == .paste ? "Cancel" : "Deny" }

  /// Return answers the paste the user asked for, but nothing answers a
  /// program's request from the keyboard except Escape, which denies: a
  /// prompt a program raises can appear the moment the user presses
  /// Return for something else, and that keystroke must not be the one
  /// that hands over the clipboard.
  var returnConfirms: Bool { kind == .paste }
}
