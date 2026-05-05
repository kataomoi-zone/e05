import AppKit
import WebKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "Extensions")

/// Owns the single shared `WKWebExtensionController` used by every browser
/// pane. The controller must be attached to a `WKWebViewConfiguration`
/// before the `WKWebView` is initialized, so `BrowserPaneView` pulls
/// `shared.controller` from this singleton when it constructs its config.
///
/// Extensions live on disk as unpacked directories or ZIP archives under
/// `~/.config/e05/extensions/`. Each immediate child is interpreted as one
/// extension's resource base URL. The root directory is created lazily at
/// first scan; the user is responsible for placing extensions there.
@MainActor
public final class ExtensionController {
  public static let shared = ExtensionController()

  public let controller: WKWebExtensionController

  private let delegateProxy: DelegateProxy

  /// Activated extensions, ordered by load completion. The sidebar
  /// extensions list reads from this array to render the per-extension
  /// row; cells should treat the snapshot as opaque and re-fetch via
  /// `loadedExtensions` after every `didChangeNotification`.
  public private(set) var loadedExtensions: [LoadedExtension] = []

  /// Posted on the main queue whenever `loadedExtensions` is mutated
  /// (a successful load, an enable/disable toggle, or a future
  /// removal). Listener views subscribe via
  /// `NotificationCenter.addObserver(forName:...)` and re-fetch the
  /// snapshot from the controller on each fire — mirrors the
  /// `FaviconCache.didChangeNotification` pattern.
  public static let didChangeNotification = Notification.Name(
    "com.kawarimidoll.e05.ExtensionController.didChange"
  )

  /// Per-extension `WKWebExtensionContext` cache keyed by source-URL
  /// filename. Built once during `load(at:)` so a toggle from the
  /// sidebar can call `controller.load` / `controller.unload` without
  /// re-reading the manifest. The keys mirror `disabledFilenames` so
  /// the JSON state file stays portable across machines (the parent
  /// directory of `~/.config/e05/extensions/` is the user-controlled
  /// part; only the directory or ZIP basename is persisted).
  private var contextsByFilename: [String: WKWebExtensionContext] = [:]

  /// Set of source-URL filenames the user has explicitly disabled.
  /// Persisted as JSON at `extensionsStateFileURL`. Never includes
  /// filenames that aren't currently present on disk — the launch-time
  /// scan only writes back known entries, so a user pruning the
  /// extensions directory by hand doesn't accumulate stale entries.
  private var disabledFilenames: Set<String> = []

  /// Filenames the user has pinned to the URL-bar action row. New
  /// extensions default to unpinned (Chrome convention), so installing
  /// one drops it into the puzzle popover instead of cluttering the
  /// URL bar without consent. Persisted alongside `disabledFilenames`
  /// in `extensions-state.json`; pruned the same way at scan time.
  private var pinnedFilenames: Set<String> = []

  /// External `.appex` paths the user added through `From App Bundle…`.
  /// Persisted as JSON at `appBundlesStateFileURL` so the bundle
  /// auto-reloads on next launch. Pruned at scan time when the
  /// referenced bundle has disappeared from disk (the user trashed
  /// the host app, the path moved, etc.) so the file mirrors what's
  /// actually loadable.
  private var persistedAppBundlePaths: [URL] = []

  /// One Task per active context, watching the context's
  /// `errorsDidUpdateNotification` stream. Tracked here so a toggle
  /// can cancel the old subscription before installing a new one — an
  /// untracked spawn would leave the previous Task running after
  /// `controller.unload` and a re-enable would stack a second Task on
  /// the same context, doubling every error log entry.
  private var errorsTasksByFilename: [String: Task<Void, Never>] = [:]

  /// View + rect captured by the most recent `performAction` call so
  /// the controller's delegate can anchor `WKWebExtensionAction.popupPopover`
  /// against the URL-bar button the user just clicked. WebKit can
  /// dispatch `presentActionPopup` asynchronously after
  /// `performAction(for:)` returns (loading the popup web view runs
  /// off-thread), so the capture lives until the next click overwrites
  /// it rather than being cleared at the end of `performAction`.
  weak var pendingPopupAnchorView: NSView?
  var pendingPopupAnchorRect: NSRect = .zero

  /// Single host-window bridge. Held strongly so the controller's
  /// delegate can hand back the same instance from
  /// `openWindowsFor` / `focusedWindowFor` on every query — the
  /// `WKWebExtensionContext.openTabs` set is keyed off `NSObject`
  /// identity, so a fresh wrapper per call would invalidate
  /// extension-side per-tab state.
  let workspaceBridge = WorkspaceExtensionBridge()

  /// Cache of per-pane bridge wrappers keyed by `PaneModel.id`.
  /// Built lazily by `bridge(for:)` and pruned by `notifyTabClosed`
  /// so every `tabs(for:)` walk hands out the same instance for the
  /// same pane.
  private var tabBridgesByPaneID: [ULID: PaneExtensionBridge] = [:]

  private init() {
    // Mutate the default extension webViewConfiguration in place so
    // popup / background web views inherit WebKit's
    // `webkit-extension://` scheme handler, process pool, content
    // controller, and any other internal wiring instead of getting a
    // bare new config. Replacing the configuration outright with a
    // fresh `WKWebViewConfiguration()` breaks popup loading for
    // non-bundle extensions (popup never commits navigation,
    // `isLoading` stays true forever).
    //
    // applicationNameForUserAgent appends to the WebKit base UA, so
    // the final string ends with `Version/17.0 Chrome/120.0.0.0
    // Safari/605.1.15`. Both tokens are needed:
    // - `Version/…` + `Safari/…` keeps the Bitwarden Angular DI
    //   bootstrap happy (its api service constructor expects a
    //   non-null Safari device type when the bundle is the Mac App
    //   Store SafariWebExtension).
    // - `Chrome/…` short-circuits Bitwarden's `isBrowserSafariApi`
    //   (which requires Safari **without** Chrome to flip true), so
    //   the extension routes biometrics through the Chrome native
    //   messaging path that desktop_proxy actually serves instead of
    //   the Safari App-Group/XPC path that only the real Mac App
    //   Store extension can reach.
    let extConfig = WKWebExtensionController.Configuration.default()
    extConfig.webViewConfiguration.applicationNameForUserAgent =
      "Version/17.0 Chrome/120.0.0.0 Safari/605.1.15"

    // Forward popup / background / content script console output to
    // NSLog so a popup webView that hangs after some user input
    // (Bitwarden's 1-time code submit, OAuth handoff, etc.) surfaces
    // its JS errors and request failures in the same stderr stream
    // as the rest of the bridge — Web Inspector on a popover-hosted
    // web view is fragile to attach to in practice.
    let userContent = extConfig.webViewConfiguration.userContentController
    let relayHandler = ConsoleRelayHandler()
    userContent.addUserScript(
      WKUserScript(
        source: Self.consoleRelayScript,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
      )
    )
    userContent.add(relayHandler, name: "e05ConsoleRelay")
    self.consoleRelayHandler = relayHandler

    // Polyfill MV3-only chrome.* surfaces that WebKit's WKWebExtension
    // does not implement. 1Password's bg invokes
    // `chrome.offscreen.createDocument(...)` and
    // `chrome.declarativeNetRequest.updateDynamicRules(...)` during
    // startup; without stubs each call throws TypeError on undefined,
    // the surrounding Promise rejects, and popup initialization stalls
    // (visible as the "Could not parse restore point JSON. Rejecting."
    // log followed by a perpetual loading spinner). Stubs return
    // empty / no-op responses so callers see "feature unsupported"
    // rather than a parse error and keep walking the init chain.
    //
    // Set E05_DISABLE_CHROME_POLYFILL=1 in the environment to skip
    // the injection — useful while bisecting polyfill regressions to
    // see whether the polyfill itself is at fault for some breakage.
    if ProcessInfo.processInfo.environment["E05_DISABLE_CHROME_POLYFILL"] == "1" {
      NSLog("[e05/ext] chrome MV3 polyfill DISABLED (E05_DISABLE_CHROME_POLYFILL=1)")
    } else {
      // Per-section disable: E05_DISABLE_POLYFILL=offscreen,notifications,...
      // Lets us bisect a regression to a single polyfill chunk
      // without flipping the whole shim off.
      let disabledRaw = ProcessInfo.processInfo.environment["E05_DISABLE_POLYFILL"] ?? ""
      let disabledNames = disabledRaw.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      let disabledJSON =
        (try? String(
          data: JSONSerialization.data(withJSONObject: disabledNames), encoding: .utf8
        )) ?? "[]"
      if !disabledNames.isEmpty {
        NSLog(
          "[e05/ext] chrome MV3 polyfill sections disabled: %@",
          disabledNames.joined(separator: ",")
        )
      }
      let prelude =
        "window.__e05PolyfillDisabled = new Set(\(disabledJSON));\n"
      userContent.addUserScript(
        WKUserScript(
          source: prelude + Self.chromeMV3PolyfillScript,
          injectionTime: .atDocumentStart,
          forMainFrameOnly: false
        )
      )
    }

    self.controller = WKWebExtensionController(configuration: extConfig)
    let proxy = DelegateProxy()
    self.delegateProxy = proxy
    self.controller.delegate = proxy
    proxy.controller = self
  }

  /// Retain the message handler explicitly — `WKUserContentController.add`
  /// keeps a reference too, but holding our own makes the lifetime
  /// obvious from the controller's surface.
  private let consoleRelayHandler: ConsoleRelayHandler

  /// JS shim injected into every extension web view. Replaces the
  /// console methods with passthroughs that also `postMessage` to a
  /// native handler, plus catches uncaught errors and unhandled
  /// rejections so popup hangs caused by silent failures stop being
  /// invisible.
  private static let consoleRelayScript = """
    (function() {
      if (window.__e05ConsoleRelayInstalled) return;
      window.__e05ConsoleRelayInstalled = true;
      const channel = window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.e05ConsoleRelay;
      if (!channel) return;
      const orig = {
        log: console.log, info: console.info,
        warn: console.warn, error: console.error,
      };
      function relay(level, args) {
        try {
          const text = Array.from(args).map(a => {
            if (a instanceof Error) return a.stack || (a.name + ': ' + a.message);
            if (typeof a === 'string') return a;
            try { return JSON.stringify(a); } catch (_) { return String(a); }
          }).join(' ');
          const trimmed = text.length > 1000 ? text.slice(0, 1000) + '…' : text;
          channel.postMessage({ level: level, text: trimmed, url: location.href });
        } catch (_) {}
      }
      console.log = function() { relay('log', arguments); orig.log.apply(console, arguments); };
      console.info = function() { relay('info', arguments); orig.info.apply(console, arguments); };
      console.warn = function() { relay('warn', arguments); orig.warn.apply(console, arguments); };
      console.error = function() { relay('error', arguments); orig.error.apply(console, arguments); };
      window.addEventListener('error', function(e) {
        relay('uncaught', [(e.message || '(no message)'),
          (e.filename || '?') + ':' + (e.lineno || '?')]);
      });
      window.addEventListener('unhandledrejection', function(e) {
        const reason = e.reason;
        let detail;
        if (reason instanceof Error) {
          // Always emit name + message; append stack when available.
          // The earlier "stack || name+message" branch dropped the
          // message whenever the runtime produced a stack, leaving
          // only opaque minified frames like `JSe@…/bg.js:110:N`.
          detail = (reason.name || 'Error') + ': ' + (reason.message || '(no message)');
          if (reason.stack) detail += '\\n' + reason.stack;
        } else if (reason && typeof reason === 'object') {
          try { detail = JSON.stringify(reason); } catch (_) { detail = String(reason); }
        } else {
          detail = String(reason);
        }
        relay('unhandled-rejection', [detail]);
      });
    })();
    """

  /// Stubs for MV3-only `chrome.*` APIs that WKWebExtension does not
  /// implement. Inlined into every extension web view so popup, bg
  /// event-page, and content scripts that touch these surfaces see
  /// the same shape Chrome would expose. Stubs report "no resources"
  /// rather than synthesising fake state — extensions that gate on
  /// `chrome.X.has(...)` get a clean `false`, extensions that gate on
  /// `chrome.X !== undefined` proceed and find their callbacks become
  /// no-ops. Logs each install so a missing stub stands out in
  /// `/tmp/e05.log`.
  private static let chromeMV3PolyfillScript = """
    (function() {
      if (window.__e05ChromeMV3PolyfillInstalled) return;
      window.__e05ChromeMV3PolyfillInstalled = true;
      if (typeof chrome === 'undefined') return;
      function stubEvent() {
        return {
          addListener: function() {},
          removeListener: function() {},
          hasListener: function() { return false; },
          hasListeners: function() { return false; },
        };
      }
      function disabled(name) {
        return window.__e05PolyfillDisabled
          && window.__e05PolyfillDisabled.has(name);
      }
      var isPopupContext = (location.protocol === 'webkit-extension:')
        && (location.pathname.indexOf('/popup') !== -1
            || /\\bpopup[._-]?(html|index)/i.test(location.pathname));
      if (!disabled('offscreen') && !chrome.offscreen) {
        chrome.offscreen = {
          Reason: {
            AUDIO_PLAYBACK: 'AUDIO_PLAYBACK', IFRAME_SCRIPTING: 'IFRAME_SCRIPTING',
            DOM_SCRAPING: 'DOM_SCRAPING', BLOBS: 'BLOBS', DOM_PARSER: 'DOM_PARSER',
            USER_MEDIA: 'USER_MEDIA', DISPLAY_MEDIA: 'DISPLAY_MEDIA',
            WEB_RTC: 'WEB_RTC', CLIPBOARD: 'CLIPBOARD',
            LOCAL_STORAGE: 'LOCAL_STORAGE', WORKERS: 'WORKERS',
            BATTERY_STATUS: 'BATTERY_STATUS', MATCH_MEDIA: 'MATCH_MEDIA',
            GEOLOCATION: 'GEOLOCATION',
          },
          DocumentLifecycle: { ACTIVE: 'active', PRERENDER: 'prerender' },
          createDocument: function() { return Promise.resolve(); },
          closeDocument: function() { return Promise.resolve(); },
          hasDocument: function() { return Promise.resolve(false); },
        };
        console.log('[e05/polyfill] chrome.offscreen stubbed at', location.href);
      }
      // chrome.scripting.ExecutionWorld: read-only enum.
      // Additive-only when chrome.scripting exists. Earlier revision
      // also synthesized the entire chrome.scripting object when
      // missing, but that broke Bitwarden Cmd+Shift+L autofill —
      // when bg has the real scripting API, our stub object replaced
      // it in some context relay path, killing executeScript-based
      // injection. Keep the stub strictly additive.
      if (!disabled('scripting') && chrome.scripting && !chrome.scripting.ExecutionWorld) {
        chrome.scripting.ExecutionWorld = {
          ISOLATED: 'ISOLATED',
          MAIN: 'MAIN',
        };
        console.log('[e05/polyfill] chrome.scripting.ExecutionWorld stubbed at', location.href);
      }
      // chrome.webNavigation.onCreatedNavigationTarget: present in
      // Chrome but absent from WebKit. Same `.appex`-bypass-rewriter
      // story as ExecutionWorld; inject here so 1Password's bg
      // listener attach (line 110:369317 in 8.12.12) doesn't throw.
      // stubEvent() returns a fresh object whose addListener is a
      // no-op — WebKit doesn't track this event in any internal
      // routing path, so synthesizing it is safe.
      if (!disabled('webNavigation') && chrome.webNavigation
          && !chrome.webNavigation.onCreatedNavigationTarget) {
        chrome.webNavigation.onCreatedNavigationTarget = stubEvent();
        console.log('[e05/polyfill] chrome.webNavigation.onCreatedNavigationTarget stubbed at', location.href);
      }
      if (!disabled('declarativeNetRequest') && !chrome.declarativeNetRequest) {
        chrome.declarativeNetRequest = {
          MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 5000,
          MAX_NUMBER_OF_REGEX_RULES: 1000,
          DYNAMIC_RULESET_ID: '_dynamic',
          SESSION_RULESET_ID: '_session',
          updateDynamicRules: function() { return Promise.resolve(); },
          getDynamicRules: function() { return Promise.resolve([]); },
          updateSessionRules: function() { return Promise.resolve(); },
          getSessionRules: function() { return Promise.resolve([]); },
          updateEnabledRulesets: function() { return Promise.resolve(); },
          getEnabledRulesets: function() { return Promise.resolve([]); },
          updateStaticRules: function() { return Promise.resolve(); },
          getDisabledRuleIds: function() { return Promise.resolve([]); },
          getMatchedRules: function() { return Promise.resolve({ rulesMatchedInfo: [] }); },
          isRegexSupported: function() { return Promise.resolve({ isSupported: true }); },
          setExtensionActionOptions: function() { return Promise.resolve(); },
          getAvailableStaticRuleCount: function() { return Promise.resolve(0); },
          testMatchOutcome: function() { return Promise.resolve({ matchedRules: [] }); },
          onRuleMatchedDebug: stubEvent(),
        };
        console.log('[e05/polyfill] chrome.declarativeNetRequest stubbed at', location.href);
      }
      if (!disabled('webRequest') && chrome.webRequest && !chrome.webRequest.onAuthRequired) {
        chrome.webRequest.onAuthRequired = stubEvent();
        console.log('[e05/polyfill] chrome.webRequest.onAuthRequired stubbed at', location.href);
      }
      // chrome.notifications polyfill is intentionally NOT here.
      // Mutating chrome.notifications from a controller-level
      // WKUserScript wedges the popup web view's popover render
      // path even when guarded with a popup-context check (WebKit
      // appears to set up the popup web view's `chrome.notifications`
      // by mirroring whatever shape exists in the bg/extension
      // context at popup-show time). The bg-only shim that ships
      // inside the synthesized `_e05_bg.html` is the only safe
      // place to install it — see ManifestRewriter for the inline
      // script that polyfills `chrome.notifications` strictly inside
      // the bg event-page document.
      // chrome.runtime: getContexts / onUserScriptMessage are MV3
      // additions WebKit may not expose. Stub so guards on optional
      // features pass; existing runtime methods are untouched.
      if (!disabled('runtime') && chrome.runtime) {
        if (!chrome.runtime.getContexts) {
          chrome.runtime.getContexts = function() { return Promise.resolve([]); };
          console.log('[e05/polyfill] chrome.runtime.getContexts stubbed at', location.href);
        }
        if (!chrome.runtime.onUserScriptMessage) {
          chrome.runtime.onUserScriptMessage = stubEvent();
        }
        if (!chrome.runtime.onUserScriptConnect) {
          chrome.runtime.onUserScriptConnect = stubEvent();
        }
      }
      // chrome.action / chrome.browserAction: do not touch. Earlier
      // attempts to patch onClicked (full replace OR addListener-only)
      // and setPopup all suppressed the toolbar click entirely on
      // WebKit. Whatever interplay WebKit has between its proxy and
      // the click dispatch path is too fragile to mutate from JS.
      // Tradeoff: extensions that attach an `action.onClicked`
      // listener AND have a default_popup will see WebKit prefer the
      // listener, leaving the popup unreachable from the toolbar
      // (Chrome's spec is the opposite). Document as a known
      // limitation; affected extensions can use a non-toolbar
      // shortcut or wait on Apple's resolution.
      // chrome.userScripts is MV3-only; some bg code calls
      // configureWorld / register without checking. No-op shape so
      // listeners can attach without throwing.
      if (!disabled('userScripts') && !chrome.userScripts) {
        chrome.userScripts = {
          register: function() { return Promise.resolve(); },
          unregister: function() { return Promise.resolve(); },
          getScripts: function() { return Promise.resolve([]); },
          configureWorld: function() { return Promise.resolve(); },
          resetWorldConfiguration: function() { return Promise.resolve(); },
          getWorldConfigurations: function() { return Promise.resolve([]); },
        };
        console.log('[e05/polyfill] chrome.userScripts stubbed at', location.href);
      }
      // chrome.sidePanel is MV3-only and 1Password references it
      // optionally; stub so guards on `typeof chrome.sidePanel` work.
      if (!disabled('sidePanel') && !chrome.sidePanel) {
        chrome.sidePanel = {
          setOptions: function() { return Promise.resolve(); },
          getOptions: function() { return Promise.resolve({}); },
          setPanelBehavior: function() { return Promise.resolve(); },
          getPanelBehavior: function() { return Promise.resolve({}); },
          open: function() { return Promise.resolve(); },
        };
        console.log('[e05/polyfill] chrome.sidePanel stubbed at', location.href);
      }
      // chrome.permissions: WebKit's contains() rejects any permission
      // name it doesn't recognise (e.g. `privacy`, `sidePanel`,
      // `offscreen`) with `Invalid call to permissions.contains().
      // The 'permissions' value is invalid, because '<name>' is not a
      // valid permission`. Bitwarden's "Make Bitwarden the default
      // password manager" flow calls
      // `chrome.permissions.contains({permissions: ['privacy']})` to
      // gate the autofill switch and aborts the entire setting save
      // when the call rejects. Wrap contains() / request() to filter
      // unknown names down to the WebKit-accepted set so the call
      // succeeds (returning false for the unknown ones, which is
      // strictly accurate — we don't actually have those permissions).
      if (!disabled('permissions') && chrome.permissions) {
        var KNOWN_PERMS = new Set([
          'activeTab', 'alarms', 'background', 'bookmarks', 'browsingData',
          'clipboardRead', 'clipboardWrite', 'contentSettings', 'contextMenus',
          'cookies', 'declarativeNetRequest', 'declarativeNetRequestFeedback',
          'declarativeNetRequestWithHostAccess', 'downloads', 'history',
          'idle', 'management', 'menus', 'menus.overrideContext',
          'nativeMessaging', 'notifications', 'pageCapture', 'proxy',
          'scripting', 'search', 'storage', 'tabs', 'tabHide', 'theme',
          'topSites', 'unlimitedStorage', 'webNavigation', 'webRequest',
          'webRequestBlocking', 'webRequestAuthProvider',
        ]);
        function partitionPermissions(details) {
          if (!details || !Array.isArray(details.permissions)) return details;
          var keep = [];
          var dropped = [];
          for (var i = 0; i < details.permissions.length; i++) {
            var p = details.permissions[i];
            if (KNOWN_PERMS.has(p)) keep.push(p);
            else dropped.push(p);
          }
          if (dropped.length) {
            console.log('[e05/polyfill] permissions: filtering out unknown', dropped, 'at', location.href);
          }
          var copy = {};
          for (var k in details) copy[k] = details[k];
          copy.permissions = keep;
          return copy;
        }
        if (typeof chrome.permissions.contains === 'function') {
          var origContains = chrome.permissions.contains.bind(chrome.permissions);
          chrome.permissions.contains = function(details, cb) {
            try {
              var hadUnknown = details && Array.isArray(details.permissions)
                && details.permissions.some(function(p) { return !KNOWN_PERMS.has(p); });
              var filtered = partitionPermissions(details);
              if (hadUnknown && (!filtered.permissions || filtered.permissions.length === 0)) {
                // Caller asked only for permissions WebKit doesn't
                // know — answer "false" honestly without going into
                // WebKit (which would throw).
                if (typeof cb === 'function') cb(false);
                return Promise.resolve(false);
              }
              return origContains(filtered, cb);
            } catch (e) {
              console.warn('[e05/polyfill] permissions.contains wrap failed:', e);
              if (typeof cb === 'function') cb(false);
              return Promise.resolve(false);
            }
          };
        }
        if (typeof chrome.permissions.request === 'function') {
          var origRequest = chrome.permissions.request.bind(chrome.permissions);
          chrome.permissions.request = function(details, cb) {
            try {
              var filtered = partitionPermissions(details);
              if (!filtered.permissions || filtered.permissions.length === 0) {
                if (typeof cb === 'function') cb(true);
                return Promise.resolve(true);
              }
              return origRequest(filtered, cb);
            } catch (e) {
              console.warn('[e05/polyfill] permissions.request wrap failed:', e);
              if (typeof cb === 'function') cb(false);
              return Promise.resolve(false);
            }
          };
        }
        console.log('[e05/polyfill] chrome.permissions wrapped at', location.href);
      }
      // R4-2 diagnostic: log every `window.message` event that
      // reaches Bitwarden's inline-menu wrapper iframe
      // (overlay/menu.html). The bg → page-side wrapper
      // `port.postMessage(initAutofillInlineMenuButton, …)` step is
      // confirmed working (see `bg→port[autofill-inline-menu-…]`
      // logs in bg-shim), and the wrapper iframe loads, but the
      // sub-iframe (menu-button.html / menu-list.html) never gets
      // its `src` set. Bitwarden's `handleWindowMessage` rejects
      // init messages unless `event.origin === extensionOrigin` OR
      // `event.source === globalThis.parent`. WebKit's content_script
      // isolated worlds may break the parent-window identity check
      // and the page→iframe origin ladder, so log what actually
      // arrives so we can decide what guard to relax.
      if (location.pathname.indexOf('/overlay/menu.html') !== -1) {
        try {
          globalThis.addEventListener('message', function(e) {
            try {
              var d = e.data;
              var summary = {
                cmd: (d && typeof d === 'object' && d.command) || '(no-command)',
                origin: e.origin,
                hasPortKey: !!(d && typeof d === 'object' && d.portKey),
                sourceIsParent: e.source === globalThis.parent,
                sourceIsSelf: e.source === globalThis,
                parentOrigin: (function() {
                  try { return globalThis.parent.location.origin; }
                  catch (_) { return '(cross-origin-blocked)'; }
                })(),
              };
              console.log('[e05/diag] menu.html msg ' + JSON.stringify(summary));
            } catch (_) {}
          }, true);
          console.log('[e05/diag] menu.html message observer installed (extensionOrigin='
            + (chrome.runtime.getURL ? chrome.runtime.getURL('').slice(0, -1) : '?') + ')');
        } catch (e) {
          console.warn('[e05/diag] menu.html observer failed:', e);
        }
      }
    })();
    """

  /// Wire the bridge to its pane container. AppDelegate calls this
  /// once after building the container so the workspace bridge
  /// resolves real panes by the time `loadAll()` seeds
  /// `WKWebExtensionContext.openTabs` from
  /// `openWindowsFor → tabs(for:)`. Calling before `loadAll` runs
  /// is required: the open-tabs seed happens once at extension load
  /// time, and a missed binding leaves every loaded extension with
  /// an empty `chrome.tabs` view that never recovers.
  public func bindContainer(_ container: PaneContainerViewController) {
    workspaceBridge.container = container
    logger.info("Bound PaneContainer to extension workspace bridge")
  }

  /// Tear down every live native messaging host so quit doesn't
  /// leave orphan `desktop_proxy` processes hanging on to user
  /// sockets. `shutdown` is idempotent and walks `onClosed` to
  /// remove itself from the dict, so we snapshot the values first
  /// and iterate the copy.
  public func shutdownAllNativePorts() {
    let ports = Array(delegateProxy.nativePorts.values)
    if ports.isEmpty { return }
    NSLog("[e05/ext] shutting down %d native port(s) at app teardown", ports.count)
    for port in ports {
      port.shutdown(reason: "app terminating")
    }
  }

  /// Resolve the bridge for `pane`, creating + caching it on first
  /// access. Returns the same instance for repeat queries so the
  /// controller's identity-based set tracking holds across popup
  /// opens, focus changes, and `tabs(for:)` walks.
  func bridge(for pane: PaneModel) -> PaneExtensionBridge {
    if let cached = tabBridgesByPaneID[pane.id] { return cached }
    let bridge = PaneExtensionBridge(pane: pane, container: workspaceBridge.container)
    tabBridgesByPaneID[pane.id] = bridge
    return bridge
  }

  // MARK: - Tab lifecycle notifications
  //
  // Extensions only see `chrome.tabs.*` events when these helpers
  // fire — the controller's `openTabs` set is seeded once at
  // extension load and otherwise relies on the host telling it
  // every state change. Skipping any of these leaves a popup
  // listening on `tabs.onUpdated` (Bitwarden waits on this to
  // detect navigation finish before offering autofill) hanging
  // indefinitely.
  //
  // Each helper guards on `address.kind == .browser` so terminal /
  // finder pane mutations don't synthesise phantom tabs.

  /// Offer `event` to every loaded extension's command dispatcher.
  /// Returns true if any context handled the event (the caller should
  /// then suppress further routing, e.g. by returning `nil` from an
  /// NSEvent local monitor). Mirrors the WKWebExtensionContext docs:
  /// "The app should use this method to perform any extension commands
  /// at an appropriate time in the app's event handling, like in
  /// `sendEvent:` of NSApplication or NSWindow subclasses." We hook a
  /// local monitor instead of subclassing NSApp so the rest of e05 can
  /// keep using the stock NSApplication.
  ///
  /// Walking every loaded context is acceptable because typical install
  /// counts are < 10 and `performCommand(for:)` early-exits on contexts
  /// that don't bind the keystroke. Skips disabled contexts so a
  /// quiesced extension's keymap stays inert.
  public func performExtensionCommand(for event: NSEvent) -> Bool {
    for entry in loadedExtensions where entry.isEnabled {
      guard let ctx = contextsByFilename[entry.sourceURL.lastPathComponent] else { continue }
      if ctx.performCommand(for: event) {
        NSLog(
          "[e05/ext] performCommand consumed event by '%@'",
          entry.displayName
        )
        return true
      }
    }
    return false
  }

  /// Locate the on-disk extension directory backing `context`.
  /// `contextsByFilename` is the only mapping we own; reverse-lookup
  /// by identity to find the install path under `extensionsRoot`.
  /// Used by the native-messaging delegate to read the rewriter's
  /// pre-computed `_e05_caller_origin` when handing the host an
  /// authentic chrome-extension origin URL.
  func extensionDirectory(for context: WKWebExtensionContext) -> URL? {
    for (filename, ctx) in contextsByFilename where ctx === context {
      return Self.extensionsRoot.appendingPathComponent(filename)
    }
    return nil
  }

  /// Tell every loaded extension that a new browser pane has come
  /// into existence. Callers MUST insert the pane into its column
  /// model BEFORE invoking this — WebKit may sync-call
  /// `tabs(for:)` from inside `didOpenTab` to validate the new
  /// tab's window membership, and a not-yet-inserted pane fails
  /// that validation silently.
  ///
  /// Private workspaces are skipped: `WorkspaceExtensionBridge.tabs(for:)`
  /// already filters them out of the enumerated tab set, so emitting
  /// `didOpenTab` for a pane that won't appear in the next walk would
  /// leave extensions with a phantom-tab identity.
  public func notifyTabOpened(_ pane: PaneModel) {
    guard pane.address.kind == .browser, !isPanePrivate(pane) else { return }
    let tab = bridge(for: pane)
    controller.didOpenTab(tab)
  }

  /// Tell every loaded extension that a browser pane has been
  /// closed (or moved to the undo-stash). Drops the cached bridge
  /// so a later undo / restore lands a fresh tab identity rather
  /// than reusing the now-detached one.
  ///
  /// Private panes never fired `didOpenTab`, so a `didCloseTab` here
  /// would also be phantom; the bridge cache is still cleared so a
  /// future cross-private-boundary reattach (currently blocked, but
  /// belt-and-braces) can't reuse a dangling identity.
  public func notifyTabClosed(_ pane: PaneModel) {
    guard pane.address.kind == .browser else { return }
    guard let bridge = tabBridgesByPaneID.removeValue(forKey: pane.id) else { return }
    guard !isPanePrivate(pane) else { return }
    controller.didCloseTab(bridge, windowIsClosing: false)
  }

  /// Tell every loaded extension that the active tab has changed.
  /// `previous` is `nil` when there was no previously active
  /// browser pane (e.g. focus moved from a terminal pane to a
  /// browser pane). When `next` isn't a browser pane (focus moved
  /// off a browser pane onto a terminal / finder pane) the
  /// notification is suppressed — there's no sensible
  /// representation of "no active tab" mid-session, and extensions
  /// tolerate the active tab staying put across non-browser focus
  /// excursions.
  public func notifyTabActivated(next: PaneModel?, previous: PaneModel?) {
    guard let next, next.address.kind == .browser else { return }
    let nextBridge = bridge(for: next)
    let previousBridge: PaneExtensionBridge?
    if let previous, previous.address.kind == .browser, previous.id != next.id {
      previousBridge = tabBridgesByPaneID[previous.id]
    } else {
      previousBridge = nil
    }
    controller.didActivateTab(nextBridge, previousActiveTab: previousBridge)
  }

  /// Tell every loaded extension that one of `pane`'s observable
  /// properties has changed. The OptionSet maps directly to the
  /// `chrome.tabs.onUpdated` payload bits — `.url` for navigation,
  /// `.title` for the document title, `.loading` for the
  /// loading-state flip the URL bar reload-vs-stop button mirrors.
  public func notifyTabPropertiesChanged(
    _ pane: PaneModel, properties: WKWebExtension.TabChangedProperties
  ) {
    guard pane.address.kind == .browser, !isPanePrivate(pane) else { return }
    guard let bridge = tabBridgesByPaneID[pane.id] else { return }
    controller.didChangeTabProperties(properties, for: bridge)
  }

  /// Whether `pane` belongs to a private workspace. Resolved through
  /// the `workspaceBridge`'s container reference so the check stays
  /// in lockstep with the same source of truth `tabs(for:)` filters
  /// against. Returns `false` when the bridge isn't yet bound — the
  /// pane is "in flight" and the safe default is to suppress
  /// notifications until it lands somewhere with a known privacy
  /// scope.
  private func isPanePrivate(_ pane: PaneModel) -> Bool {
    workspaceBridge.container?.workspaceContaining(pane: pane)?.isPrivate ?? true
  }

  /// Root directory scanned at launch. Each immediate child (either an
  /// unpacked directory or a ZIP archive) is treated as an extension.
  public static var extensionsRoot: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/e05/extensions", isDirectory: true)
  }

  /// Persistent enable/disable state for installed extensions. Stored
  /// alongside the extensions root rather than inside it so a user
  /// who copies an extension directory between machines doesn't drag
  /// the state with it (the file's location matches the convention of
  /// the other top-level stores under `~/.config/e05/`).
  private static var extensionsStateFileURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/e05/extensions-state.json", isDirectory: false)
  }

  /// Persisted list of external `.appex` paths the user added through
  /// `From App Bundle…`. Kept in a separate file from
  /// `extensions-state.json` because the lifecycle is different
  /// (entries can vanish when the host app is trashed; archive
  /// entries live and die with `extensionsRoot`).
  private static var appBundlesStateFileURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/e05/extensions-app-bundles.json", isDirectory: false)
  }

  /// On-disk shape of the state file. Kept as a dedicated nested
  /// `Codable` type so additions (e.g. per-extension permission
  /// overrides, last-update timestamps) can be appended later without
  /// breaking existing files — Codable synthesis tolerates unknown
  /// keys when decoding via the default initializer.
  private struct PersistedState: Codable {
    var disabledFilenames: [String] = []
    /// URL-bar pinning state. Codable's synthesized init treats this
    /// as the empty default when the file predates the field, so a
    /// state.json written before the URL-bar pinning feature shipped
    /// decodes to "all unpinned" without a migration step.
    var pinnedFilenames: [String] = []
  }

  /// On-disk shape of `appBundlesStateFileURL`. Stores absolute file
  /// system paths (resolved to the inner `.appex`, not the parent
  /// `.app`) so re-launch hits the same load target without
  /// re-running the picker logic.
  private struct PersistedAppBundles: Codable {
    var bundlePaths: [String] = []
  }

  /// Domain shared by every NSError thrown from this controller.
  /// `WKWebExtensionErrorDomain` covers WebKit's own load failures;
  /// our own validation errors (collision, missing source) live here.
  static let errorDomain = "com.kawarimidoll.e05.Extensions"

  /// Numeric code space for our NSErrors. Centralised so two callers
  /// can't reach for the same `code: 1` literal independently.
  /// `fileprivate` so the file's `DelegateProxy` can use the same
  /// codes when bridging WebKit delegate failures.
  fileprivate enum ErrorCode: Int {
    case alreadyInstalled = 1
    case notLoaded = 2
    case storeFetchFailed = 3
    case storeBadResponse = 4
    case bundleNoAppex = 5
    case bundleInvalid = 6
    case nativeHostNotFound = 12
    case nativeHostLaunchFailed = 13
  }

  /// Chrome version pinned for the Chrome Web Store update endpoint.
  /// The server uses this to decide which CRX format to return; any
  /// recent Chrome stable release works because we accept both crx2
  /// and crx3 in the same request. Bumping it is harmless when a new
  /// CRX format ships, but staying on a known-good value keeps the
  /// download path reproducible.
  private static let chromeStoreClientVersion = "120.0.6099.225"

  /// Hosts the Chrome Web Store CRX endpoint is allowed to redirect
  /// to. The endpoint itself lives on `clients2.google.com`; the
  /// actual blob is served from a `googleusercontent.com` subdomain
  /// chosen at request time (e.g. `r6.googleusercontent.com`). Any
  /// other host indicates either an open-redirect abuse or a DNS
  /// hijack and is rejected before bytes reach the loader.
  private static let chromeStoreAllowedHosts: Set<String> = [
    "clients2.google.com",
    "googleusercontent.com",
  ]

  /// Match `host` against an allowlist where each entry is either an
  /// exact host or a registrable suffix. Suffix matches require a
  /// `.` boundary so `evil-googleusercontent.com` does not slip past
  /// a `googleusercontent.com` entry. `nonisolated` because the
  /// redirect delegate runs on a `URLSession` queue, not the main
  /// actor.
  nonisolated fileprivate static func hostMatches(
    _ host: String, allowed: Set<String>
  ) -> Bool {
    if allowed.contains(host) { return true }
    return allowed.contains { suffix in host.hasSuffix(".\(suffix)") }
  }

  /// Scan `extensionsRoot` and load every child as an extension. Creates
  /// the root directory if missing to match the other persistence stores
  /// under `~/.config/e05/`; an empty directory simply produces no loads.
  public func loadAll() async {
    loadPersistedState()
    NSLog(
      "[e05/ext] loadAll start: disabledFilenames=[%@]",
      disabledFilenames.sorted().joined(separator: ",")
    )

    let root = Self.extensionsRoot
    let fm = FileManager.default

    do {
      try fm.createDirectory(at: root, withIntermediateDirectories: true)
    } catch {
      logger.error(
        """
        Failed to create extensions root at \
        \(root.path, privacy: .private(mask: .hash)): \
        \(String(describing: error), privacy: .public)
        """
      )
      return
    }

    let entries: [URL]
    do {
      entries = try fm.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      logger.error(
        "Failed to enumerate extensions root: \(String(describing: error), privacy: .public)"
      )
      return
    }

    for entry in entries {
      var entryIsDir: ObjCBool = false
      let exists = fm.fileExists(atPath: entry.path, isDirectory: &entryIsDir)
      guard exists else { continue }
      let isZip = entry.pathExtension.lowercased() == "zip"
      guard entryIsDir.boolValue || isZip else { continue }
      // Tolerate a single bad extension at scan time — log and move
      // on. `addExtension` uses the throwing form for direct user
      // feedback, but here a startup-time scan must not abort just
      // because one disk entry has a malformed manifest.
      do {
        try await load(at: entry)
      } catch {
        logger.error(
          """
          Failed to load extension at \
          \(entry.path, privacy: .private(mask: .hash)): \
          \(String(describing: error), privacy: .public)
          """
        )
      }
    }

    // Re-write the state file restricted to filenames currently on
    // disk so removed extensions stop accumulating in the disabled
    // / pinned sets. Unknown filenames still resolve to defaults
    // (enabled, unpinned) on the next launch, but trimming on every
    // scan keeps the file small and surfaces the live convention to
    // anyone hand-editing it.
    let presentFilenames = Set(contextsByFilename.keys)
    let staleDisabled = disabledFilenames.subtracting(presentFilenames)
    let stalePinned = pinnedFilenames.subtracting(presentFilenames)
    if !staleDisabled.isEmpty || !stalePinned.isEmpty {
      disabledFilenames.formIntersection(presentFilenames)
      pinnedFilenames.formIntersection(presentFilenames)
      savePersistedState()
    }

    await loadPersistedAppBundles()
  }

  /// Re-load every `.appex` the user previously added through
  /// `From App Bundle…`. Only bundles whose host app has been
  /// physically removed (Trashed, moved, renamed) are dropped —
  /// transient failures (codesign cache mismatch, alreadyInstalled
  /// from a duplicate launch path, etc.) keep their path in the
  /// list so the next launch can retry instead of silently losing
  /// the user's saved entry.
  private func loadPersistedAppBundles() async {
    loadPersistedAppBundlesState()
    let saved = persistedAppBundlePaths
    // Reset and rebuild from successful + retained paths. The user-
    // facing `installFromAppBundle` is bypassed in favour of the
    // internal core so startup re-install never touches the persist
    // step (we'll save the full reconciled list once at the end).
    persistedAppBundlePaths = []
    let fm = FileManager.default
    for bundleURL in saved {
      guard fm.fileExists(atPath: bundleURL.path) else {
        logger.info(
          """
          Pruning missing app-bundle reference \
          \(bundleURL.path, privacy: .public)
          """
        )
        continue
      }
      do {
        try await loadAppBundleInternal(at: bundleURL)
        persistedAppBundlePaths.append(bundleURL)
      } catch {
        // Path is on disk but the load throw'd. Could be a transient
        // failure (codesign re-validation racing the launch, an OS
        // upgrade-induced cache miss, alreadyInstalled if loadAll
        // ever runs twice) — keep the path so the next launch retries
        // instead of silently dropping the user's saved bundle.
        persistedAppBundlePaths.append(bundleURL)
        logger.error(
          """
          Failed to re-load persisted app bundle \
          \(bundleURL.lastPathComponent, privacy: .public): \
          \(String(describing: error), privacy: .public). \
          Path retained for next launch.
          """
        )
      }
    }
    // Persist the reconciled list once. Skipping the save keeps the
    // existing file untouched if `loadPersistedAppBundlesState`
    // detected and quarantined a corrupt original.
    saveAppBundlesState()
  }

  private func loadPersistedAppBundlesState() {
    let url = Self.appBundlesStateFileURL
    guard let data = try? Data(contentsOf: url) else { return }
    do {
      let decoded = try JSONDecoder().decode(PersistedAppBundles.self, from: data)
      persistedAppBundlePaths = decoded.bundlePaths.map(URL.init(fileURLWithPath:))
    } catch {
      // Move the bad file aside instead of overwriting it: if the
      // user (or a buggy editor) corrupted the JSON, we want a copy
      // they can recover from rather than silently turning it into
      // an empty array. The next save writes a fresh file at the
      // canonical path.
      let quarantineURL = url.appendingPathExtension("corrupt")
      logger.error(
        """
        Failed to decode extensions-app-bundles.json: \
        \(String(describing: error), privacy: .public). \
        Moving the original to \(quarantineURL.lastPathComponent, privacy: .public).
        """
      )
      try? FileManager.default.moveItem(at: url, to: quarantineURL)
    }
  }

  private func saveAppBundlesState() {
    let url = Self.appBundlesStateFileURL
    let payload = PersistedAppBundles(
      bundlePaths: persistedAppBundlePaths.map(\.path).sorted()
    )
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(payload)
      try data.write(to: url, options: [.atomic])
    } catch {
      logger.error(
        """
        Failed to write extensions-app-bundles.json at \
        \(url.path, privacy: .private(mask: .hash)): \
        \(String(describing: error), privacy: .public)
        """
      )
    }
  }

  private func load(at url: URL) async throws {
    // If `url` points at an unpacked tree, run the MV3→MV2 rewriter
    // so WKWebExtension can wake the bg via the event-page path
    // instead of the SW path it doesn't fully implement. ZIP archives
    // are unpacked in `installDownloadedExtension` before reaching
    // here; ZIPs that arrive via direct `addExtension(from:)` (e.g.
    // a user dragging a .zip in) skip the rewrite and run as-is —
    // not ideal, but degrading gracefully beats failing the install.
    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    if isDir {
      do {
        if try ManifestRewriter.mv3ToMV2(at: url) {
          NSLog("[e05/ext] MV3→MV2 rewrite applied at %@", url.lastPathComponent)
        }
      } catch {
        NSLog(
          "[e05/ext] manifest rewrite skipped for %@: %@",
          url.lastPathComponent, String(describing: error)
        )
      }
    }
    let ext = try await WKWebExtension(resourceBaseURL: url)
    try activate(ext: ext, sourceURL: url, sourceKind: .archive)
  }

  /// Build a `WKWebExtension` from a Safari Web Extension's `.appex`
  /// bundle and activate it through the standard pipeline. The
  /// bundle reference is held implicitly by the resulting context
  /// for as long as `WKWebExtensionController` keeps it loaded —
  /// we never copy the `.appex` into `extensionsRoot`, because
  /// copying would invalidate any code-signed Mac app's signature.
  private func loadFromBundle(_ bundle: Bundle, sourceURL: URL) async throws {
    let ext: WKWebExtension
    do {
      ext = try await WKWebExtension(appExtensionBundle: bundle)
    } catch {
      // Wrap WebKit's raw error in our own `bundleInvalid` so the
      // sidebar alert speaks the same language for `.app` / `.appex`
      // problems as the store paths do for HTTP failures, and so
      // the underlying WebKit text shows up in `localizedDescription`
      // without leaking domain implementation details to UI code.
      logger.error(
        """
        WKWebExtension(appExtensionBundle:) threw for \
        \(sourceURL.lastPathComponent, privacy: .public): \
        \(String(describing: error), privacy: .public)
        """
      )
      throw NSError(
        domain: Self.errorDomain,
        code: ErrorCode.bundleInvalid.rawValue,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Could not load '\(sourceURL.lastPathComponent)' as a Safari Web Extension: "
            + (error as NSError).localizedDescription
        ]
      )
    }
    try activate(ext: ext, sourceURL: sourceURL, sourceKind: .appBundle)
  }

  /// Shared activation tail used by both the directory/ZIP and
  /// `.appex` load paths. Builds the context, pre-grants permissions,
  /// honours the persisted disable flag, and appends a snapshot to
  /// `loadedExtensions`. Every call site has already produced the
  /// `WKWebExtension` instance — this helper handles the
  /// post-construction work that's identical across sources.
  private func activate(
    ext: WKWebExtension, sourceURL: URL, sourceKind: SourceKind
  ) throws {
    let name = ext.displayName ?? sourceURL.lastPathComponent
    let mv = String(format: "%g", ext.manifestVersion)

    logger.info(
      """
      Loaded manifest '\(name, privacy: .public)' \
      v\(ext.version ?? "(unknown)", privacy: .public) MV\(mv, privacy: .public) \
      from \(sourceURL.lastPathComponent, privacy: .public) \
      caps[bg=\(ext.hasBackgroundContent), \
      persistBg=\(ext.hasPersistentBackgroundContent), \
      inject=\(ext.hasInjectedContent), \
      cmr=\(ext.hasContentModificationRules), \
      opts=\(ext.hasOptionsPage), \
      cmds=\(ext.hasCommands)]
      """
    )

    // Surface any parse-time errors immediately. For MV3 extensions
    // that expect Chrome-specific APIs (offscreen, userScripts, ...),
    // the parser may report non-fatal warnings here.
    for (i, err) in ext.errors.enumerated() {
      let ns = err as NSError
      logger.error(
        """
        Parse err[\(i)] for '\(name, privacy: .public)': \
        domain=\(ns.domain, privacy: .public) code=\(ns.code) \
        desc=\(ns.localizedDescription, privacy: .public)
        """
      )
    }

    let ctx = WKWebExtensionContext(for: ext)

    // Stable identifier so chrome.storage / IndexedDB / cookies /
    // anything else WebKit keys per-context survives app restarts.
    // The default uniqueIdentifier is a fresh UUID every context
    // creation, which means each launch sees the extension as a
    // brand-new install: stored auth tokens vanish, vault encryption
    // keys can't be located, and password managers fall back to the
    // first-run flow. Using the source filename (e.g. the CRX
    // basename or `<host>.appex` lastPathComponent) keeps the
    // identifier deterministic across runs without leaking the path.
    ctx.uniqueIdentifier = "e05.\(sourceURL.lastPathComponent)"

    // Surface the extension's background page / service worker (and
    // every popup web view it ever opens) in Safari's Develop menu so
    // the bridge is debuggable end-to-end. Without `inspectable=true`
    // on the context, popup web views can be inspected (we set the
    // matching property on each popupWebView) but the background page
    // / SW stays invisible — the most important spot to look when the
    // chrome.* round-trip stalls. macOS 13.3+ is required.
    ctx.isInspectable = true
    ctx.inspectionName = "e05: \(name)"

    // Pre-grant every requested permission and host pattern so
    // content-blocking paths run end-to-end without surfacing a
    // prompt. Placing an extension under ~/.config/e05/extensions/
    // is treated as explicit user trust; a richer permission flow
    // ships with the extensions sidebar UI.
    //
    // `optionalPermissions` are pre-granted too. Bitwarden declares
    // `nativeMessaging` as optional, and its bg gates biometric
    // unlock on `chrome.permissions.contains({permissions:
    // ['nativeMessaging']})` returning true — without an explicit
    // grant the call resolves false (WebKit's default for optional
    // perms), the bg logs "Native messaging permission is missing
    // for biometrics", and the popup silently falls back to
    // password unlock instead of triggering the desktop biometric
    // prompt. Treating sideload as explicit trust covers optionals
    // as well; Chrome's policy of asking the user at first use
    // doesn't fit a developer-only browser.
    let permNames = ext.requestedPermissions.map(\.rawValue).sorted()
    for perm in ext.requestedPermissions {
      ctx.setPermissionStatus(.grantedExplicitly, for: perm)
    }
    let optionalPermNames = ext.optionalPermissions.map(\.rawValue).sorted()
    for perm in ext.optionalPermissions {
      ctx.setPermissionStatus(.grantedExplicitly, for: perm)
    }
    let patternStrings = ext.requestedPermissionMatchPatterns
      .map(\.string)
      .sorted()
    for pattern in ext.requestedPermissionMatchPatterns {
      ctx.setPermissionStatus(.grantedExplicitly, for: pattern)
    }
    logger.info(
      """
      Pre-granted \(permNames.count) perms \
      [\(permNames.joined(separator: ","), privacy: .public)] + \
      \(optionalPermNames.count) optional perms \
      [\(optionalPermNames.joined(separator: ","), privacy: .public)] + \
      \(patternStrings.count) host patterns \
      [\(patternStrings.joined(separator: ","), privacy: .public)] \
      for '\(name, privacy: .public)'
      """
    )

    let filename = sourceURL.lastPathComponent
    contextsByFilename[filename] = ctx
    let isEnabled = !disabledFilenames.contains(filename)
    NSLog(
      "[e05/ext] loadFromBundle '%@' filename=%@ isEnabled=%@",
      name, filename, isEnabled ? "true" : "false"
    )

    if isEnabled {
      try controller.load(ctx)

      let currentPermNames = ctx.currentPermissions.map(\.rawValue).sorted()
      logger.info(
        """
        Activated '\(name, privacy: .public)' \
        ctx[inject=\(ctx.hasInjectedContent), \
        cmr=\(ctx.hasContentModificationRules), \
        allURLs=\(ctx.hasAccessToAllURLs), \
        currentPerms=[\(currentPermNames.joined(separator: ","), privacy: .public)]]
        """
      )

      // Dump the error array immediately post-load — declarativeNetRequest
      // ruleset installation, background script boot, and any Chrome API
      // feature gaps will surface here within a few hundred milliseconds.
      Self.logErrors(ctx: ctx, source: "post-load")

      subscribeToErrors(ctx: ctx, name: name, key: filename)
      scheduleCapabilityRecheck(ctx: ctx, name: name)
      Self.eagerlyLoadBackgroundContent(ctx: ctx, name: name)
    } else {
      logger.info(
        "Skipping controller.load for user-disabled '\(name, privacy: .public)'"
      )
    }

    let entry = LoadedExtension(
      sourceURL: sourceURL,
      displayName: name,
      version: ext.version,
      manifestVersion: ext.manifestVersion,
      icon: Self.bestIcon(for: ext),
      isEnabled: isEnabled,
      isPinned: pinnedFilenames.contains(filename),
      sourceKind: sourceKind,
      hasOptionsPage: ext.hasOptionsPage
    )
    loadedExtensions.append(entry)
    // Stable display order across launches: filesystem enumeration
    // order is not guaranteed and async-load completion order would
    // shuffle the list further if loads ever run in parallel.
    loadedExtensions.sort {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  /// Re-log extension capability flags a few seconds after load. The
  /// initial activation log is captured microseconds after `controller.load`,
  /// which is too early for async declarativeNetRequest ruleset install or
  /// service-worker-driven dynamic content script registration to complete.
  /// When the deferred context state contradicts what the manifest
  /// advertises, a warning is emitted — this is the earliest surface for
  /// silent WebKit feature gaps (e.g. `scripting.registerContentScripts`
  /// calls that succeed on the JS side but never reach the loader).
  private func scheduleCapabilityRecheck(ctx: WKWebExtensionContext, name: String) {
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      let ext = ctx.webExtension
      NSLog(
        "[e05/ext] +3s recheck '%@' inject=%@ cmr=%@ allURLs=%@",
        name,
        ctx.hasInjectedContent ? "true" : "false",
        ctx.hasContentModificationRules ? "true" : "false",
        ctx.hasAccessToAllURLs ? "true" : "false"
      )
      if ext.hasInjectedContent, !ctx.hasInjectedContent {
        NSLog(
          "[e05/ext] WARNING '%@' advertises injected content but ctx inject=false after 3s",
          name
        )
      }
      if ext.hasContentModificationRules, !ctx.hasContentModificationRules {
        NSLog(
          "[e05/ext] WARNING '%@' advertises content modification rules but ctx cmr=false after 3s",
          name
        )
      }
      Self.logErrors(ctx: ctx, source: "+3s recheck")
    }
  }

  private func subscribeToErrors(ctx: WKWebExtensionContext, name: String, key: String) {
    // Cancel the previous subscription for this context before
    // installing a new one. Without this, an enable/disable cycle
    // would leak the original Task — the AsyncSequence keeps the
    // for-await alive for the lifetime of `ctx`, so it would never
    // self-terminate after `controller.unload`.
    errorsTasksByFilename[key]?.cancel()

    // AsyncSequence form keeps both producer and consumer inside the
    // MainActor isolation domain, sidestepping the Sendable barrier
    // that the block-based `addObserver(forName:object:queue:using:)`
    // trips in Swift 6 (the Notification argument is task-isolated and
    // cannot be handed to a MainActor closure safely).
    let task = Task { @MainActor in
      let stream = NotificationCenter.default.notifications(
        named: WKWebExtensionContext.errorsDidUpdateNotification,
        object: ctx
      )
      for await _ in stream {
        Self.logErrors(ctx: ctx, source: "errorsDidUpdate")
      }
    }
    errorsTasksByFilename[key] = task
    logger.debug("Subscribed to errorsDidUpdate for '\(name, privacy: .public)'")
  }

  /// Resolve the best display icon for an extension. Prefers a 32pt
  /// action icon (toolbar / popup affordance) and falls back to the
  /// manifest icon at the same size, so both action-bearing extensions
  /// (uBO Lite, Bitwarden) and content-only extensions (declarative
  /// rule packs) render with a meaningful glyph in the sidebar list.
  /// Returns nil when neither is available; the cell paints a generic
  /// `puzzlepiece.extension` placeholder in that case.
  private static func bestIcon(for ext: WKWebExtension) -> NSImage? {
    let target = NSSize(width: 32, height: 32)
    if let actionIcon = ext.actionIcon(for: target) {
      return actionIcon
    }
    return ext.icon(for: target)
  }

  /// Snapshot of the extension's runtime errors at this instant.
  /// Returns an empty array when the source isn't loaded. Calls
  /// through to `WKWebExtensionContext.errors`, which collects parse-
  /// time issues, declarativeNetRequest installation failures, and
  /// Chrome-API gaps as they accumulate — useful surface for a
  /// `View Errors` menu entry.
  public func errors(for sourceURL: URL) -> [NSError] {
    let filename = sourceURL.lastPathComponent
    guard let ctx = contextsByFilename[filename] else { return [] }
    return ctx.errors as [NSError]
  }

  /// Resolve an extension URL (`webkit-extension://<uuid>/...`) back
  /// to the owning `WKWebExtensionContext`. Required by `PaneModel.init`
  /// to seed an extension-hosted browser pane with the context's own
  /// `webViewConfiguration`, which Apple documents as the only
  /// supported way to load a `webkit-extension://` URL.
  public func extensionContext(forExtensionURL url: URL) -> WKWebExtensionContext? {
    controller.extensionContext(for: url)
  }

  /// Options page URL for the extension installed at `sourceURL`, or
  /// nil when the manifest declares no options page, the extension
  /// has been disabled, or no entry is loaded for the source. The URL
  /// is `webkit-extension://<uuid>/...` — pass straight to
  /// `addColumn(address:)` after wrapping in a `PaneAddress` to open
  /// the page as a regular browser column.
  ///
  /// Disabled entries are gated explicitly: `setEnabled(false)` calls
  /// `controller.unload` but keeps `contextsByFilename` intact, so
  /// `ctx.optionsPageURL` still resolves. Returning the URL anyway
  /// would route the click into a fallback browser pane (the
  /// controller's `extensionContext(for:)` won't resolve the
  /// unloaded ctx) and silently render a navigation failure instead
  /// of the documented "extension is disabled" alert.
  public func optionsPageURL(for sourceURL: URL) -> URL? {
    let filename = sourceURL.lastPathComponent
    guard !disabledFilenames.contains(filename) else { return nil }
    return contextsByFilename[filename]?.optionsPageURL
  }

  /// Re-parse and reactivate the extension. Equivalent to a remove +
  /// re-add round-trip but **preserves** the user's enable/disable
  /// state and the source's on-disk filename. Useful after editing a
  /// manifest or content script in place; the new context picks up
  /// the change without a full app relaunch.
  ///
  /// On failure (broken manifest, unsupported manifest version, etc.)
  /// the previously loaded context is re-installed so the sidebar row
  /// stays exactly as it was before the attempt. The user can then
  /// fix the source on disk and try again, or remove the extension
  /// outright. The caller presents the error in an `NSAlert`.
  public func reloadExtension(for sourceURL: URL) async throws {
    let filename = sourceURL.lastPathComponent
    guard let oldCtx = contextsByFilename[filename] else {
      throw NSError(
        domain: Self.errorDomain,
        code: ErrorCode.notLoaded.rawValue,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Cannot reload — '\(filename)' is not currently loaded."
        ]
      )
    }
    let displayName = oldCtx.webExtension.displayName ?? filename
    let wasEnabled = !disabledFilenames.contains(filename)
    // Capture the prior snapshot's source kind so the rollback path
    // can restore it without re-deriving it from controller state —
    // future bundle-source reload support won't have to touch this
    // code.
    let oldSourceKind =
      loadedExtensions.first(where: { $0.sourceURL == sourceURL })?.sourceKind ?? .archive

    errorsTasksByFilename[filename]?.cancel()
    errorsTasksByFilename.removeValue(forKey: filename)
    if wasEnabled {
      // Mirrors the `removeExtension` unload gate: skipping unload for
      // disabled rows because `load(at:)` never called `controller.load`
      // for them in the first place, so calling unload here would throw.
      do {
        try controller.unload(oldCtx)
      } catch {
        logger.error(
          """
          controller.unload during reload failed for \
          '\(displayName, privacy: .public)': \
          \(String(describing: error), privacy: .public)
          """
        )
      }
    }
    contextsByFilename.removeValue(forKey: filename)
    loadedExtensions.removeAll { $0.sourceURL == sourceURL }

    do {
      // `load(at:)` reads `disabledFilenames` to decide whether to
      // re-`controller.load`, so the user-toggled state survives the
      // round-trip without explicit handling here.
      try await load(at: sourceURL)
      logger.info("Reloaded '\(displayName, privacy: .public)'")
    } catch {
      // Rollback: re-install the previously loaded context so the
      // sidebar row reverts to what was visible before the reload
      // attempt. The on-disk source still holds the broken manifest;
      // restoring controller state lets the user keep using the
      // working version while they fix the source.
      restoreAfterFailedReload(
        oldCtx: oldCtx,
        sourceURL: sourceURL,
        filename: filename,
        wasEnabled: wasEnabled,
        displayName: displayName,
        sourceKind: oldSourceKind
      )
      throw error
    }
  }

  /// Re-install the previous context after a failed `reloadExtension`.
  /// The old `WKWebExtension` is still valid (we never touched the
  /// on-disk source during the reload attempt), so the snapshot can
  /// be rebuilt from it and the controller re-loaded with the same
  /// instance. Errors during rollback are logged but never re-thrown:
  /// the caller is already in the middle of throwing the original
  /// reload error, and a rollback failure is tertiary information at
  /// best.
  private func restoreAfterFailedReload(
    oldCtx: WKWebExtensionContext,
    sourceURL: URL,
    filename: String,
    wasEnabled: Bool,
    displayName: String,
    sourceKind: SourceKind
  ) {
    contextsByFilename[filename] = oldCtx
    if wasEnabled {
      do {
        try controller.load(oldCtx)
        subscribeToErrors(ctx: oldCtx, name: displayName, key: filename)
        scheduleCapabilityRecheck(ctx: oldCtx, name: displayName)
      } catch {
        // Double failure — both the new manifest load and the rollback
        // controller.load have throw'd. The cache and snapshot still
        // get rebuilt below so the row stays visible, but the error
        // subscription is not re-armed; runtime errors from the old
        // context will not surface in `View Errors` until the next
        // successful reload (or app relaunch).
        logger.error(
          """
          Rollback controller.load failed for \
          '\(displayName, privacy: .public)': \
          \(String(describing: error), privacy: .public)
          """
        )
      }
    }
    let oldExt = oldCtx.webExtension
    let filename = sourceURL.lastPathComponent
    let entry = LoadedExtension(
      sourceURL: sourceURL,
      displayName: displayName,
      version: oldExt.version,
      manifestVersion: oldExt.manifestVersion,
      icon: Self.bestIcon(for: oldExt),
      isEnabled: wasEnabled,
      isPinned: pinnedFilenames.contains(filename),
      sourceKind: sourceKind,
      hasOptionsPage: oldExt.hasOptionsPage
    )
    loadedExtensions.append(entry)
    loadedExtensions.sort {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  /// Copy an unpacked extension folder (or ZIP archive) into
  /// `extensionsRoot` and load it, so the new entry appears in the
  /// sidebar alongside the existing extensions. Throws if the
  /// destination already exists — replacing in place would silently
  /// drop user-toggled state and re-arm permission grants for what
  /// could be a different version. Throws and rolls back the copy if
  /// the load itself fails (malformed manifest, unsupported manifest
  /// version, etc.) so a bad install doesn't leave a dead directory
  /// that re-fails on every launch. The caller (sidebar UI) presents
  /// the error in an `NSAlert`.
  public func addExtension(from sourceURL: URL) async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: Self.extensionsRoot, withIntermediateDirectories: true)
    let dst = Self.extensionsRoot.appendingPathComponent(sourceURL.lastPathComponent)
    if fm.fileExists(atPath: dst.path) {
      throw NSError(
        domain: Self.errorDomain,
        code: ErrorCode.alreadyInstalled.rawValue,
        userInfo: [
          NSLocalizedDescriptionKey:
            "An extension named '\(sourceURL.lastPathComponent)' is already installed. "
            + "Remove the existing copy first if you want to replace it."
        ]
      )
    }
    try fm.copyItem(at: sourceURL, to: dst)
    do {
      try await load(at: dst)
    } catch {
      // The copy succeeded but the manifest didn't parse / register.
      // Removing the destination keeps the next launch's scan from
      // re-failing on the same input and matches the user's
      // expectation that a failed install leaves no trace.
      Self.rollbackInstall(at: dst)
      throw error
    }
  }

  /// Download an extension from the Chrome Web Store via the public
  /// update endpoint that Chromium itself uses, strip the CRX header,
  /// and load the inner ZIP through the standard install path.
  ///
  /// The endpoint replies with a redirect to a googleusercontent
  /// blob. A `HostAllowlistRedirectDelegate` gates redirects so an
  /// open redirect (or DNS hijack) of `clients2.google.com` can't
  /// stream attacker-supplied bytes into our `WKWebExtension`
  /// loader and silently inherit the auto-promoted permission set
  /// archive-flavoured installs grant.
  public func installFromChromeWebStore(extensionID id: String) async throws {
    let downloadURL = Self.chromeWebStoreCRXURL(extensionID: id)
    let crx: Data
    do {
      let delegate = HostAllowlistRedirectDelegate(
        allowedHosts: Self.chromeStoreAllowedHosts
      )
      let (data, response) = try await URLSession.shared.data(
        for: URLRequest(url: downloadURL), delegate: delegate
      )
      // The HTTP status NSError thrown here intentionally bypasses
      // the URLError catch below and propagates straight to the
      // caller — an HTTP 404 from the Web Store should reach the
      // alert verbatim, not be wrapped in a URLError-flavoured
      // message.
      try Self.requireOKResponse(response, source: "Chrome Web Store")
      crx = data
    } catch let urlError as URLError {
      throw NSError(
        domain: Self.errorDomain,
        code: ErrorCode.storeFetchFailed.rawValue,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Could not download from the Chrome Web Store: \(urlError.localizedDescription)"
        ]
      )
    }
    let zipData = try CRXArchive.extractZIP(from: crx)
    try await installDownloadedExtension(zipData, suggestedFilename: "\(id).zip")
  }

  /// Shared landing path for store-sourced ZIP data: unpack the
  /// archive into `extensionsRoot/<basename>/`, then run the standard
  /// `load(at:)`. Used to write the ZIP file in place and let
  /// WKWebExtension expand it itself, but unpacking up front lets the
  /// MV3→MV2 manifest rewriter run on the unpacked tree before
  /// WebKit ever parses it. Same rollback policy as `addExtension` —
  /// a load failure removes the freshly-written tree so dead installs
  /// don't accumulate.
  private func installDownloadedExtension(
    _ data: Data, suggestedFilename: String
  ) async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: Self.extensionsRoot, withIntermediateDirectories: true)
    let dirName = (suggestedFilename as NSString).deletingPathExtension
    let dst = Self.extensionsRoot.appendingPathComponent(dirName)
    if fm.fileExists(atPath: dst.path) {
      throw NSError(
        domain: Self.errorDomain,
        code: ErrorCode.alreadyInstalled.rawValue,
        userInfo: [
          NSLocalizedDescriptionKey:
            "An extension named '\(dirName)' is already installed. "
            + "Remove the existing copy first if you want to replace it."
        ]
      )
    }
    let tmpZip = fm.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + "-" + suggestedFilename
    )
    try data.write(to: tmpZip, options: [.atomic])
    defer { try? fm.removeItem(at: tmpZip) }
    try fm.createDirectory(at: dst, withIntermediateDirectories: true)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    proc.arguments = ["-q", tmpZip.path, "-d", dst.path]
    do {
      try proc.run()
    } catch {
      Self.rollbackInstall(at: dst)
      throw NSError(
        domain: Self.errorDomain,
        code: ErrorCode.bundleInvalid.rawValue,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Could not launch /usr/bin/unzip to unpack the downloaded archive: "
            + error.localizedDescription
        ]
      )
    }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
      Self.rollbackInstall(at: dst)
      throw NSError(
        domain: Self.errorDomain,
        code: ErrorCode.bundleInvalid.rawValue,
        userInfo: [
          NSLocalizedDescriptionKey:
            "/usr/bin/unzip exited with status \(proc.terminationStatus); the archive is corrupt or unsupported."
        ]
      )
    }
    do {
      try await load(at: dst)
    } catch {
      Self.rollbackInstall(at: dst)
      throw error
    }
  }

  /// Remove a partially-installed extension after a load failure.
  /// Logs (rather than throws) on removeItem failure: the caller is
  /// already in the middle of throwing the original install error,
  /// and the worst case of a stuck file is a re-failed load on the
  /// next launch — visible to the user as an extra log line, not as
  /// silent corruption.
  private static func rollbackInstall(at url: URL) {
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      logger.error(
        """
        Failed to roll back partial install at \
        \(url.lastPathComponent, privacy: .public): \
        \(String(describing: error), privacy: .public)
        """
      )
    }
  }

  private static func chromeWebStoreCRXURL(extensionID id: String) -> URL {
    var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
    components.queryItems = [
      URLQueryItem(name: "response", value: "redirect"),
      URLQueryItem(name: "prodversion", value: chromeStoreClientVersion),
      URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
      // The `x` parameter carries an opaque sub-query of its own
      // (`id=<id>&uc`). URLComponents percent-encodes the inner `=`
      // and `&` when serialising the outer query, which is what the
      // endpoint expects — the inner separators only have meaning
      // after the server decodes the outer value.
      URLQueryItem(name: "x", value: "id=\(id)&uc"),
    ]
    return components.url!
  }

  private static func requireOKResponse(
    _ response: URLResponse, source: String
  ) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      throw NSError(
        domain: Self.errorDomain,
        code: ErrorCode.storeFetchFailed.rawValue,
        userInfo: [
          NSLocalizedDescriptionKey:
            "\(source) returned HTTP \(http.statusCode)."
        ]
      )
    }
  }

  /// Load a Safari Web Extension from a code-signed Mac app's
  /// bundled `.appex` (or a directly-passed `.appex`). The bundle is
  /// held in place — we deliberately do **not** copy it into
  /// `extensionsRoot`, because copying invalidates the parent app's
  /// code signature (App Store distributions, Developer ID-signed
  /// builds, and ad-hoc-signed local builds all care). As a
  /// consequence:
  ///
  /// - The bundle path is recorded in
  ///   `extensions-app-bundles.json` so the next launch re-loads
  ///   the same `.appex` automatically (`forgetAppBundleExtension`
  ///   is the matching uninstall path).
  /// - The sidebar row gates Reload and Move to Trash off so we
  ///   never invoke `controller.unload`+rebuild on a bundle whose
  ///   reference we'd have to re-resolve, and never `trashItem` an
  ///   external app the user did not install through e05. The
  ///   bundle row gets a `Forget` action instead.
  /// - There's no `rollbackInstall` step on failure: nothing was
  ///   copied, so a thrown error already leaves the user's
  ///   filesystem untouched.
  public func installFromAppBundle(at sourceURL: URL) async throws {
    let resolvedURL = try await loadAppBundleInternal(at: sourceURL)
    // User-driven installs append to the persisted list and save
    // immediately; startup reloads bypass this and let
    // `loadPersistedAppBundles` save once at the end of reconciliation.
    if !persistedAppBundlePaths.contains(where: { $0.path == resolvedURL.path }) {
      persistedAppBundlePaths.append(resolvedURL)
      saveAppBundlesState()
    }
  }

  /// Core install path for `.appex` sources. Resolves the bundle,
  /// guards against duplicate filenames, and runs the standard
  /// activation pipeline. Both the user-facing `installFromAppBundle`
  /// and the startup `loadPersistedAppBundles` funnel through this so
  /// the activation logic stays in one place; persistence is layered
  /// on by the caller depending on whether this is a new install or
  /// a startup reload. Returns the resolved `.appex` URL — the
  /// caller often handed in a `.app` and needs to know which
  /// internal `.appex` was actually loaded.
  @discardableResult
  private func loadAppBundleInternal(at sourceURL: URL) async throws -> URL {
    let appexURL = try Self.resolveAppExtensionBundle(at: sourceURL)
    // Same `alreadyInstalled` guard the archive paths use: silently
    // overwriting a context that's already keyed under
    // `appex.lastPathComponent` would orphan the previous entry's
    // toggle/error subscriptions and let the new row mask the old
    // one without warning.
    let filename = appexURL.lastPathComponent
    if contextsByFilename[filename] != nil {
      throw NSError(
        domain: Self.errorDomain,
        code: ErrorCode.alreadyInstalled.rawValue,
        userInfo: [
          NSLocalizedDescriptionKey:
            "An extension named '\(filename)' is already loaded. "
            + "Remove the existing copy first if you want to replace it."
        ]
      )
    }
    guard let bundle = Bundle(url: appexURL) else {
      throw NSError(
        domain: Self.errorDomain,
        code: ErrorCode.bundleInvalid.rawValue,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Could not open '\(filename)' as an app extension bundle."
        ]
      )
    }
    try await loadFromBundle(bundle, sourceURL: appexURL)
    return appexURL
  }

  /// Default `WKWebExtensionAction` for `sourceURL`'s extension —
  /// the toolbar/badge surface a UI builds on top of. Returns `nil`
  /// when the extension isn't loaded or the action is suppressed
  /// (e.g. because `manifest.json` has no `action` key). `nil` is
  /// passed for the tab argument because PaneModel does not yet
  /// conform to `WKWebExtensionTab`; once it does, per-tab badge
  /// state can be threaded through here.
  public func defaultAction(for sourceURL: URL) -> WKWebExtension.Action? {
    let filename = sourceURL.lastPathComponent
    guard let ctx = contextsByFilename[filename] else { return nil }
    return ctx.action(for: nil)
  }

  /// Trigger the extension's default action and anchor any popup
  /// popover the extension chooses to display on the supplied view.
  /// `WKWebExtensionContext.performAction(for:)` runs synchronously
  /// in WebKit and dispatches through `presentActionPopup`, so the
  /// anchor capture below is read inside that callback before
  /// returning. Action-only extensions (no popup) just no-op the
  /// delegate and the anchor capture is harmlessly discarded.
  public func performAction(for sourceURL: URL, anchorView: NSView, anchorRect: NSRect) {
    let filename = sourceURL.lastPathComponent
    guard let ctx = contextsByFilename[filename] else {
      logger.error(
        "performAction for unknown source '\(filename, privacy: .public)' — ignored"
      )
      return
    }
    let displayName = ctx.webExtension.displayName ?? filename
    let action = ctx.action(for: nil)
    NSLog(
      "[e05/ext] performAction '%@' presentsPopup=%@ hasPopover=%@ hasWebView=%@ isEnabled=%@",
      displayName,
      (action?.presentsPopup ?? false) ? "true" : "false",
      (action?.popupPopover != nil) ? "true" : "false",
      (action?.popupWebView != nil) ? "true" : "false",
      (action?.isEnabled ?? false) ? "true" : "false"
    )
    pendingPopupAnchorView = anchorView
    pendingPopupAnchorRect = anchorRect
    ctx.performAction(for: nil)
    // Anchor is intentionally not cleared: WebKit may dispatch
    // presentActionPopup after this returns. The capture is
    // single-slot; the next click overwrites it.
  }

  /// Drop an app-bundle extension's controller state and remove its
  /// path from the persisted list so the next launch ignores it.
  /// Doesn't touch the on-disk `.app` — that belongs to the user;
  /// uninstalling the host app is a separate operation. This is the
  /// `.appBundle`-source counterpart to `removeExtension`'s
  /// Move-to-Trash flow.
  public func forgetAppBundleExtension(for sourceURL: URL) {
    let filename = sourceURL.lastPathComponent
    guard let ctx = contextsByFilename[filename] else {
      logger.error(
        "forgetAppBundleExtension for unknown source '\(filename, privacy: .public)' — ignored"
      )
      return
    }
    let displayName = ctx.webExtension.displayName ?? filename

    errorsTasksByFilename[filename]?.cancel()
    errorsTasksByFilename.removeValue(forKey: filename)
    // Same disabledFilenames-gated unload as `removeExtension`; see
    // there for the reasoning (entries that were never `controller.load`'d
    // throw on unload).
    if !disabledFilenames.contains(filename) {
      do {
        try controller.unload(ctx)
      } catch {
        logger.error(
          """
          controller.unload during forget failed for \
          '\(displayName, privacy: .public)': \
          \(String(describing: error), privacy: .public)
          """
        )
      }
    }

    contextsByFilename.removeValue(forKey: filename)
    disabledFilenames.remove(filename)
    pinnedFilenames.remove(filename)
    loadedExtensions.removeAll { $0.sourceURL == sourceURL }
    persistedAppBundlePaths.removeAll { $0.path == sourceURL.path }
    savePersistedState()
    saveAppBundlesState()
    logger.info("Forgot app-bundle extension '\(displayName, privacy: .public)'")
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  /// Resolve an `.appex` URL out of the user's selection. Accepts
  /// either an `.appex` directly or a parent `.app`; in the latter
  /// case the lexicographically first `.appex` under
  /// `Contents/PlugIns` wins, sorted to keep the choice
  /// deterministic across runs.
  private static func resolveAppExtensionBundle(at url: URL) throws -> URL {
    if url.pathExtension.lowercased() == "appex" {
      return url
    }
    let pluginsURL = url.appendingPathComponent("Contents/PlugIns", isDirectory: true)
    let fm = FileManager.default
    guard fm.fileExists(atPath: pluginsURL.path) else {
      throw NSError(
        domain: Self.errorDomain,
        code: ErrorCode.bundleNoAppex.rawValue,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Selected app does not embed a Safari Web Extension."
        ]
      )
    }
    let entries =
      ((try? fm.contentsOfDirectory(
        at: pluginsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
      )) ?? [])
      .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    guard let firstAppex = entries.first(where: { $0.pathExtension.lowercased() == "appex" })
    else {
      throw NSError(
        domain: Self.errorDomain,
        code: ErrorCode.bundleNoAppex.rawValue,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Selected app does not embed a Safari Web Extension."
        ]
      )
    }
    return firstAppex
  }

  /// Move an extension to the Trash and tear down every cache entry
  /// the controller keeps for it. The Trash is the right destination
  /// (rather than `removeItem`) so the user can put the extension
  /// back if they removed the wrong one — same Finder-style policy
  /// the e05 finder pane already uses for its `Move to Trash` action.
  /// Cleanup proceeds even if the trash step fails: the controller
  /// caches are still cleared, and on next launch the scan will pick
  /// up the still-on-disk source as a fresh entry. That re-loading
  /// behaviour is documented (not a bug); a Trash failure leaves the
  /// extension visibly back in the list after a restart.
  public func removeExtension(for sourceURL: URL) {
    let filename = sourceURL.lastPathComponent
    guard let ctx = contextsByFilename[filename] else {
      logger.error(
        "removeExtension for unknown source '\(filename, privacy: .public)' — ignored"
      )
      return
    }
    let displayName = ctx.webExtension.displayName ?? filename

    errorsTasksByFilename[filename]?.cancel()
    errorsTasksByFilename.removeValue(forKey: filename)

    // Skip `controller.unload` for entries that were never loaded —
    // `load(at:)` skips `controller.load` for any filename in
    // `disabledFilenames`, so calling unload here would always throw
    // for disabled rows. The throw itself is harmless but the
    // resulting log line reads like a real bug.
    if !disabledFilenames.contains(filename) {
      do {
        try controller.unload(ctx)
      } catch {
        logger.error(
          """
          controller.unload during remove failed for \
          '\(displayName, privacy: .public)': \
          \(String(describing: error), privacy: .public)
          """
        )
      }
    }

    do {
      try FileManager.default.trashItem(at: sourceURL, resultingItemURL: nil)
      logger.info("Trashed '\(displayName, privacy: .public)'")
    } catch {
      logger.error(
        """
        trashItem failed for '\(sourceURL.lastPathComponent, privacy: .public)': \
        \(String(describing: error), privacy: .public). \
        Controller caches cleared anyway; the source on disk will \
        re-appear after the next launch's scan.
        """
      )
    }

    contextsByFilename.removeValue(forKey: filename)
    disabledFilenames.remove(filename)
    pinnedFilenames.remove(filename)
    loadedExtensions.removeAll { $0.sourceURL == sourceURL }
    savePersistedState()
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  /// Toggle the runtime activation of `sourceURL`'s extension and
  /// persist the new state. Idempotent on the requested side: calling
  /// with `true` for an already-enabled extension is a cheap no-op.
  /// Failures from `controller.load` / `controller.unload` are logged
  /// but the persisted state is still updated — the alternative
  /// (rolling back the user's intent because WebKit had a transient
  /// problem) makes the toggle feel unreliable in practice.
  public func setEnabled(_ enabled: Bool, for sourceURL: URL) {
    let filename = sourceURL.lastPathComponent
    guard let ctx = contextsByFilename[filename] else {
      logger.error(
        "setEnabled(\(enabled)) for unknown source '\(filename, privacy: .public)' — ignored"
      )
      return
    }
    let wasDisabled = disabledFilenames.contains(filename)
    guard enabled == wasDisabled else { return }

    let displayName = ctx.webExtension.displayName ?? filename
    if enabled {
      disabledFilenames.remove(filename)
      do {
        try controller.load(ctx)
        logger.info("Enabled '\(displayName, privacy: .public)'")
        // Re-arm the diagnostics channels we wired during the initial
        // load so a re-enabled extension produces the same telemetry
        // as a freshly installed one. Kept inside the try so a failed
        // load doesn't leave a subscriber attached to an inactive
        // context.
        subscribeToErrors(ctx: ctx, name: displayName, key: filename)
        scheduleCapabilityRecheck(ctx: ctx, name: displayName)
        Self.eagerlyLoadBackgroundContent(ctx: ctx, name: displayName)
      } catch {
        logger.error(
          """
          controller.load failed for '\(displayName, privacy: .public)': \
          \(String(describing: error), privacy: .public)
          """
        )
      }
    } else {
      disabledFilenames.insert(filename)
      // Tear down the diagnostics subscription so the AsyncSequence
      // for-await self-terminates and the Task can be released.
      errorsTasksByFilename[filename]?.cancel()
      errorsTasksByFilename.removeValue(forKey: filename)
      do {
        try controller.unload(ctx)
        logger.info("Disabled '\(displayName, privacy: .public)'")
      } catch {
        logger.error(
          """
          controller.unload failed for '\(displayName, privacy: .public)': \
          \(String(describing: error), privacy: .public)
          """
        )
      }
    }

    // Mirror the new flag into the snapshot array so listeners that
    // re-read `loadedExtensions` after the post observe the change
    // without an extra round-trip through the controller.
    if let i = loadedExtensions.firstIndex(where: { $0.sourceURL == sourceURL }) {
      loadedExtensions[i].isEnabled = enabled
    }
    savePersistedState()
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  /// Toggle the URL-bar pinning state for `sourceURL`'s extension.
  /// Idempotent on the requested side. Pure persistence + snapshot
  /// update — no `WKWebExtensionContext` activity is involved, since
  /// pinning is a host-side display concern WebKit knows nothing
  /// about. The post lets the URL bar and the sidebar re-render
  /// against the new flag.
  public func setPinned(_ pinned: Bool, for sourceURL: URL) {
    let filename = sourceURL.lastPathComponent
    let wasPinned = pinnedFilenames.contains(filename)
    guard pinned != wasPinned else { return }
    if pinned {
      pinnedFilenames.insert(filename)
    } else {
      pinnedFilenames.remove(filename)
    }
    if let i = loadedExtensions.firstIndex(where: { $0.sourceURL == sourceURL }) {
      loadedExtensions[i].isPinned = pinned
    }
    savePersistedState()
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  private func loadPersistedState() {
    let url = Self.extensionsStateFileURL
    guard let data = try? Data(contentsOf: url) else {
      // A missing file is the first-run convention, not an error —
      // every extension defaults to enabled until the user toggles
      // one off.
      return
    }
    do {
      let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
      disabledFilenames = Set(decoded.disabledFilenames)
      pinnedFilenames = Set(decoded.pinnedFilenames)
    } catch {
      logger.error(
        """
        Failed to decode extensions-state.json: \
        \(String(describing: error), privacy: .public). \
        Falling back to all-enabled defaults.
        """
      )
    }
  }

  private func savePersistedState() {
    let url = Self.extensionsStateFileURL
    let payload = PersistedState(
      disabledFilenames: disabledFilenames.sorted(),
      pinnedFilenames: pinnedFilenames.sorted()
    )
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(payload)
      try data.write(to: url, options: [.atomic])
    } catch {
      logger.error(
        """
        Failed to write extensions-state.json at \
        \(url.path, privacy: .private(mask: .hash)): \
        \(String(describing: error), privacy: .public)
        """
      )
    }
  }

  /// Force the background page / service worker to start immediately
  /// instead of waiting for the first `chrome.runtime.sendMessage`
  /// from a content script or popup. Without this kick, MV3 service
  /// workers and event-page MV2 background pages stay dormant until
  /// a saved listener is dispatched — and on a fresh install there
  /// are no saved listeners yet, so the popup's first
  /// `runtime.sendMessage` waits forever for a recipient that's
  /// never going to wake up. Symptomatically: popup HTML loads but
  /// the JS hangs on the initial "Loading please wait..." placeholder.
  ///
  /// Errors are swallowed (logged) on purpose: an extension without
  /// background content (`NoBackgroundContent`) shouldn't be a fatal
  /// load failure, and a transient `BackgroundContentFailedToLoad`
  /// will be re-attempted on the next sendMessage anyway.
  private static func eagerlyLoadBackgroundContent(
    ctx: WKWebExtensionContext, name: String
  ) {
    ctx.loadBackgroundContent { error in
      Task { @MainActor in
        if let error {
          let ns = error as NSError
          // Code 9 (NoBackgroundContent) is not really an error for
          // pure declarative-net-request packs; surface it as info.
          if ns.domain == "WKWebExtensionContextErrorDomain"
            && ns.code == WKWebExtensionContext.Error.noBackgroundContent.rawValue
          {
            NSLog("[e05/ext] '%@' has no background content (declarative-only)", name)
          } else {
            NSLog(
              "[e05/ext] loadBackgroundContent FAILED '%@' domain=%@ code=%ld desc=%@",
              name, ns.domain, ns.code, ns.localizedDescription
            )
          }
        } else {
          NSLog("[e05/ext] loadBackgroundContent OK '%@' — bg is awake", name)
        }
      }
    }
  }

  private static func logErrors(ctx: WKWebExtensionContext, source: String) {
    let errs = ctx.errors
    let name = ctx.webExtension.displayName ?? "(unknown)"
    if errs.isEmpty {
      NSLog("[e05/ext] [%@] no runtime errors for '%@'", source, name)
      return
    }
    for (i, err) in errs.enumerated() {
      let ns = err as NSError
      NSLog(
        "[e05/ext] [%@] err[%d] '%@' domain=%@ code=%ld desc=%@ userInfo=%@",
        source, i, name, ns.domain, ns.code, ns.localizedDescription,
        String(describing: ns.userInfo)
      )
    }
  }
}

/// Snapshot of one activated extension surfaced to the sidebar list.
/// Captured at load time so repeated reads (cell render, listener
/// fan-out) don't re-touch the underlying `WKWebExtensionContext`.
/// `NSImage` is not `Sendable`, so the type is `MainActor`-confined —
/// every accessor touches it from the main queue. Stable identity for
/// per-row routing comes from `sourceURL`: the directory or ZIP path
/// under `~/.config/e05/extensions/` is unique per extension.
@MainActor
public struct LoadedExtension {
  public let sourceURL: URL
  public let displayName: String
  public let version: String?
  public let manifestVersion: Double
  public let icon: NSImage?
  /// Reflects whether `controller.load` is currently active for this
  /// entry. Mutable so the controller's `setEnabled` can flip the
  /// snapshot in place; external callers should treat the value as
  /// read-only and route changes through `ExtensionController`.
  public internal(set) var isEnabled: Bool
  /// Whether the user has pinned the extension to the URL-bar
  /// action row. Unpinned extensions reach their popup through the
  /// URL bar's puzzle-piece menu instead of taking a permanent
  /// slot. Mutated through `ExtensionController.setPinned`; the
  /// snapshot field exists so cell renders skip a controller hop.
  public internal(set) var isPinned: Bool
  /// Where the extension was loaded from. Drives the sidebar's
  /// per-row UI gating: `.archive` rows expose the full ellipsis
  /// menu (Reload / Move to Trash), `.appBundle` rows hide actions
  /// that would touch a code-signed app the controller doesn't own.
  public let sourceKind: SourceKind
  /// Mirrors `WKWebExtension.hasOptionsPage` at activation time.
  /// Captured into the snapshot so the sidebar's row menu can gate
  /// the `Open Options Page` item without a per-render lookup
  /// through the context cache.
  public let hasOptionsPage: Bool
}

/// How an extension reached `ExtensionController`. The value is
/// frozen at install time and travels with the snapshot so UI code
/// can gate destructive actions without re-inspecting the file
/// system. `public` mirrors `LoadedExtension`; tightening both to
/// `internal` is a follow-up bundled with the loadedExtensions
/// access-level review.
public enum SourceKind: Sendable {
  /// Unpacked directory or ZIP archive under
  /// `~/.config/e05/extensions/` — including ones the user dropped
  /// in by hand and ones e05 wrote there from a Web Store / AMO
  /// download. Safe targets for Reload / Move to Trash.
  case archive
  /// `.appex` bundle inside an external `.app` (typically a
  /// Mac App Store app's bundled Safari Web Extension). Loaded in
  /// place; Reload would need to recreate the bundle reference and
  /// Move to Trash would Trash the bundling app, so both are gated
  /// off in the sidebar UI.
  case appBundle
}

/// Delegate wrapper kept as a private class so the controller retains it via
/// its weak `delegate` pointer (a struct would be released immediately).
@MainActor
private final class DelegateProxy: NSObject, WKWebExtensionControllerDelegate {
  /// Owning controller, set right after init so the popup callback
  /// can read the URL-bar anchor capture. Weak avoids a reference
  /// cycle with the controller's strong `delegate` pointer.
  weak var controller: ExtensionController?

  /// Live native messaging ports, retained per `WKWebExtensionMessagePort`
  /// identity so each long-lived connection stays alive until the
  /// extension or host disconnects. Apple's SDK contract treats the
  /// port object as the lifetime anchor — releasing it disconnects the
  /// channel — so we mirror that with a dictionary keyed by port
  /// identity instead of a free-floating Set.
  var nativePorts: [ObjectIdentifier: NativeMessagingPort] = [:]

  /// Associated-object key for the per-popup KVO token. Storing the
  /// observation on the popup web view itself ties its lifetime to
  /// the view (released alongside the popup), unlike a delegate-side
  /// dictionary keyed by `ObjectIdentifier(popupView)` which leaks an
  /// entry per popup open *and* exposes a use-after-free risk: an
  /// `ObjectIdentifier` is just the pointer bit pattern, so a
  /// reallocated WKWebView at the same address can land in the dict
  /// and silently overwrite the old entry.
  private static var popupObservationKey: UInt8 = 0

  // Hand back the single host window. e05's niri-style WM treats
  // every workspace as a slice of one continuous editing surface,
  // so the bridge unifies them into one `WKWebExtensionWindow`.
  // Returning the empty / nil form before `bindContainer(_:)` runs
  // is a defensive guard for races between controller load and
  // PaneContainer assembly — once bound, every loaded extension
  // sees the same workspace bridge identity for the rest of the
  // session.
  func webExtensionController(
    _: WKWebExtensionController,
    openWindowsFor _: WKWebExtensionContext
  ) -> [any WKWebExtensionWindow] {
    guard let controller, controller.workspaceBridge.container != nil else {
      return []
    }
    return [controller.workspaceBridge]
  }

  func webExtensionController(
    _: WKWebExtensionController,
    focusedWindowFor _: WKWebExtensionContext
  ) -> (any WKWebExtensionWindow)? {
    guard let controller, controller.workspaceBridge.container != nil else {
      return nil
    }
    return controller.workspaceBridge
  }

  // Three symmetric auto-grant paths — runtime-prompted permissions,
  // URL access, and match-pattern access. Leaving any of these
  // unimplemented maps to silent denial in WebKit, which is painful
  // to diagnose when an extension requests an optional host late.
  func webExtensionController(
    _: WKWebExtensionController,
    promptForPermissions permissions: Set<WKWebExtension.Permission>,
    in _: (any WKWebExtensionTab)?,
    for context: WKWebExtensionContext,
    completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
  ) {
    let names = permissions.map(\.rawValue).sorted().joined(separator: ",")
    logger.info(
      """
      Auto-granting runtime-prompted permissions [\(names, privacy: .public)] for \
      '\(context.webExtension.displayName ?? "(unknown)", privacy: .public)'
      """
    )
    completionHandler(permissions, nil)
  }

  func webExtensionController(
    _: WKWebExtensionController,
    promptForPermissionToAccess urls: Set<URL>,
    in _: (any WKWebExtensionTab)?,
    for context: WKWebExtensionContext,
    completionHandler: @escaping (Set<URL>, Date?) -> Void
  ) {
    let urlStrings = urls.map(\.absoluteString).sorted().joined(separator: ",")
    logger.info(
      """
      Auto-granting runtime URL access [\(urlStrings, privacy: .public)] for \
      '\(context.webExtension.displayName ?? "(unknown)", privacy: .public)'
      """
    )
    completionHandler(urls, nil)
  }

  func webExtensionController(
    _: WKWebExtensionController,
    promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
    in _: (any WKWebExtensionTab)?,
    for context: WKWebExtensionContext,
    completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
  ) {
    let patternStrings = patterns.map(\.string).sorted().joined(separator: ",")
    logger.info(
      """
      Auto-granting runtime match patterns [\(patternStrings, privacy: .public)] for \
      '\(context.webExtension.displayName ?? "(unknown)", privacy: .public)'
      """
    )
    completionHandler(patterns, nil)
  }

  // Show the extension's popup popover anchored on the URL-bar
  // button the user clicked. Anchor coordinates were stashed by
  // `ExtensionController.performAction(for:anchorView:anchorRect:)`
  // immediately before WebKit dispatched here. Completion is always
  // `nil`: telling WebKit the request failed would invite the
  // extension to retry on every user gesture, but a missing popup
  // (e.g. action without a popup, missing anchor capture) is a
  // legitimate "nothing to show" path the extension already
  // tolerates.
  // Bridge `chrome.runtime.sendNativeMessage` for hosts we know how
  // to satisfy in-process. Bitwarden's Safari build routes every
  // `copyToClipboard` request through `sendNativeMessage` to its
  // companion app's `SafariWebExtensionHandler`, which on the real
  // platform writes to `NSPasteboard.general`. WKWebExtensionController
  // doesn't ship a native host registry, so without this hook the
  // call resolves with no reply and the popup's copy button silently
  // does nothing — the same code path that drives password / TOTP /
  // username copy. Returning a synthesised reply convinces the
  // extension that the host responded and lets its UX continue.
  //
  // Only specific hosts are honoured: an unrecognised
  // `applicationIdentifier` resolves with an explicit error so future
  // additions stay opt-in rather than silently mimicking arbitrary
  // hosts.
  func webExtensionController(
    _: WKWebExtensionController,
    sendMessage message: Any,
    toApplicationWithIdentifier applicationIdentifier: String?,
    for context: WKWebExtensionContext,
    replyHandler: @escaping (Any?, Error?) -> Void
  ) {
    let name = context.webExtension.displayName ?? "(unknown)"
    let host = applicationIdentifier ?? "(nil)"
    logger.info(
      """
      sendMessage '\(name, privacy: .public)' \
      → host=\(host, privacy: .public) \
      shape=\(String(describing: type(of: message)), privacy: .public)
      """
    )
    guard applicationIdentifier == "com.bitwarden.desktop",
      let payload = message as? [String: Any],
      let command = payload["command"] as? String
    else {
      replyHandler(
        nil,
        NSError(
          domain: "com.kawarimidoll.e05.Extensions",
          code: 10,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Native messaging host '\(host)' is not bridged in e05."
          ]
        )
      )
      return
    }
    switch command {
    case "copyToClipboard":
      let text = (payload["data"] as? String) ?? ""
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(text, forType: .string)
      replyHandler(["status": "ok"], nil)
    case "readFromClipboard":
      let text = NSPasteboard.general.string(forType: .string) ?? ""
      replyHandler(["status": "ok", "data": text], nil)
    default:
      // Reply with a soft error so callbacks resolve. Returning nil
      // without an error makes the extension treat the message as a
      // success it can't interpret, which is worse than an honest
      // "unhandled" signal.
      replyHandler(
        nil,
        NSError(
          domain: "com.kawarimidoll.e05.Extensions",
          code: 11,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Bitwarden native command '\(command)' is not implemented in e05."
          ]
        )
      )
    }
  }

  /// Long-lived port equivalent of `sendMessage:toApplicationWithIdentifier:`.
  /// `chrome.runtime.connectNative(host)` lands here with the WebKit-side
  /// `WKWebExtensionMessagePort` already wired; we resolve a Chrome-style
  /// native messaging manifest for the requested host, spawn the binary it
  /// names, and bridge JSON traffic between the port and the subprocess so
  /// the extension can hold an open channel for the lifetime of the
  /// handshake (Bitwarden's biometric unlock relies on a persistent
  /// encryption channel established this way).
  ///
  /// Without this, `chrome.runtime.connectNative` falls through to the
  /// "no action performed" default and the extension hangs on its first
  /// `port.postMessage`. The pop-up shows "Bitwarden デスクトップアプリとの
  /// 通信許可がなければ、ブラウザー拡張機能で生体認証を利用できません".
  func webExtensionController(
    _: WKWebExtensionController,
    connectUsing port: WKWebExtension.MessagePort,
    for context: WKWebExtensionContext,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let appId = port.applicationIdentifier ?? ""
    let extName = context.webExtension.displayName ?? "(unknown)"
    NSLog(
      "[e05/ext] connectUsingMessagePort '%@' → host=%@",
      extName, appId
    )
    logger.info(
      """
      connectUsingMessagePort '\(extName, privacy: .public)' \
      → host=\(appId, privacy: .public)
      """
    )
    guard !appId.isEmpty,
      let manifest = NativeMessagingHostRegistry.manifest(forHost: appId)
    else {
      completionHandler(
        NSError(
          domain: ExtensionController.errorDomain,
          code: ExtensionController.ErrorCode.nativeHostNotFound.rawValue,
          userInfo: [
            NSLocalizedDescriptionKey:
              "No native messaging manifest installed for host '\(appId)'."
          ]
        )
      )
      return
    }
    // Chrome convention: pass the calling extension's origin URL as the
    // first subprocess argument so the host can identify which channel
    // it is talking to. Bitwarden Desktop refuses to negotiate the
    // encryption handshake without this — it routes per-extension keys
    // by origin.
    //
    // 1Password Browser Helper validates the origin against the
    // production extension ID (`aeblfdkhh…`) derived from the CRX
    // `key`. Our ManifestRewriter strips `key` so the manifest WebKit
    // sees no longer carries it; pre-write the derived
    // `chrome-extension://<id>/` to `_e05_caller_origin` next to the
    // manifest and prefer it here. Hosts that don't validate (Bitwarden
    // Desktop) don't care which valid-shape origin we send. Falling
    // back to the manifest's first allowed origin keeps the older
    // `.appex` path working.
    let callerOrigin: String? = {
      if let extDir = controller?.extensionDirectory(for: context) {
        let originFile = extDir.appendingPathComponent("_e05_caller_origin")
        if let data = try? Data(contentsOf: originFile),
          let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !s.isEmpty
        {
          NSLog(
            "[e05/ext] using derived caller origin '%@' for host '%@'",
            s, appId
          )
          return s
        }
      }
      return manifest.allowedOrigins?.first ?? manifest.allowedExtensions?.first
    }()
    let key = ObjectIdentifier(port)
    do {
      let nmPort = try NativeMessagingPort(
        port: port,
        manifest: manifest,
        callerOrigin: callerOrigin
      )
      nmPort.onClosed = { [weak self] in
        self?.nativePorts.removeValue(forKey: key)
      }
      nativePorts[key] = nmPort
      completionHandler(nil)
    } catch {
      logger.error(
        """
        Failed launching native host '\(appId, privacy: .public)' \
        at \(manifest.path, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """
      )
      completionHandler(
        NSError(
          domain: ExtensionController.errorDomain,
          code: ExtensionController.ErrorCode.nativeHostLaunchFailed.rawValue,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Could not launch native messaging host '\(appId)': \(error.localizedDescription)",
            NSUnderlyingErrorKey: error,
          ]
        )
      )
    }
  }

  func webExtensionController(
    _: WKWebExtensionController,
    presentActionPopup action: WKWebExtension.Action,
    for context: WKWebExtensionContext,
    completionHandler: @escaping (Error?) -> Void
  ) {
    let name = context.webExtension.displayName ?? "(unknown)"
    // Enable Web Inspector access on the popup web view. The legacy
    // `developerExtrasEnabled` preference key is the right-click
    // "Inspect Element" gate; the modern `isInspectable` property
    // (macOS 13.3+) is what makes the web view visible in Safari's
    // Develop menu so a popover that closes on right-click can still
    // be inspected via Develop → <e05> → <popup URL>.
    if let popupView = action.popupWebView {
      popupView.configuration.preferences.setValue(
        true, forKey: "developerExtrasEnabled"
      )
      popupView.isInspectable = true
      // Track URL / loading transitions so SPA hash navigations and
      // post-auth route changes surface in the same trace stream as
      // the rest of the bridge — popups don't get a navigation
      // delegate hook from the controller, so KVO is the cheapest
      // way to see whether the extension's router is moving at all.
      // Stash the observation on the popup web view itself via an
      // associated object so the token is released together with the
      // popup; a delegate-side dictionary would leak one entry per
      // open and risk pointer-reuse collisions.
      let observation = popupView.observe(
        \.url, options: [.initial, .new]
      ) { wv, _ in
        // KVO callbacks are typed Sendable but always fire on the
        // observed view's queue; popup web views are main-actor only,
        // so it's safe to assume isolation here for the isLoading /
        // url reads.
        MainActor.assumeIsolated {
          NSLog(
            "[e05/ext] popup URL '%@' loading=%@ url=%@",
            name,
            wv.isLoading ? "true" : "false",
            wv.url?.absoluteString ?? "(nil)"
          )
        }
      }
      objc_setAssociatedObject(
        popupView,
        &Self.popupObservationKey,
        observation,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
      )
    }
    NSLog(
      "[e05/ext] presentActionPopup '%@' hasPopover=%@ hasWebView=%@ anchorCaptured=%@",
      name,
      (action.popupPopover != nil) ? "true" : "false",
      (action.popupWebView != nil) ? "true" : "false",
      (self.controller?.pendingPopupAnchorView != nil) ? "true" : "false"
    )
    guard let popover = action.popupPopover else {
      NSLog("[e05/ext] presentActionPopup '%@' → no popupPopover, no-op", name)
      completionHandler(nil)
      return
    }
    // The window/superview check guards against a workspace switch
    // (or column rebuild) detaching the URL-bar button between the
    // user's click and WebKit's delayed `presentActionPopup` dispatch
    // — `popover.show(relativeTo:of:preferredEdge:)` on a view that
    // no longer has a window crashes in older AppKit and quietly
    // anchors to the screen origin in current AppKit, both of which
    // are worse than dropping the popup.
    guard let anchorView = controller?.pendingPopupAnchorView,
      anchorView.window != nil, anchorView.superview != nil
    else {
      NSLog(
        "[e05/ext] presentActionPopup '%@' → no live anchor view (workspace switch tore URL bar down?)",
        name
      )
      completionHandler(nil)
      return
    }
    let anchorRect = controller?.pendingPopupAnchorRect ?? anchorView.bounds
    // Semi-transient so Inspect Element / Web Inspector can open
    // alongside the popup without dismissing it. .transient (the
    // default) closes the popover on every click outside its bounds,
    // including the right-click that summons the inspector menu and
    // the inspector window itself, which makes popup-side debugging
    // impossible. Semi-transient still closes the popover on app
    // switch (matching the conventional browser-popup ergonomics) but
    // keeps it alive across in-app focus changes.
    popover.behavior = .semitransient
    NSLog(
      "[e05/ext] showing popover '%@' anchor=%@ rect=%@",
      name, String(describing: type(of: anchorView)),
      String(describing: anchorRect)
    )
    popover.show(
      relativeTo: anchorRect,
      of: anchorView,
      preferredEdge: .maxY
    )
    completionHandler(nil)
  }

  /// Bridge `chrome.tabs.create` to a new browser pane in the host
  /// container. Without this, an extension that relies on opening a
  /// helper tab (Captcha verification, OAuth handoff, settings page
  /// link) sees its `chrome.tabs.create` call resolve with `nil` and
  /// silently fails — the popup looks like it hung after the user
  /// triggered the action.
  func webExtensionController(
    _: WKWebExtensionController,
    openNewTabUsing configuration: WKWebExtension.TabConfiguration,
    for context: WKWebExtensionContext,
    completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
  ) {
    let extName = context.webExtension.displayName ?? "(unknown)"
    let url = configuration.url
    NSLog(
      "[e05/ext] openNewTabUsing '%@' url=%@ shouldFocus=%@",
      extName, url?.absoluteString ?? "(nil)",
      configuration.shouldBeActive ? "true" : "false"
    )
    guard let container = controller?.workspaceBridge.container else {
      completionHandler(
        nil,
        NSError(
          domain: ExtensionController.errorDomain,
          code: 14,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Cannot create tab — host container is not yet bound."
          ]
        )
      )
      return
    }
    let address: PaneAddress = url.map(PaneAddress.init) ?? .blankBrowser
    let column = container.addColumn(address: address)
    guard let pane = column.panes.first else {
      completionHandler(
        nil,
        NSError(
          domain: ExtensionController.errorDomain,
          code: 14,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Created column has no pane — this should not happen."
          ]
        )
      )
      return
    }
    let bridge = ExtensionController.shared.bridge(for: pane)
    if configuration.shouldBeActive {
      container.focusPane(id: pane.id)
    }
    completionHandler(bridge, nil)
  }
}

/// Receives `postMessage` payloads from the console-relay shim
/// installed on the controller's shared `userContentController`. Each
/// payload is a `{level, text, url}` triple; we collapse it to a
/// single NSLog line so popup / background / content-script console
/// output flows into the same stderr stream as the native messaging
/// trace, sidestepping the fragility of attaching Web Inspector to a
/// popover-hosted web view.
@MainActor
private final class ConsoleRelayHandler: NSObject, WKScriptMessageHandler {
  func userContentController(
    _: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard let dict = message.body as? [String: Any] else { return }
    let level = (dict["level"] as? String) ?? "?"
    let text = (dict["text"] as? String) ?? "(empty)"
    let url = (dict["url"] as? String) ?? "(no url)"
    NSLog("[e05/console %@] %@ — %@", level, text, url)
  }
}

/// Per-task `URLSessionTaskDelegate` that drops 30x redirects whose
/// target host is outside an allowlist. Used by the store / AMO
/// download paths so a malicious open redirect on a trusted entry
/// host can't stream attacker bytes into the WKWebExtension loader.
private final class HostAllowlistRedirectDelegate: NSObject, URLSessionTaskDelegate {
  let allowedHosts: Set<String>

  init(allowedHosts: Set<String>) {
    self.allowedHosts = allowedHosts
  }

  func urlSession(
    _: URLSession,
    task _: URLSessionTask,
    willPerformHTTPRedirection _: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let host = request.url?.host?.lowercased(),
      ExtensionController.hostMatches(host, allowed: allowedHosts)
    else {
      // Returning nil cancels the redirect; the in-flight task
      // surfaces as a `URLError(.cancelled)` to the caller, which
      // the existing catch arm converts into a `storeFetchFailed`
      // error visible in the install alert.
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}
