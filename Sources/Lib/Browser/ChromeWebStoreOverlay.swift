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
/// Rebranding strategy: on the install button, swap the literal
/// `Chrome` substring for `E05` and flip the add/remove direction
/// from the live install state. The new-layout selector (`button
/// span[jsname]`) also matches the "install Chrome / switch to
/// Chrome" promo banner CWS shows non-Chromium browsers, so the
/// rewrite — and the click intercept — must tell the two apart. They
/// do it by state, not by label: CWS ships the install button
/// `disabled` to hosts it can't verify as Chromium, while the promo's
/// download link is a normal enabled link. That signal is locale-
/// independent, so the install keeps working in every CWS locale (the
/// brand stays literal "Chrome" worldwide); only the add/remove
/// direction flip is English + Japanese, and other locales keep CWS's
/// own verb. Once the rewrite strips `disabled`, a `dataset` claim
/// flag keeps the button recognised on later passes. The old layout's
/// `div.webstore-test-button-label` is an install-only class, so it
/// qualifies unconditionally.
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

        // Tell the extension's install button apart from the "install
        // Chrome / switch to Chrome" promo banner that shares SELECTOR,
        // and from any other disabled control on the page. Two locale-
        // independent signals: CWS ships the install button `disabled`
        // to hosts it can't verify as Chromium (the promo's download
        // link stays enabled), and the install label carries the brand
        // substring — "Chrome" untranslated in every CWS locale, or our
        // "E05" after the rewrite. `disabled` excludes the promo banner;
        // the brand check excludes unrelated `disabled`/`aria-disabled`
        // buttons (Google's components mark many controls `aria-disabled`
        // while leaving them clickable), so a press on one can't be
        // mistaken for an install. The `e05Install` claim flag keeps the
        // button recognised after the rewrite strips `disabled`. The old
        // layout's `div.webstore-test-button-label` is an install-only
        // class, so it qualifies unconditionally.
        function installButton(node) {
          if (node.classList && node.classList.contains('webstore-test-button-label')) {
            return node.closest('button') || node;
          }
          const button = node.closest('button');
          if (!button) return null;
          const claimed = button.dataset.e05Install === '1';
          const disabled =
            button.hasAttribute('disabled') || button.hasAttribute('aria-disabled');
          if (!claimed && !disabled) return null;
          const text = (node.textContent || '').trim();
          if (text.indexOf('Chrome') < 0 && text.indexOf('E05') < 0) return null;
          return button;
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
            const button = installButton(node);
            // Skip the promo banner (matched by SELECTOR but never
            // disabled) and anything else, so the brand swap can't
            // mangle "install Chrome" into "install E05".
            if (!button) continue;
            // Claim the button so the next pass still recognises it
            // after the disabled attribute is stripped below.
            button.dataset.e05Install = '1';
            const text = (node.textContent || '').trim();
            // The brand swap is locale-independent (CWS leaves "Chrome"
            // literal in every locale); the add/remove direction flip
            // is English + Japanese only, so other locales keep CWS's
            // own verb while the brand still rebrands.
            let next = text.replace('Chrome', 'E05');
            next = installed ? flipToRemove(next) : flipToAdd(next);
            if (text !== next) node.textContent = next;
            // CWS disables the install button when it can't identify
            // the host as a Chromium-derived browser. Strip the signal
            // so the capture-phase click handler below can intercept
            // the press and route it into e05's install pipeline. The
            // visual gating (opacity / pointer-events) is a build-keyed
            // CSS class on top of the `disabled` attribute; overriding
            // the inline style overrides the class for free.
            button.removeAttribute('disabled');
            button.removeAttribute('aria-disabled');
            button.style.opacity = '1';
            button.style.pointerEvents = 'auto';
            button.style.cursor = 'pointer';
          }
        }

        // Intercept clicks only on the install button (claimed by the
        // rewrite, or still disabled before the first pass). The promo
        // banner shares SELECTOR and carries a valid extension ID from
        // the listing URL, but is never disabled/claimed, so its
        // "install Chrome" press falls through to CWS instead of being
        // mistaken for an extension install.
        document.addEventListener('click', (event) => {
          const node = event.target.closest(SELECTOR) || event.target.closest('button');
          if (!node) return;
          const button = installButton(node);
          if (!button) return;
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
