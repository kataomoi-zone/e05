import AppKit
import WebKit

/// Browser-side overlay that rebrands Chrome Web Store's install
/// affordances ("Add to Chrome" / "Remove from Chrome" / the
/// banner's "Chrome をインストール" link) to read in terms of e05 and
/// routes their clicks to the host install pipeline.
///
/// Brave applies the same approach (`brave/brave-core` →
/// `components/brave_extension/extension/brave_extension/webstore.ts`):
/// a content script + MutationObserver that swaps the textContent on
/// the install button. CWS itself does no client-side branding
/// detection, so DOM rewrite alone makes the visible label match the
/// host browser. Brave inherits Chromium's install flow
/// (`chrome.webstorePrivate.beginInstallWithManifest3` →
/// `WebstoreInstaller`) and CWS install-state tracking via
/// `chrome.management`, so its rebrand needs no install-side
/// bookkeeping. WKWebView ships none of those APIs, so this overlay
/// adds two pieces of plumbing on top of the rewrite:
///
/// 1. Click intercept: the click is captured before CWS's own
///    handler so the request never reaches `chrome.webstorePrivate`
///    (which would otherwise log a console error and stall). The
///    intercepted extension ID is posted to Swift, where
///    ``ExtensionController/installFromChromeWebStore(extensionID:)``
///    or ``ExtensionController/uninstallChromeWebStoreExtension(extensionID:)``
///    runs depending on whether the extension is already installed.
/// 2. Install state push: the host writes the live install ID list
///    into `window.__e05InstalledExtensions` whenever the underlying
///    `loadedExtensions` snapshot changes; the script consults that
///    array to choose between "Add to E05" and "Remove from E05"
///    text, since CWS's own button textContent would otherwise stay
///    on "Add to Chrome" forever (no Chromium API means no state
///    feedback from e05 to CWS's DOM).
///
/// Rebranding strategy: instead of enumerating every CWS locale,
/// substitute the literal `Chrome` substring with `E05` on any node
/// matched by the install-button selector. Brave's approach uses an
/// enumerated phrase table plus a literal `replace('Chrome', 'Brave')`
/// fallback; the e05 overlay drops the table entirely and relies on
/// the substring substitution alone — the selector already restricts
/// the rewrite to install-button-shaped DOM, so unrelated occurrences
/// of "Chrome" on the page are untouched. This gives the rebrand
/// 50+ locale coverage with zero translation work, and any future
/// CWS localization comes for free.
///
/// CWS rolled out a new layout under `chromewebstore.google.com` in
/// 2023, retaining the legacy `chrome.google.com/webstore/*` for
/// older deep links. Both surfaces are matched. Selectors mirror the
/// upstream Brave script: `div.webstore-test-button-label` for the
/// old layout, `button span[jsname]:not(:empty)` for the new one.
/// New CWS uses Google's internal framework with `jsname` attributes
/// whose values change build-to-build, so the substring match keys
/// off textContent rather than any stable DOM identifier.
@MainActor
enum ChromeWebStoreOverlay {
  /// `WKScriptMessage.name` the injected script posts under for
  /// install / uninstall clicks (fire-and-forget).
  static let handlerName = "e05CWSInstall"

  /// `WKScriptMessage.name` used by the user script's startup query
  /// for the current install ID list. Routed through
  /// `addScriptMessageHandlerWithReply` so the `await` on the JS
  /// side resolves before the first MutationObserver pass — keeps
  /// the rebranded button text on the right side ("Add to E05" vs
  /// "Remove from E05") from the page's first paint instead of
  /// flickering after the post-`didFinish` push.
  static let stateHandlerName = "e05CWSState"

  /// Single shared `WKUserScript` instance — the source is immutable,
  /// so the same script can be attached to every pane's
  /// `WKUserContentController` without duplicating the string.
  static let userScript: WKUserScript = {
    let source = #"""
      (async function() {
        'use strict';
        const host = location.host;
        if (host !== 'chromewebstore.google.com' && host !== 'chrome.google.com') {
          return;
        }
        // Fetch the install state from Swift before the first rewrite
        // runs so the initial paint already reflects the correct "Add
        // to E05" / "Remove from E05" wording. `WKScriptMessageHandlerWithReply`
        // crosses the UI ↔ WebContent process boundary so the reply is
        // not literally synchronous, but it resolves before any
        // user-script-driven DOM read because the IIFE is the only JS
        // running on this turn — the await yields back to the page
        // event loop, which has no other queued work between
        // document_start and our continuation.
        try {
          const ids = await webkit.messageHandlers.e05CWSState.postMessage(null);
          window.__e05InstalledExtensions = Array.isArray(ids) ? ids : [];
        } catch (e) {
          console.error('[e05/cws-overlay] state fetch failed:', e);
          window.__e05InstalledExtensions = window.__e05InstalledExtensions || [];
        }
        const SELECTOR =
          'div.webstore-test-button-label, button span[jsname]:not(:empty)';

        function extensionIDFromURL() {
          // CWS extension IDs use Google's base16-shifted alphabet
          // (a-p only); matching that here mirrors the Swift-side
          // `installedChromeWebStoreIDs` filter so the install-state
          // check can't false-match on a malformed listing URL.
        const m = location.pathname.match(/\/detail\/[^/]+\/([a-p]{32})/);
          return m ? m[1] : null;
        }

        function isInstalled(id) {
          return Array.isArray(window.__e05InstalledExtensions)
            && window.__e05InstalledExtensions.indexOf(id) >= 0;
        }

        // Switch between the add and remove wording when the live
        // install state disagrees with the textContent (either CWS's
        // own "Add to Chrome" form because chrome.management is
        // unavailable to inform it of the install, or our prior
        // rewrite of the same node from a previous pass). The
        // mapping is locale-keyed and lossy on languages we haven't
        // seen — the unmatched fallback returns the input as-is so a
        // missing translation doesn't lie about the action.
        function flipToRemove(text) {
          if (text.indexOf('Add to ') === 0) {
            return text.replace('Add to ', 'Remove from ');
          }
          if (text.indexOf(' に追加') >= 0) {
            return text.replace(' に追加', ' から削除');
          }
          if (text.indexOf('に追加') >= 0) {
            return text.replace('に追加', 'から削除');
          }
          return text;
        }
        function flipToAdd(text) {
          if (text.indexOf('Remove from ') === 0) {
            return text.replace('Remove from ', 'Add to ');
          }
          if (text.indexOf(' から削除') >= 0) {
            return text.replace(' から削除', ' に追加');
          }
          if (text.indexOf('から削除') >= 0) {
            return text.replace('から削除', 'に追加');
          }
          return text;
        }

        // Rewriting textContent / button attributes is itself a DOM
        // mutation, so the observer re-fires on our own writes. Pause
        // observation for the duration of a rewrite pass to avoid a
        // ping-pong between this script and any CWS re-render that
        // reasserts the disabled attribute (CWS is Lit-based and
        // re-renders are rare, but the rebrand needs to be stable
        // even if Google ships a chattier component tomorrow).
        let observer = null;
        function rewrite() {
          if (observer) observer.disconnect();
          try {
            rewriteInner();
          } finally {
            if (observer) observer.observe(document, { attributes: true, childList: true, subtree: true });
          }
        }
        function rewriteInner() {
          const id = extensionIDFromURL();
          const installed = id ? isInstalled(id) : false;
          const nodes = document.querySelectorAll(SELECTOR);
          for (const node of nodes) {
            const text = (node.textContent || '').trim();
            // Re-process nodes already carrying our rebranded text so
            // the install-state direction stays current when the
            // installed-IDs push arrives after the first rewrite
            // pass. Without the E05 check the second pass would skip
            // a node we just changed and the wording would be stuck
            // on whichever direction the first pass landed on.
            if (!text.includes('Chrome') && !text.includes('E05')) continue;
            // `replace('Chrome','E05')` runs before flipToRemove /
            // flipToAdd so the verb checks ("Add to ", " に追加") see
            // a stable subject regardless of the source locale —
            // sidesteps an enumerated locale table while keeping the
            // direction flip locale-aware.
            let next = text.replace('Chrome', 'E05');
            next = installed ? flipToRemove(next) : flipToAdd(next);
            if (text === next) continue;
            node.textContent = next;
            // CWS disables the install button when it can't identify
            // the host as a Chromium-derived browser. Brave gets a
            // free pass because it is Chromium; WKWebView is not, so
            // strip the disabled signal from the enclosing button so
            // the capture-phase click handler below can intercept the
            // press and route it into e05's install pipeline. The
            // visual gating (opacity / pointer-events) comes from a
            // build-keyed CSS class on top of the `disabled` attribute;
            // overriding the inline style overrides the class for
            // free.
            const button = node.closest('button');
            if (button) {
              button.removeAttribute('disabled');
              button.removeAttribute('aria-disabled');
              button.style.opacity = '1';
              button.style.pointerEvents = 'auto';
              button.style.cursor = 'pointer';
            }
          }
        }

        // Match install / uninstall button text in any locale, before
        // or after the rewrite (Chrome → E05). Substring match on
        // either brand name is enough to catch the install affordance
        // since the SELECTOR has already narrowed the click target to
        // install-button-shaped DOM.
        function isInstallButton(text) {
          return /Chrome|E05/.test(text);
        }
        document.addEventListener('click', (event) => {
          const target = event.target.closest('button, div.webstore-test-button-label');
          if (!target) return;
          const text = (target.textContent || '').trim();
          if (!isInstallButton(text)) return;
          const id = extensionIDFromURL();
          if (!id) return;
          event.preventDefault();
          event.stopPropagation();
          const installed = isInstalled(id);
          window.webkit.messageHandlers.e05CWSInstall.postMessage({
            extensionID: id,
            uninstall: installed
          });
        }, true);

        // Rerun whenever the install state push from Swift hits the
        // page (and an explicit hook the host calls right after).
        window.__e05CWSOverlayRewrite = rewrite;

        observer = new MutationObserver(rewrite);
        observer.observe(document, { attributes: true, childList: true, subtree: true });
        rewrite();
      })();
      """#
    return WKUserScript(
      source: source,
      injectionTime: .atDocumentStart,
      forMainFrameOnly: false
    )
  }()

  /// Snippet the host evaluates against each browser pane every
  /// time the live install-ID set changes (after a CWS install or
  /// any sidebar mutation that fires
  /// ``ExtensionController/didChangeNotification``). Sets the JS-
  /// side mirror used by the user script and re-runs the rewrite
  /// pass so the live button text follows the state immediately.
  static func installedIDsSnippet(_ ids: [String]) -> String {
    let json: String = {
      if let data = try? JSONSerialization.data(withJSONObject: ids, options: []),
        let s = String(data: data, encoding: .utf8)
      {
        return s
      }
      return "[]"
    }()
    return """
      window.__e05InstalledExtensions = \(json);
      if (typeof window.__e05CWSOverlayRewrite === 'function') {
        window.__e05CWSOverlayRewrite();
      }
      """
  }
}

/// Replies to the user script's startup query for the current
/// install ID list. Pulled at message time rather than at handler
/// construction so a pane that outlives several install /
/// uninstall cycles always returns the live snapshot.
@MainActor
final class ChromeWebStoreStateHandler: NSObject, WKScriptMessageHandlerWithReply {
  /// Read on every incoming query — see class doc. Set by the host
  /// pane immediately after attaching the handler.
  var idsProvider: (@MainActor () -> [String])?

  func userContentController(
    _: WKUserContentController,
    didReceive message: WKScriptMessage,
    replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
  ) {
    guard message.name == ChromeWebStoreOverlay.stateHandlerName else {
      replyHandler(nil, "unexpected handler name: \(message.name)")
      return
    }
    let ids = idsProvider?() ?? []
    replyHandler(ids, nil)
  }
}

/// Forwards `e05CWSInstall` messages posted by the user script to a
/// Swift closure. Kept outside the host view so
/// `WKUserContentController` can hold the weak reference without
/// re-introducing a retain cycle with the pane.
@MainActor
final class ChromeWebStoreInstallHandler: NSObject, WKScriptMessageHandler {
  /// Invoked with the 32-character Chrome Web Store extension ID
  /// and a flag indicating whether the user clicked an already-
  /// installed listing (i.e. an uninstall intent).
  var onAction: ((_ extensionID: String, _ uninstall: Bool) -> Void)?

  nonisolated func userContentController(
    _: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    MainActor.assumeIsolated {
      guard message.name == ChromeWebStoreOverlay.handlerName else { return }
      guard let body = message.body as? [String: Any],
        let id = body["extensionID"] as? String,
        !id.isEmpty
      else { return }
      let uninstall = (body["uninstall"] as? Bool) ?? false
      onAction?(id, uninstall)
    }
  }
}
