import GhosttyKit
import Testing

@testable import E05Lib

@Suite("ClipboardConfirmation")
struct ClipboardConfirmationTests {
  private let text = [ClipboardContent(mime: "text/plain", data: Array("hi".utf8))]

  private func confirmation(
    _ request: ghostty_clipboard_request_e, _ contents: [ClipboardContent] = []
  ) -> ClipboardConfirmation? {
    ClipboardConfirmation(request: request, contents: contents, canRemember: false)
  }

  @Test("each request is worded as a paste, a read or a write")
  func kinds() {
    #expect(confirmation(GHOSTTY_CLIPBOARD_REQUEST_PASTE)?.kind == .paste)
    #expect(confirmation(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ)?.kind == .read)
    #expect(confirmation(GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ)?.kind == .read)
    #expect(confirmation(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, text)?.kind == .write)
    #expect(confirmation(GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE, text)?.kind == .write)
  }

  @Test("a type listing never asks")
  func listingNeverAsks() {
    #expect(confirmation(GHOSTTY_CLIPBOARD_REQUEST_LIST) == nil)
  }

  @Test("Return pastes for the user, but never answers a program")
  func defaultButton() {
    #expect(confirmation(GHOSTTY_CLIPBOARD_REQUEST_PASTE)?.returnConfirms == true)
    #expect(confirmation(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ)?.returnConfirms == false)
    #expect(confirmation(GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE, text)?.returnConfirms == false)
  }

  @Test("a write with no text is not asked about, since none of it would be written")
  func textlessWriteNeverAsks() {
    let image = [ClipboardContent(mime: "image/png", data: [1])]
    #expect(confirmation(GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, image) == nil)
    #expect(confirmation(GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE, image) == nil)
    #expect(confirmation(GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ, image) != nil)
  }

  @Test("a long clipboard is previewed up to the limit, with the rest counted")
  func previewIsCapped() {
    let limit = ClipboardConfirmation.previewLimit
    let preview = ClipboardConfirmation.preview(of: [
      ClipboardContent(mime: "text/plain", data: Array(repeating: 0x61, count: limit + 10))
    ])
    #expect(preview == String(repeating: "a", count: limit) + "\n… 10 more bytes")
  }

  @Test("a request's own name is quoted in the prompt")
  func nameIsShown() {
    let named = ClipboardConfirmation(
      request: GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ, contents: [], canRemember: true,
      name: "vault")
    #expect(named?.informativeText.contains("“vault”") == true)
    #expect(
      confirmation(GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ)?.informativeText.contains("“") == false)
  }

  @Test("the preview is the text, under any of ghostty's text MIME names")
  func previewShowsText() {
    let preview = ClipboardConfirmation.preview(of: [
      ClipboardContent(mime: "image/png", data: [0x89, 0x50]),
      ClipboardContent(mime: "UTF8_STRING", data: Array("echo hi".utf8)),
    ])
    #expect(preview == "echo hi")
  }

  @Test("without text, the preview names each representation and its size")
  func previewSummarisesBinary() {
    let preview = ClipboardConfirmation.preview(of: [
      ClipboardContent(mime: "image/png", data: [1, 2, 3])
    ])
    #expect(preview == "image/png (3 bytes)")
  }

  @Test("a C representation is copied by its length, NULs included")
  func copiesByLength() {
    let bytes: [CChar] = [0x61, 0x00, 0x62, 0x63]
    let content = "text/plain".withCString { mime in
      bytes.withUnsafeBufferPointer { data in
        ClipboardContent(
          ghostty_clipboard_content_s(mime: mime, data: data.baseAddress, len: 3))
      }
    }
    #expect(content == ClipboardContent(mime: "text/plain", data: [0x61, 0x00, 0x62]))
  }
}
