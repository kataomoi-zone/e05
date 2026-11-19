import AppKit
import Testing
import WebKit

@testable import E05Lib

@MainActor
@Suite("Browser page undo")
struct BrowserPageUndoTests {
  func spin(_ seconds: Double, until: () -> Bool) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
  }

  func value(_ web: WKWebView) async throws -> String? {
    try await web.evaluateJavaScript("document.getElementById('i').value") as? String
  }

  @Test("typing undoes on the web view's own manager, never the window's")
  func typingStaysOffTheWindow() async throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let web = FocusReportingWebView(frame: window.contentView!.bounds)
    window.contentView!.addSubview(web)
    defer {
      web.removeFromSuperview()
      window.close()
    }
    window.makeFirstResponder(web)
    let undo = try #require(web.undoManager)
    // WebKit registers the edit asynchronously, and the first attempt
    // can land before the page has the input focused.
    for _ in 0..<10 where !undo.canUndo {
      _ = try await web.evaluateJavaScript(
        """
        if (!document.getElementById('i')) {
          const e = document.createElement('input'); e.id = 'i';
          (document.body || document.documentElement).appendChild(e);
        }
        document.getElementById('i').focus();
        document.execCommand('insertText', false, 'abc');
        """)
      spin(1) { undo.canUndo }
    }
    #expect(undo.canUndo)
    #expect(window.undoManager?.canUndo == false)

    let item = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "")
    #expect(web.validateUserInterfaceItem(item))
    #expect(item.title == undo.undoMenuItemTitle)

    // Walks the responder chain the way the Edit menu's nil-targeted
    // action does.
    #expect(web.tryToPerform(NSSelectorFromString("undo:"), with: nil))
    spin(2) { undo.canRedo }
    #expect(try await value(web) == "")

    #expect(web.tryToPerform(NSSelectorFromString("redo:"), with: nil))
    spin(2) { undo.canUndo }
    #expect(try await value(web) == "abc")
  }
}
