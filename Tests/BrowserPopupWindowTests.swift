import AppKit
import Testing

@testable import E05Lib

/// The two decisions a popup rests on. `WKWindowFeatures` cannot be
/// built in a test — every property is read-only — so both are
/// separated from the window they configure and pinned here; the rest
/// of the controller is AppKit and WebKit wiring a unit test cannot
/// reach.
@Suite("BrowserPopupWindowController")
@MainActor
struct BrowserPopupWindowTests {
  // MARK: - Where the request goes

  /// Every "open in new tab" button on the web is a `window.open`
  /// with no features, and answering those with a chrome-less panel
  /// would be a worse place to read than a pane with a URL bar. This
  /// decides placement only — either answer keeps the opening page
  /// connected to what it opened.
  @Test("a request naming no window shape is a new tab, not a window")
  func featurelessOpenIsATab() {
    #expect(
      !BrowserPopupWindowController.requestsWindow(
        width: nil, height: nil, x: nil, y: nil,
        menuBar: nil, statusBar: nil, toolbars: nil))
  }

  /// Each feature on its own, because a page may name only one, and a
  /// check reduced to whichever pair is listed first would still pass
  /// a test that only tried width and height together.
  @Test("any window feature at all makes it a window")
  func anyFeatureMakesAWindow() {
    // The shape a sign-in takes.
    #expect(
      BrowserPopupWindowController.requestsWindow(
        width: 500, height: 600, x: nil, y: nil,
        menuBar: nil, statusBar: nil, toolbars: nil))

    #expect(
      BrowserPopupWindowController.requestsWindow(
        width: 500, height: nil, x: nil, y: nil,
        menuBar: nil, statusBar: nil, toolbars: nil))
    #expect(
      BrowserPopupWindowController.requestsWindow(
        width: nil, height: 600, x: nil, y: nil,
        menuBar: nil, statusBar: nil, toolbars: nil))
    #expect(
      BrowserPopupWindowController.requestsWindow(
        width: nil, height: nil, x: 10, y: nil,
        menuBar: nil, statusBar: nil, toolbars: nil))
    #expect(
      BrowserPopupWindowController.requestsWindow(
        width: nil, height: nil, x: nil, y: 10,
        menuBar: nil, statusBar: nil, toolbars: nil))
    #expect(
      BrowserPopupWindowController.requestsWindow(
        width: nil, height: nil, x: nil, y: nil,
        menuBar: false, statusBar: nil, toolbars: nil))
    #expect(
      BrowserPopupWindowController.requestsWindow(
        width: nil, height: nil, x: nil, y: nil,
        menuBar: nil, statusBar: false, toolbars: nil))
    #expect(
      BrowserPopupWindowController.requestsWindow(
        width: nil, height: nil, x: nil, y: nil,
        menuBar: nil, statusBar: nil, toolbars: false))
  }

  // MARK: - What it says it is

  /// The window has no URL bar, so the title is the only place an
  /// origin can appear — and the page picks its own title. A page
  /// calling itself a sign-in screen has to stay separable from the
  /// host actually serving it.
  @Test("the host leads the title, ahead of what the page calls itself")
  func hostLeadsTheTitle() {
    #expect(
      BrowserPopupWindowController.panelTitle(
        host: "accounts.google.com", pageTitle: "Sign in")
        == "accounts.google.com — Sign in")
  }

  /// A popup opens `about:blank` and swaps its location afterwards, so
  /// both halves arrive separately and either can be missing.
  @Test("whichever half is missing, the other stands alone")
  func fallsBackToWhicheverHalfExists() {
    #expect(
      BrowserPopupWindowController.panelTitle(host: "example.com", pageTitle: "")
        == "example.com")
    #expect(
      BrowserPopupWindowController.panelTitle(host: "", pageTitle: "Untitled")
        == "Untitled")
    #expect(BrowserPopupWindowController.panelTitle(host: "", pageTitle: "") == "")
  }

  // MARK: - How big it is

  @Test("a page that asks for nothing gets a usable window")
  func defaultsWhenUnspecified() {
    let size = BrowserPopupWindowController.contentSize(width: nil, height: nil)
    #expect(size.width == 600)
    #expect(size.height == 700)
  }

  @Test("a size the page asked for is honoured")
  func honoursRequestedSize() {
    let size = BrowserPopupWindowController.contentSize(width: 480, height: 640)
    #expect(size.width == 480)
    #expect(size.height == 640)
  }

  /// Both ends matter: a sign-in window at 60 by 40 cannot be used, and
  /// one larger than the display cannot be moved off whatever it
  /// covers.
  @Test("sizes outside what a window can be are clamped")
  func clampsExtremes() {
    let tiny = BrowserPopupWindowController.contentSize(width: 60, height: 40)
    #expect(tiny.width == 320)
    #expect(tiny.height == 240)

    let huge = BrowserPopupWindowController.contentSize(width: 5000, height: 4000)
    #expect(huge.width == 1200)
    #expect(huge.height == 1000)
  }
}
