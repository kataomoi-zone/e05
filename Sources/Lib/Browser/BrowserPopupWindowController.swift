import AppKit
import WebKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "BrowserPopup")

/// A web popup — what `window.open()` asks for — in an auxiliary panel.
///
/// The page that opened it holds a reference to it and expects to talk
/// to it: a sign-in flow hands the token back through `window.opener`
/// and then closes itself. That relationship is WebKit's to establish,
/// and it only does so for a web view built from the configuration it
/// hands to `createWebViewWith`. So this controller adopts a web view
/// rather than making one, and never loads anything into it — WebKit
/// runs the navigation the opener asked for.
///
/// A panel rather than a pane, like the app's other auxiliary surfaces:
/// a popup is transient and closes itself, and a pane appearing and
/// vanishing mid-flow would shift the whole column layout under the
/// user. It also puts the popup's requested size to use, which a tiled
/// pane could not honour.
///
/// Known gap: no `WKNavigationDelegate` is attached, so three things a
/// pane has are missing here — a download goes nowhere, a failed load
/// shows no error page, and a web content process that dies leaves a
/// blank panel rather than reloading. The pane implements those
/// against itself, and lending them out would let a popup's navigation
/// write to the pane's URL bar and history. Sign-in popups, which is
/// what these are, do none of the three. Content blocking is not in
/// that list: the rule lists and content scripts ride on the
/// configuration WebKit hands over, so a popup is filtered like its
/// opener.
@MainActor
final class BrowserPopupWindowController: NSWindowController, NSWindowDelegate {
  /// The adopted web view. Held so the opener can find the controller
  /// that owns a given view, and for the title observation below.
  let webView: WKWebView

  /// Called once, with `self`, when the popup goes away however it goes
  /// away: the page closing itself, or the user closing the panel. The
  /// opener uses it to drop its reference. It takes the controller as
  /// an argument rather than closing over it, which would be a cycle
  /// through the property it is stored in.
  var onClose: ((BrowserPopupWindowController) -> Void)?

  private var titleObservation: NSKeyValueObservation?
  private var urlObservation: NSKeyValueObservation?
  private var didFinish = false

  /// Matches what the main window shows for a private pane, so the two
  /// read as the same session rather than as two unrelated windows.
  static let privateTitle = "Private Browsing"

  /// Whether a script's `window.open` asked for a window or for what
  /// every browser calls a new tab.
  ///
  /// `window.open(url)` and `window.open(url, '_blank')` are the idiom
  /// for "open this elsewhere" — dashboards, documents, a PDF link —
  /// and they belong in a pane, where there is a URL bar, history, and
  /// somewhere for a download to go. A page that names a size or a
  /// position wants a window, and that is the shape a sign-in takes.
  /// Chromium and WebKit draw the line in the same place: any window
  /// feature at all makes it a popup.
  ///
  /// The cost of sending the featureless case to a pane is that the
  /// opener relationship is lost — a pane builds its own web view — so
  /// a page using `window.open(url)` *and* expecting to talk to it is
  /// served worse than a sign-in is. Nothing observed does that, and
  /// the alternative is a window with no address bar for every "open
  /// in new tab" button on the web.
  static func requestsWindow(
    width: Double?, height: Double?, x: Double?, y: Double?,
    menuBar: Bool?, statusBar: Bool?, toolbars: Bool?
  ) -> Bool {
    width != nil || height != nil || x != nil || y != nil
      || menuBar != nil || statusBar != nil || toolbars != nil
  }

  /// What the page asked for, within reason. A page that asks for
  /// 60×60 or for more than the screen gets something usable instead.
  /// Position is not honoured: a window placed by a page tends to land
  /// somewhere unhelpful on a multi-display desktop, and `center()` is
  /// the better answer.
  /// What the title bar says. The host comes first because the page
  /// controls its own title and this window has nowhere else to show
  /// an address: a page that titles itself "Sign in to Google" in a
  /// window with no URL bar leaves nothing to check it against. The
  /// title still follows, since it is what distinguishes one page on
  /// a host from another.
  static func panelTitle(host: String, pageTitle: String) -> String {
    guard !host.isEmpty else { return pageTitle }
    guard !pageTitle.isEmpty else { return host }
    return "\(host) — \(pageTitle)"
  }

  static func contentSize(width: Double?, height: Double?) -> NSSize {
    NSSize(
      width: min(max(width ?? 600, 320), 1200),
      height: min(max(height ?? 700, 240), 1000))
  }

  /// `masksTitle` comes from a private workspace. The main window
  /// already replaces its title with a fixed string while a private
  /// pane has focus, so that Mission Control, the window switcher and
  /// a screen recording cannot read the site from it. A panel carrying
  /// the site's own title would put back exactly what that hides, so
  /// popups from a private pane are titled the same fixed way and
  /// nothing about the page is observed at all.
  init(webView: WKWebView, features: WKWindowFeatures, masksTitle: Bool) {
    self.webView = webView

    let size = Self.contentSize(
      width: features.width?.doubleValue, height: features.height?.doubleValue)
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: true
    )
    panel.isReleasedWhenClosed = false
    // Not floating: a sign-in window is something to work in, not an
    // inspector to keep above everything, and pinning it over the app
    // would leave it covering panes the user switches to while it is
    // open. It does stay up when e05 is not frontmost, so going to
    // another app for a password does not dismiss it.
    panel.isFloatingPanel = false
    panel.level = .normal
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.fullScreenAuxiliary]
    panel.center()

    super.init(window: panel)

    panel.delegate = self
    panel.contentView = webView

    guard !masksTitle else {
      panel.title = Self.privateTitle
      return
    }

    // The title bar is the only thing telling the user which site is
    // asking, which matters most on the sign-in pages these windows
    // exist for. Both the title and the URL are observed: a popup that
    // opens `about:blank` and swaps its location afterwards — the shape
    // most sign-in flows take — would otherwise sit untitled, because
    // no title ever arrives to trigger a title-only observation.
    // Both observations do the same thing: hop to the main actor and
    // read both halves there. The web view's `url` and `title` are
    // main-actor properties and the observation block is not, so the
    // read has to happen after the hop rather than inside the block.
    titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.applyTitle() }
    }
    urlObservation = webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.applyTitle() }
    }
  }

  private func applyTitle() {
    window?.title = Self.panelTitle(
      host: webView.url?.host(percentEncoded: false) ?? "",
      pageTitle: webView.title ?? "")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func windowWillClose(_: Notification) {
    finish()
  }

  /// Runs once, whoever closes the window. `close()` sends
  /// `windowWillClose` synchronously, so the script path and the user
  /// path both arrive here.
  private func finish() {
    guard !didFinish else { return }
    didFinish = true
    titleObservation = nil
    urlObservation = nil
    // A permission sheet hung on this panel has to be answered before
    // the panel it is attached to goes away: its completion is what
    // resolves the request and lets the pane's queue move on, and an
    // unanswered one would stall every later prompt behind it.
    // Ending it counts as declining, which is the right reading of
    // closing the window the request came from.
    if let sheet = window?.attachedSheet {
      window?.endSheet(sheet)
    }
    // A sign-in page interrupted mid-load would otherwise keep its web
    // content process running behind a closed window.
    webView.stopLoading()
    window?.contentView = nil
    logger.debug("[popup] closed")
    // Handing self over is the last thing done: the callback drops the
    // opener's reference, which is usually the only one left. Deferred
    // because the user's own close arrives here from inside
    // `windowWillClose`, and releasing the controller there would take
    // the window announcing its own close with it.
    let callback = onClose
    onClose = nil
    DispatchQueue.main.async { [self] in
      callback?(self)
    }
  }
}
