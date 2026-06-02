import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: LogSubsystem.app, category: "ManifestRewriter")

/// In-place MV3 → MV2 manifest rewriter for unpacked extension trees.
/// Apple WKWebExtension does not wake MV3 service-worker backgrounds,
/// so popups that talk to bg via `runtime.sendMessage` hang. Rewriting
/// the manifest into MV2 + `background.page` + `persistent: false`
/// (event-page) lets a large class of CRX run unmodified — WebKit
/// wakes event pages reliably.
///
/// Idempotent: re-running on a tree that has already been rewritten
/// is a no-op. The original `manifest.json` is preserved at
/// `manifest.json.e05-original` so the rewrite can be diffed and
/// reverted by hand without re-installing.
///
/// Limitations the rewriter does NOT solve:
/// - bg code that calls `importScripts(...)` (SW-only global)
/// - bg code that touches `self.clients` / `ServiceWorkerRegistration`
/// - declarative_net_request rules (MV2 has webRequest blocking only)
/// - offscreen documents
enum ManifestRewriter {
  /// Reproduce Chromium's `crx_file::id_util::GenerateId` over the
  /// SubjectPublicKeyInfo DER bytes encoded in `manifest.json`'s
  /// `key`. Chromium hashes the key with SHA-256, takes the first
  /// 16 bytes, hex-encodes them (32 chars 0-9a-f), then maps each
  /// hex character into a-p by adding 'a'. The result is the
  /// 32-char extension ID Chrome shows in `chrome://extensions/`
  /// and that the manifest's `allowed_origins` references for
  /// production CRX deployments. We need it so native-messaging
  /// hosts (1Password Browser Helper, …) authenticate us as the
  /// "real" extension instead of rejecting the caller as
  /// `UnknownBrowser`.
  static func chromeExtensionID(fromBase64DERKey base64Key: String) -> String? {
    guard let keyData = Data(base64Encoded: base64Key) else { return nil }
    let hash = SHA256.hash(data: keyData)
    var result = ""
    for byte in hash.prefix(16) {
      let hi = Int(byte >> 4) & 0x0F
      let lo = Int(byte) & 0x0F
      result.append(Character(UnicodeScalar(0x61 + hi)!))
      result.append(Character(UnicodeScalar(0x61 + lo)!))
    }
    return result.count == 32 ? result : nil
  }


  enum RewriteError: Swift.Error, CustomStringConvertible {
    case manifestNotFound(URL)
    case manifestNotJSON(URL, underlying: Swift.Error)
    case manifestNotDictionary(URL)
    case writeFailed(URL, underlying: Swift.Error)

    var description: String {
      switch self {
      case .manifestNotFound(let url):
        return "manifest.json not found at \(url.path)"
      case .manifestNotJSON(let url, let underlying):
        return "manifest.json at \(url.path) failed to parse: \(underlying)"
      case .manifestNotDictionary(let url):
        return "manifest.json at \(url.path) is not a JSON object"
      case .writeFailed(let url, let underlying):
        return "Failed writing \(url.path): \(underlying)"
      }
    }
  }

  /// Rewrite the manifest at `dir/manifest.json` from MV3 to MV2 in
  /// place. Returns true if any change was applied; false if the
  /// manifest is already MV2 (or has no fields the rewriter knows
  /// about).
  ///
  /// - Throws: `RewriteError` on parse / IO problems. The caller
  ///   should log and proceed with the original manifest — a failed
  ///   rewrite is a degraded mode (popup may hang) but not a fatal
  ///   install error.
  static func mv3ToMV2(at dir: URL) throws -> Bool {
    let fm = FileManager.default
    // R&D opt-out: a `.e05-skip-rewrite` marker leaves the manifest
    // alone so the same extension can be tested under both the MV3
    // SW and MV2 event-page paths without re-installing. Lets us
    // attribute regressions to the rewrite vs. the underlying
    // extension when an MV2-rewritten extension misbehaves.
    let skipMarker = dir.appendingPathComponent(".e05-skip-rewrite")
    if fm.fileExists(atPath: skipMarker.path) {
      logger.info(
        "MV3→MV2 rewrite skipped at \(dir.lastPathComponent, privacy: .public) (.e05-skip-rewrite marker present)"
      )
      return false
    }
    let manifestURL = dir.appendingPathComponent("manifest.json")
    let backupURL = dir.appendingPathComponent("manifest.json.e05-original")
    let shimURL = dir.appendingPathComponent("_e05_bg_shim.js")
    guard fm.fileExists(atPath: manifestURL.path) else {
      throw RewriteError.manifestNotFound(manifestURL)
    }

    // If a previous run already converted this extension, the
    // on-disk manifest reads `manifest_version: 2` and the mv check
    // below would skip re-running the rewriter — meaning new
    // rewriter rules (CSP relaxation, additional polyfills, etc.)
    // never reach extensions that were converted by an older build.
    // Restore from the backup of the original MV3 manifest so each
    // load re-applies the *current* rewriter rules from a canonical
    // starting point.
    let original: Data
    do {
      if fm.fileExists(atPath: backupURL.path) {
        original = try Data(contentsOf: backupURL)
      } else {
        original = try Data(contentsOf: manifestURL)
      }
    } catch {
      throw RewriteError.writeFailed(manifestURL, underlying: error)
    }

    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(
        with: original, options: [.fragmentsAllowed]
      )
    } catch {
      throw RewriteError.manifestNotJSON(manifestURL, underlying: error)
    }
    guard var manifest = parsed as? [String: Any] else {
      throw RewriteError.manifestNotDictionary(manifestURL)
    }

    let mv = (manifest["manifest_version"] as? Int) ?? 0
    guard mv == 3 else {
      return false
    }

    var didRewrite = false
    var synthBg: (script: String, isModule: Bool)?

    // background.service_worker (+ optional type:"module") →
    //   background.page = "_e05_bg.html" + persistent: false.
    // Synthesize the html so the SW source can keep its original path
    // (helps when the bg references sibling assets relative to
    // chrome.runtime.getURL("background/something")).
    if let bg = manifest["background"] as? [String: Any] {
      if let sw = bg["service_worker"] as? String {
        let isModule = (bg["type"] as? String) == "module"
        synthBg = (sw, isModule)
        manifest["background"] = [
          "page": "_e05_bg.html",
          "persistent": false,
        ] as [String: Any]
        didRewrite = true
      } else if var bg2 = manifest["background"] as? [String: Any],
        bg2["scripts"] is [String]
      {
        // Already MV2-style scripts, but MV3 manifest may have left
        // `persistent` unset. Default to false (event-page) — matches
        // what Chrome enforces for MV3 anyway.
        if bg2["persistent"] == nil {
          bg2["persistent"] = false
          manifest["background"] = bg2
          didRewrite = true
        }
      }
    }

    // action → browser_action (key rename only, value carries through).
    if let action = manifest["action"] {
      manifest.removeValue(forKey: "action")
      manifest["browser_action"] = action
      didRewrite = true
    }

    // host_permissions → permissions merge. MV2 has no
    // host_permissions key; hosts go in the permissions array.
    if let host = manifest["host_permissions"] as? [String], !host.isEmpty {
      var perms = (manifest["permissions"] as? [String]) ?? []
      perms.append(contentsOf: host)
      manifest["permissions"] = perms
      manifest.removeValue(forKey: "host_permissions")
      didRewrite = true
    }

    // web_accessible_resources: MV3 array-of-objects → MV2 flat array.
    // Per-entry matches/extension_ids are dropped (MV2 has no
    // equivalent in this shape); the resources themselves remain
    // accessible. Adequate for popup/content-script asset loading.
    if let war = manifest["web_accessible_resources"] as? [[String: Any]] {
      var flat: [String] = []
      for entry in war {
        if let resources = entry["resources"] as? [String] {
          flat.append(contentsOf: resources)
        }
      }
      manifest["web_accessible_resources"] = flat
      didRewrite = true
    }

    // content_security_policy: object → string. MV3 nests under
    // `extension_pages` / `sandbox`; MV2 only has the flat string.
    // Use extension_pages if present (the common case), otherwise
    // leave whatever was there. After conversion, the CSP also
    // gets `'unsafe-eval'` injected into `script-src` so the
    // bg-shim's `importScripts` polyfill (sync XHR + indirect eval)
    // isn't blocked. Bitwarden ships `script-src 'self'
    // 'wasm-unsafe-eval'` which has no JS eval permission, and the
    // SDK loader's `importScripts` call ends up needing one to
    // execute the fetched module text synchronously.
    if let csp = manifest["content_security_policy"] as? [String: Any],
      let extPages = csp["extension_pages"] as? String
    {
      manifest["content_security_policy"] = Self.enrichCSP(extPages)
      didRewrite = true
    } else if let cspString = manifest["content_security_policy"] as? String {
      manifest["content_security_policy"] = Self.enrichCSP(cspString)
      didRewrite = true
    } else {
      // No CSP declared. MV2's effective default is
      // `script-src 'self'; object-src 'self'`, which still blocks
      // the eval our polyfill needs. Pin an explicit one so the
      // synthesised bg page can run the polyfill.
      manifest["content_security_policy"] =
        "script-src 'self' 'wasm-unsafe-eval' 'unsafe-eval'; object-src 'self'"
      didRewrite = true
    }

    // Drop MV3-only top-level keys that emit "unknown key" warnings
    // when the parser walks an MV2 manifest. Conservative list — keep
    // anything the bg might still introspect via chrome.runtime.getManifest()
    // even though MV2 wouldn't enforce it (e.g. optional_host_permissions
    // is fine to leave; declarative_net_request rules are still
    // discoverable to the bg even if they don't auto-apply).
    manifest.removeValue(forKey: "minimum_chrome_version")

    // `commands` entries without `description` parse as
    // `WKWebExtensionErrorDomain` code 6 ("Empty or invalid
    // `description`") even for reserved entries (`_execute_action`,
    // `_execute_browser_action`, `_execute_page_action`) where Chrome
    // treats `description` as optional because the entry is implicitly
    // labeled by the extension's action button. Backfill a non-empty
    // placeholder so the WebKit parser accepts the entry. The value is
    // never surfaced — WebKit owns the UI for reserved commands and
    // `chrome.commands.getAll()` callers receive the same string back
    // without behavioural impact.
    if var commands = manifest["commands"] as? [String: Any] {
      var changed = false
      for (key, raw) in commands {
        guard var entry = raw as? [String: Any] else { continue }
        let desc = (entry["description"] as? String) ?? ""
        if desc.isEmpty {
          entry["description"] = key
          commands[key] = entry
          changed = true
        }
      }
      if changed {
        manifest["commands"] = commands
        didRewrite = true
      }
    }

    // Stub out manifest content_scripts whose `js` / `css` files
    // aren't bundled in the CRX. Bitwarden's manifest references
    // MV2-only files like `content/fido2-page-script-delay-append-mv2.js`
    // that exist in the Firefox MV2 build but not in the Chrome MV3
    // CRX. WebKit's content_script loader emits
    // `WKWebExtensionErrorDomain code=2 — Unable to find ... in the
    // extension's resources`, which surfaces in `errorsDidUpdate`
    // and (more importantly) appears to gate Bitwarden's autofill
    // setup chain — Cmd+Shift+L gets consumed but the inline menu
    // and `chrome.commands.onCommand` autofill never fire. Empty
    // stubs satisfy the loader without changing behavior since
    // there's no script to run; the same paths called dynamically
    // via `chrome.tabs.executeScript` then succeed too (no
    // `Invalid resource` runtime error). The `e05-original` backup
    // path means the next rewrite still sees the un-stubbed CRX
    // and re-applies this pass, so the stubs stay in sync if the
    // manifest content_scripts list ever changes.
    var allStubbed: Set<String> = []
    if let cs = manifest["content_scripts"] as? [[String: Any]] {
      for entry in cs {
        let jsFiles = (entry["js"] as? [String]) ?? []
        let cssFiles = (entry["css"] as? [String]) ?? []
        for path in jsFiles + cssFiles {
          let fileURL = dir.appendingPathComponent(path)
          if !fm.fileExists(atPath: fileURL.path) {
            let parentDir = fileURL.deletingLastPathComponent()
            try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try? Data().write(to: fileURL, options: [.atomic])
            allStubbed.insert(path)
          }
        }
      }
    }

    // Scan background.js for `*-mv2.{js,css,html}` string literals
    // that name resources NOT in the manifest's `content_scripts`
    // and don't exist on disk. Bitwarden's bg has hardcoded
    // `chrome.tabs.executeScript({file: 'content/fido2-page-script-
    // delay-append-mv2.js'})` calls that target the MV2 build's
    // file layout; the MV3 CRX doesn't bundle them. Without stubs,
    // WebKit reports `WKWebExtensionErrorDomain code=2 — Invalid
    // resource` via the errors API and the user sees a persistent
    // entry in View errors even though the call is non-load-bearing
    // (autofill still works because the same flow is wired through
    // other content_scripts). Empty stubs satisfy the loader while
    // preserving the no-op semantics — the script does nothing in
    // either build, since the MV2 `delay-append` shim only matters
    // for Firefox MV2's content_script lifecycle.
    let bgJsURL = dir.appendingPathComponent("background.js")
    if fm.fileExists(atPath: bgJsURL.path),
      let bgSource = try? String(contentsOf: bgJsURL, encoding: .utf8),
      let regex = try? NSRegularExpression(pattern: #"['"]([^'"\s]+-mv2\.(?:js|css|html))['"]"#)
    {
      let range = NSRange(bgSource.startIndex..., in: bgSource)
      regex.enumerateMatches(in: bgSource, range: range) { match, _, _ in
        guard let match = match,
          let r = Range(match.range(at: 1), in: bgSource) else { return }
        let path = String(bgSource[r])
        let fileURL = dir.appendingPathComponent(path)
        if !fm.fileExists(atPath: fileURL.path) {
          let parentDir = fileURL.deletingLastPathComponent()
          try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
          try? Data().write(to: fileURL, options: [.atomic])
          allStubbed.insert(path)
        }
      }
    }

    if !allStubbed.isEmpty {
      logger.info(
        "Stubbed \(allStubbed.count) missing asset(s) at \(dir.lastPathComponent, privacy: .public): \(allStubbed.sorted().joined(separator: ", "), privacy: .public)"
      )
    }

    // Bitwarden inline-menu wrapper: the wrapper iframe
    // (`overlay/menu.html`) lives inside the page web view, not the
    // extension web view, so the controller-level WKUserScript
    // polyfill never reaches it. The wrapper's `handleWindowMessage`
    // accepts `initAutofillInlineMenuButton` /
    // `initAutofillInlineMenuList` only when
    // `event.source === globalThis.parent` *or*
    // `event.origin === extensionOrigin`. WebKit's content_script
    // isolated world appears to break the parent-window identity
    // check (each script world has its own `globalThis.parent`
    // object), so init messages from the page-side wrapper script
    // get rejected and the sub-iframe `src` is never set — the
    // visible symptom is the wrapper iframe sitting empty after
    // input focus. Patch the source to skip both checks for those
    // two init commands; everything else (session-token validated
    // bg-direction routing) is unaffected.
    let menuJSURL = dir.appendingPathComponent("overlay/menu.js")
    if fm.fileExists(atPath: menuJSURL.path),
      var src = try? String(contentsOf: menuJSURL, encoding: .utf8)
    {
      var patches: [String] = []

      // Patch 1: init guard. Without this, init messages hit the
      // (origin || parent) guard and reject because WebKit isolated
      // worlds break the identity check.
      let initGuardOriginal =
        "if ((message.command === \"initAutofillInlineMenuButton\" ||\n"
        + "                    message.command === \"initAutofillInlineMenuList\") &&\n"
        + "                    !this.isMessageFromExtensionOrigin(event) &&\n"
        + "                    !this.isMessageFromParentWindow(event)) {\n"
        + "                    return;\n"
        + "                }"
      let initGuardPatched =
        "/* e05: init guard relaxed — WebKit isolated worlds break parent identity check */\n"
        + "                if (false) { return; }"
      if src.contains(initGuardOriginal) {
        src = src.replacingOccurrences(of: initGuardOriginal, with: initGuardPatched)
        patches.append("init-guard")
      }

      // Patch 2: isForeignWindowMessage — runs *before* the init
      // guard. Its `isMessageFromParentWindow` branch fails under
      // isolated worlds (event.source !== globalThis.parent across
      // worlds) so init messages get rejected here regardless of
      // patch 1. Trust portKey alone; portKey is the bg-issued
      // shared secret, so any message carrying it is from the
      // page-side wrapper or the inline-menu sub-iframe (both of
      // which received the portKey via bg-controlled channels).
      let foreignOriginal =
        "isForeignWindowMessage(event) {\n"
        + "        var _a;\n"
        + "        if (!((_a = event.data) === null || _a === void 0 ? void 0 : _a.portKey)) {\n"
        + "            return true;\n"
        + "        }\n"
        + "        if (this.isMessageFromParentWindow(event)) {\n"
        + "            return false;\n"
        + "        }\n"
        + "        return !this.isMessageFromInlineMenuPageIframe(event);\n"
        + "    }"
      let foreignPatched =
        "isForeignWindowMessage(event) {\n"
        + "        /* e05: trust portKey alone — WebKit isolated worlds break source identity checks */\n"
        + "        var _a;\n"
        + "        return !((_a = event.data) === null || _a === void 0 ? void 0 : _a.portKey);\n"
        + "    }"
      if src.contains(foreignOriginal) {
        src = src.replacingOccurrences(of: foreignOriginal, with: foreignPatched)
        patches.append("foreign-check")
      }

      // Patch 3: isMessageFromParentWindow — used at line ~3414 to
      // route non-init relay messages to the inline-menu sub-iframe.
      // Replace identity check with an origin-based check: any
      // message *not* from the extension origin must have come from
      // the page-side wrapper script (the only other window that
      // can postMessage into us). Sub-iframe→wrapper messages have
      // event.origin === extensionOrigin and fall through to the
      // postMessageToBackground path correctly.
      let parentOriginal =
        "isMessageFromParentWindow(event) {\n"
        + "        return globalThis.parent === event.source;\n"
        + "    }"
      let parentPatched =
        "isMessageFromParentWindow(event) {\n"
        + "        /* e05: origin-based check — WebKit isolated worlds break identity */\n"
        + "        try {\n"
        + "            return event.origin !== this.extensionOrigin && event.origin !== 'null';\n"
        + "        } catch (_) { return false; }\n"
        + "    }"
      if src.contains(parentOriginal) {
        src = src.replacingOccurrences(of: parentOriginal, with: parentPatched)
        patches.append("parent-check")
      }

      // Patch 4: extension protocol allowlist — Bitwarden's
      // `isExtensionUrlWithOrigin` validates that init messages'
      // `iframeUrl` uses an extension URL scheme, but its allowlist
      // only knows `chrome-extension:`, `moz-extension:`, and
      // `safari-web-extension:`. Apple's WKWebExtension serves
      // extension resources at `webkit-extension://`, which falls
      // off the allowlist, so `handleInitInlineMenuIframe` returns
      // before setting `this.inlineMenuPageIframe.src` and the
      // sub-iframe stays blank — the user-visible "wrapper shows
      // up but content never appears" symptom. Add the WebKit
      // scheme; the rest of the validation (origin equality) is
      // unchanged.
      let protoOriginal =
        "const extensionProtocols = new Set([\n"
        + "                \"chrome-extension:\",\n"
        + "                \"moz-extension:\",\n"
        + "                \"safari-web-extension:\",\n"
        + "            ]);"
      let protoPatched =
        "const extensionProtocols = new Set([\n"
        + "                \"chrome-extension:\",\n"
        + "                \"moz-extension:\",\n"
        + "                \"safari-web-extension:\",\n"
        + "                \"webkit-extension:\",\n"
        + "            ]);"
      if src.contains(protoOriginal) {
        src = src.replacingOccurrences(of: protoOriginal, with: protoPatched)
        patches.append("ext-proto")
      }

      if !patches.isEmpty {
        try? Data(src.utf8).write(to: menuJSURL, options: [.atomic])
        logger.info(
          "Patched overlay/menu.js [\(patches.joined(separator: ","))] at \(dir.lastPathComponent, privacy: .public)"
        )
      }

      // Surface partial-match regressions: each patch is idempotent
      // (the original substring goes away after one apply), so the
      // healthy steady states are "all 4 hit on a fresh install" and
      // "0 hit on a re-rewrite of an already-patched dir". Anything
      // in between means Bitwarden shipped a build whose menu.js
      // lost some of the substrings we look for — most likely a
      // minifier change or a code rewrite — and the inline menu
      // will silently break the next time it's exercised. Log the
      // extension version so the user can pin which release first
      // broke the assumptions.
      let allPatches: Set<String> = ["init-guard", "foreign-check", "parent-check", "ext-proto"]
      let appliedSet = Set(patches)
      if !appliedSet.isEmpty, appliedSet != allPatches {
        let missing = allPatches.subtracting(appliedSet).sorted()
        let version = (manifest["version"] as? String) ?? "(unknown)"
        logger.error(
          """
          overlay/menu.js patches partial: applied=\(patches.sorted().joined(separator: ","), privacy: .public) \
          missing=\(missing.joined(separator: ","), privacy: .public) version=\(version, privacy: .public) \
          at \(dir.lastPathComponent, privacy: .public) — Bitwarden source layout may have changed
          """
        )
      }
    }

    // Diagnostic for the wrapper iframe: prepend an inline observer
    // to overlay/menu.html so the next round confirms whether the
    // patched init handler now fires. Inline `<script>` is fine —
    // Bitwarden's overlay pages have no CSP that blocks it. Logs
    // surface via the page web view's console; the e05 console
    // relay also covers extension-origin docs, so the line lands
    // in /tmp/e05.log alongside the bg-shim ones.
    let menuHTMLURL = dir.appendingPathComponent("overlay/menu.html")
    if fm.fileExists(atPath: menuHTMLURL.path),
      var html = try? String(contentsOf: menuHTMLURL, encoding: .utf8),
      !html.contains("__e05_menu_observer__")
    {
      let observer = """
        <script>(function(){window.__e05_menu_observer__=true;\
        try{globalThis.addEventListener('message',function(e){\
        try{var d=e.data;var s={cmd:(d&&typeof d==='object'&&d.command)||'(none)',\
        origin:e.origin,sourceIsParent:e.source===globalThis.parent,\
        hasPortKey:!!(d&&typeof d==='object'&&d.portKey)};\
        console.log('[e05/diag] menu.html msg '+JSON.stringify(s));}catch(_){}}, true);\
        console.log('[e05/diag] menu.html observer installed at '+location.href);}catch(_){}})();</script>
        """
      html = html.replacingOccurrences(
        of: "<head>", with: "<head>\(observer)"
      )
      try? Data(html.utf8).write(to: menuHTMLURL, options: [.atomic])
      logger.info(
        "Injected diagnostic observer into overlay/menu.html at \(dir.lastPathComponent, privacy: .public)"
      )
    }

    // Before stripping `key`, compute the Chrome-style extension ID
    // it would have produced and save it next to the manifest as
    // `_e05_caller_origin`. Native messaging hosts (1Password
    // Browser Helper, Bitwarden Desktop, …) authenticate the caller
    // by chrome-extension://<id>/ and fail with
    // `BrowserVerificationFailed: UnknownBrowser` when handed a
    // beta-channel `allowed_origins[0]` instead of the production
    // ID derived from `key`. Saving the derived ID lets the
    // controller hand the host the correct origin even though the
    // ID is no longer present in the manifest WebKit sees.
    if let keyB64 = manifest["key"] as? String,
      let extID = Self.chromeExtensionID(fromBase64DERKey: keyB64)
    {
      let originURL = "chrome-extension://\(extID)/"
      let originPath = dir.appendingPathComponent("_e05_caller_origin")
      do {
        try Data(originURL.utf8).write(to: originPath, options: [.atomic])
        logger.info(
          "Saved derived caller origin \(originURL, privacy: .public) at \(originPath.lastPathComponent, privacy: .public)"
        )
      } catch {
        logger.error(
          "Failed writing _e05_caller_origin: \(String(describing: error), privacy: .public)"
        )
      }
    }

    // Strip `key`: with `key` present, WKWebExtension derives a
    // Chrome-style stable origin for the popup (and content scripts)
    // from the public key, but the synthesized event-page (the
    // `_e05_bg.html` we wrote next to manifest.json) gets a separate
    // per-load UUID. The two contexts then sit on different
    // `webkit-extension://<uuid>` origins, so popup→bg
    // `chrome.runtime.sendMessage` crosses extension boundaries and
    // is silently dropped. Removing `key` collapses popup, content
    // scripts, and bg onto the same UUID and restores the same-origin
    // invariant Chrome maintains. Observed concretely with 1Password
    // CRX where popup origin `52067801-…` and bg origin `7d1e00c6-…`
    // diverged.
    manifest.removeValue(forKey: "key")

    // Strip `update_url`: WebKit may treat a Chrome Web Store update
    // endpoint as a hint to silently re-fetch, which lands on the
    // same "archive too small" path that the manual store install
    // already trips. The extension was installed once and we manage
    // updates ourselves; nothing inside the bridge benefits from
    // letting the bg / loader contact the store unattended.
    manifest.removeValue(forKey: "update_url")

    manifest["manifest_version"] = 2
    didRewrite = true

    if !fm.fileExists(atPath: backupURL.path) {
      do {
        try original.write(to: backupURL, options: [.atomic])
      } catch {
        throw RewriteError.writeFailed(backupURL, underlying: error)
      }
    }

    let rewritten: Data
    do {
      rewritten = try JSONSerialization.data(
        withJSONObject: manifest,
        options: [.prettyPrinted, .sortedKeys]
      )
    } catch {
      throw RewriteError.writeFailed(manifestURL, underlying: error)
    }
    do {
      try rewritten.write(to: manifestURL, options: [.atomic])
    } catch {
      throw RewriteError.writeFailed(manifestURL, underlying: error)
    }

    if let bg = synthBg {
      let bgURL = dir.appendingPathComponent("_e05_bg.html")
      // type=module preserves ESM imports — 1Password's CRX uses
      // `"type": "module"` in its service_worker entry, so its bg
      // source contains top-level import/export. Loading it as a
      // classic script would throw a SyntaxError at parse time.
      let scriptTag =
        bg.isModule
        ? "<script type=\"module\" src=\"\(bg.script)\"></script>"
        : "<script src=\"\(bg.script)\"></script>"
      do {
        try Data(Self.bgShimSource.utf8).write(to: shimURL, options: [.atomic])
      } catch {
        throw RewriteError.writeFailed(shimURL, underlying: error)
      }
      let html = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <script src="_e05_bg_shim.js"></script>
            \(scriptTag)
          </head>
          <body></body>
        </html>
        """
      do {
        try Data(html.utf8).write(to: bgURL, options: [.atomic])
      } catch {
        throw RewriteError.writeFailed(bgURL, underlying: error)
      }
    }

    logger.info(
      "MV3→MV2 rewrite applied at \(dir.lastPathComponent, privacy: .public) (synth bg: \(synthBg != nil))"
    )
    return didRewrite
  }

  /// Inject `'unsafe-eval'` into a CSP string's `script-src`
  /// directive. Idempotent — returns the input unchanged when the
  /// keyword is already present. The bg-shim's `importScripts`
  /// polyfill calls indirect `eval` to keep the call's blocking
  /// semantics intact (sync XHR fetches the SDK chunk text, then
  /// `(0, eval)(text)` runs it in the global scope), so an MV3 CSP
  /// that omits `'unsafe-eval'` (Bitwarden's
  /// `script-src 'self' 'wasm-unsafe-eval'` is the production
  /// example) silently fails the load with EvalError. Inserting the
  /// keyword right after the `script-src` token keeps the rest of
  /// the directive (host allowlists, hashes) intact.
  fileprivate static func enrichCSP(_ csp: String) -> String {
    var result = csp
    // Inject `'unsafe-eval'` into script-src so the bg-shim's
    // importScripts polyfill (sync XHR + indirect eval) is allowed.
    if !result.contains("'unsafe-eval'") {
      if result.contains("script-src") {
        result = result.replacingOccurrences(
          of: "script-src",
          with: "script-src 'unsafe-eval'"
        )
      } else {
        result = "script-src 'self' 'unsafe-eval'; \(result)"
      }
    }
    // Extension manifests with `default-src 'none'` and no
    // object-src silently block `<object data="...">` embeds.
    // Inject a minimal `object-src 'self'` so embeds from the
    // extension's own origin load. Note: this directive applies
    // to every extension we rewrite, so the directive stays
    // intentionally narrow — extensions that need `data:` (such
    // as 1Password's popup inline SVG) get that allowance from a
    // per-extension patch, not from this broad shim.
    if !result.contains("object-src") {
      result = "\(result); object-src 'self'"
    }
    return result
  }

  /// Source for `_e05_bg_shim.js`. Loaded as a classic blocking
  /// script *before* the rewritten ESM bg so polyfills are in place
  /// by the time `background.js` evaluates. Has to live in the bg
  /// *document* (not a controller-level WKUserScript) — userContent
  /// injection of the same stubs propagates the mutated chrome
  /// shape to the popup web view at popover-open time and wedges
  /// WebKit's render path so the toolbar click stops opening the
  /// popup at all (verified by per-section bisect). Has to be an
  /// *external file* (not an inline `<script>`) — restrictive CSPs
  /// (1Password's `script-src 'self' 'wasm-unsafe-eval'`) silently
  /// block inline scripts and the shim never runs.
  fileprivate static let bgShimSource: String = """
    (function() {
      if (typeof chrome === 'undefined') return;
      function stubEvent() {
        return {
          addListener: function() {},
          removeListener: function() {},
          hasListener: function() { return false; },
          hasListeners: function() { return false; },
        };
      }
      // chrome.scripting.ExecutionWorld: MV3-only enum some bg
      // code references unconditionally (1Password's
      // `chrome.scripting.ExecutionWorld.MAIN`). Apple's
      // chrome.scripting omits the constant set, so the access
      // throws TypeError at module load and aborts bg init.
      if (chrome.scripting && !chrome.scripting.ExecutionWorld) {
        chrome.scripting.ExecutionWorld = {
          ISOLATED: 'ISOLATED',
          MAIN: 'MAIN',
        };
        console.log('[e05/bg-shim] chrome.scripting.ExecutionWorld stubbed at', location.href);
      }
      // chrome.webNavigation.onCreatedNavigationTarget: see the
      // matching block in ExtensionController.chromeMV3PolyfillScript
      // for the full rationale. Apple's WKWebExtension reinitialises
      // chrome.webNavigation between parse-time stub install and the
      // deferred module script's read, so we install a `get` trap on
      // chrome.webNavigation here too in case the user-script-level
      // polyfill was skipped (env-disabled / R&D mode).
      if (chrome.webNavigation) {
        var wnAlreadyPatched = !!(chrome.webNavigation.onCreatedNavigationTarget
          && chrome.webNavigation.onCreatedNavigationTarget.addListener);
        if (!wnAlreadyPatched) {
          var wnStubEv = stubEvent();
          var wnMakeProxy = function(target) {
            return new Proxy(target, {
              get: function(t, p) {
                if (p === 'onCreatedNavigationTarget') return wnStubEv;
                var v = Reflect.get(t, p);
                return (typeof v === 'function') ? v.bind(t) : v;
              },
            });
          };
          var wnInstalled = false;
          try {
            var wnOrig = chrome.webNavigation;
            Object.defineProperty(chrome, 'webNavigation', {
              get: function() { return wnMakeProxy(wnOrig); },
              configurable: true, enumerable: true,
            });
            wnInstalled = !!(chrome.webNavigation
              && chrome.webNavigation.onCreatedNavigationTarget
              && chrome.webNavigation.onCreatedNavigationTarget.addListener);
          } catch (e) {
            console.warn('[e05/bg-shim] chrome.webNavigation getter define failed:', e);
          }
          if (!wnInstalled) {
            try {
              var chromeOrig = chrome;
              var chromeWrap = new Proxy(chromeOrig, {
                get: function(t, p) {
                  if (p === 'webNavigation') {
                    var w = Reflect.get(t, p);
                    return w ? wnMakeProxy(w) : w;
                  }
                  return Reflect.get(t, p);
                },
              });
              Object.defineProperty(globalThis, 'chrome', {
                value: chromeWrap, writable: true, configurable: true,
              });
              wnInstalled = !!(globalThis.chrome.webNavigation
                && globalThis.chrome.webNavigation.onCreatedNavigationTarget);
            } catch (e) {
              console.warn('[e05/bg-shim] globalThis.chrome proxy failed:', e);
            }
          }
          console.log('[e05/bg-shim] chrome.webNavigation.onCreatedNavigationTarget patched at', location.href,
            'installed=', wnInstalled);
        }
      }
      if (!chrome.notifications) {
        try {
          chrome.notifications = {
            create: function(id, opts, cb) {
              var nid = (typeof id === 'string') ? id : 'e05-stub-' + Date.now();
              if (typeof cb === 'function') cb(nid);
              return Promise.resolve(nid);
            },
            clear: function(_id, cb) {
              if (typeof cb === 'function') cb(false);
              return Promise.resolve(false);
            },
            update: function(_id, _opts, cb) {
              if (typeof cb === 'function') cb(false);
              return Promise.resolve(false);
            },
            getAll: function(cb) {
              if (typeof cb === 'function') cb({});
              return Promise.resolve({});
            },
            getPermissionLevel: function(cb) {
              if (typeof cb === 'function') cb('granted');
              return Promise.resolve('granted');
            },
            onClicked: stubEvent(),
            onClosed: stubEvent(),
            onButtonClicked: stubEvent(),
            onPermissionLevelChanged: stubEvent(),
            onShowSettings: stubEvent(),
            PermissionLevel: { GRANTED: 'granted', DENIED: 'denied' },
            TemplateType: { BASIC: 'basic', IMAGE: 'image', LIST: 'list', PROGRESS: 'progress' },
          };
          console.log('[e05/bg-shim] chrome.notifications stubbed at', location.href);
        } catch (e) { console.warn('[e05/bg-shim] notifications inject failed:', e); }
      }
      // Pin chrome.action / chrome.browserAction to the
      // default_popup path for any extension that declares one.
      // WebKit's WKWebExtension routes the toolbar click into the
      // onClicked listener the moment one exists, *and* honours
      // `setPopup({popup: ""})` / `disable(...)` to suppress the
      // popup entirely. 1Password's bg does all three at various
      // points — attaches a click listener, calls
      // `setPopup({popup: ""})` after the desktop-app handshake,
      // disables the action while locking — so on WebKit the
      // toolbar icon goes silent. We intercept all three from the
      // bg-document scope so the mutation stays local to bg JS and
      // never reaches the popup web view's chrome.action.
      try {
        var mf = (chrome.runtime && chrome.runtime.getManifest)
          ? chrome.runtime.getManifest() : null;
        var hasDefaultPopup = mf && (
          (mf.action && mf.action.default_popup) ||
          (mf.browser_action && mf.browser_action.default_popup)
        );
        if (hasDefaultPopup) {
          var defaultPopup =
            (mf.action && mf.action.default_popup) ||
            (mf.browser_action && mf.browser_action.default_popup);
          ['action', 'browserAction'].forEach(function(ns) {
            var api = chrome[ns];
            if (!api) return;
            if (api.onClicked
                && typeof api.onClicked.addListener === 'function') {
              api.onClicked.addListener = function() {};
              console.log('[e05/bg-shim] chrome.' + ns + '.onClicked.addListener swallowed at', location.href);
            }
            if (typeof api.setPopup === 'function') {
              var origSetPopup = api.setPopup.bind(api);
              api.setPopup = function(details, cb) {
                if (details && details.popup === '') {
                  try {
                    origSetPopup({popup: defaultPopup}, function() {});
                  } catch (_) {}
                  if (typeof cb === 'function') cb();
                  return Promise.resolve();
                }
                return origSetPopup(details, cb);
              };
            }
            if (typeof api.disable === 'function') {
              api.disable = function(_id, cb) {
                console.log('[e05/bg-shim] swallowed chrome.' + ns + '.disable at', location.href);
                if (typeof cb === 'function') cb();
                return Promise.resolve();
              };
            }
          });
          // Bounded re-arm: 10 passes spread over a second so any
          // path we did not intercept (state-machine promise
          // chains that resolve on their own micro-queue) also
          // lands on default_popup before the user can click.
          if (defaultPopup) {
            var rearm = function() {
              ['action', 'browserAction'].forEach(function(ns) {
                var api = chrome[ns];
                if (api && typeof api.setPopup === 'function') {
                  try { api.setPopup({popup: defaultPopup}); } catch (_) {}
                }
              });
            };
            var passes = 10;
            var loop = function() {
              rearm();
              if (--passes > 0) setTimeout(loop, 100);
            };
            Promise.resolve().then(loop);
            console.log('[e05/bg-shim] default_popup re-arm scheduled (' + defaultPopup + ', 10 passes) at', location.href);
          }
        }
      } catch (e) { console.warn('[e05/bg-shim] action neutralize failed:', e); }
      // Polyfill `importScripts` in the synthesised bg page.
      // Bitwarden MV3 background.js loads its WASM SDK via
      // `importScripts()` (a WorkerGlobalScope helper), which is
      // undefined inside a regular HTML document. The MV3→MV2
      // rewriter drops Bitwarden's bg into a normal page, so the
      // access throws ReferenceError and the SDK never loads —
      // biometric replies arrive but can't decrypt ciphers. Sync
      // XHR + indirect-eval keeps the call's blocking semantics
      // intact, which Bitwarden's loader assumes when resolving
      // the SDK module graph.
      // The outer try/catch wraps the *install* only. The function
      // body (XHR + eval) runs later when bg JS calls importScripts;
      // any error inside it propagates back to the caller, which is
      // what we want — silent fallback would leave the SDK loader's
      // Promise resolved with undefined and surface as a confusing
      // "cipher decrypt failed" much later. Use console.error for
      // install failures so a CSP misconfiguration shows up loudly
      // instead of hiding behind console.warn noise.
      try {
        if (typeof globalThis.importScripts === 'undefined') {
          globalThis.importScripts = function() {
            for (var i = 0; i < arguments.length; i++) {
              var url = String(arguments[i]);
              var xhr = new XMLHttpRequest();
              xhr.open('GET', url, false);
              xhr.send();
              if (xhr.status < 200 || xhr.status >= 300) {
                throw new Error('importScripts polyfill HTTP ' + xhr.status + ' for ' + url);
              }
              (0, eval)(xhr.responseText + '\\n//# sourceURL=' + url);
            }
          };
          console.log('[e05/bg-shim] importScripts polyfilled at', location.href);
        }
      } catch (e) { console.error('[e05/bg-shim] importScripts polyfill install failed:', e); }
      // Polyfill `chrome.windows.create` so Bitwarden's Cmd+Shift+L
      // autofill (and "open in popup" cipher pickers) don't bail on
      // "Invalid call to windows.create(). It is not implemented."
      // WebKit's WKWebExtension does not bridge chrome.windows.create
      // at all, only chrome.tabs.create. Falling back to a tab keeps
      // the cipher picker / autofill flow alive — losing the popup-
      // window framing is acceptable; losing autofill is not.
      try {
        if (chrome.windows && typeof chrome.windows.create === 'function') {
          var origWinCreate = chrome.windows.create.bind(chrome.windows);
          chrome.windows.create = function(opts, cb) {
            opts = opts || {};
            var fallbackToTab = function() {
              return new Promise(function(resolve) {
                chrome.tabs.create(
                  { url: opts.url, active: opts.focused !== false },
                  function(tab) {
                    var fake = {
                      id: -1,
                      focused: opts.focused !== false,
                      incognito: !!opts.incognito,
                      alwaysOnTop: false,
                      tabs: tab ? [tab] : [],
                    };
                    if (typeof cb === 'function') cb(fake);
                    resolve(fake);
                  }
                );
              });
            };
            try {
              var p = origWinCreate(opts, function(win) {
                if (chrome.runtime.lastError) {
                  console.log('[e05/bg-shim] windows.create unavailable, falling back to tabs.create:',
                    chrome.runtime.lastError.message);
                  fallbackToTab();
                  return;
                }
                if (typeof cb === 'function') cb(win);
              });
              if (p && typeof p.catch === 'function') {
                return p.catch(function() { return fallbackToTab(); });
              }
              return p;
            } catch (e) {
              console.log('[e05/bg-shim] windows.create threw, falling back to tabs.create:', e);
              return fallbackToTab();
            }
          };
          console.log('[e05/bg-shim] chrome.windows.create wrapped at', location.href);
        }
      } catch (e) { console.warn('[e05/bg-shim] windows.create wrap failed:', e); }
      // R4-2 diagnostic: log every chrome.runtime.onConnect plus
      // every port.postMessage going TO the connected client. This
      // surfaces (a) what `port.sender` looks like when sub-frame
      // (iframe) content scripts connect (Bitwarden's
      // OverlayBackground bails silently on `senderHasValidTab`),
      // and (b) whether bg actually sends data on inline-menu
      // ports. Bitwarden's wrapper iframe (overlay/menu.html)
      // populates its body only after receiving an
      // `initAutofillInlineMenuButton` / `initAutofillInlineMenuList`
      // postMessage that carries the sub-iframe URL — if bg never
      // posts that message, the wrapper stays empty even when
      // ports connect cleanly. Wrap addListener so the original
      // handler still fires — diagnostic-only, no behavior change.
      try {
        if (chrome.runtime && chrome.runtime.onConnect
            && typeof chrome.runtime.onConnect.addListener === 'function') {
          var origAdd = chrome.runtime.onConnect.addListener.bind(chrome.runtime.onConnect);
          chrome.runtime.onConnect.addListener = function(listener) {
            var wrapped = function(port) {
              try {
                var s = port && port.sender;
                var summary = {
                  portName: port && port.name,
                  hasSender: !!s,
                  hasTab: !!(s && s.tab),
                  tabId: s && s.tab && s.tab.id,
                  frameId: s && s.frameId,
                  url: s && s.url,
                  origin: s && s.origin,
                  senderId: s && s.id,
                };
                console.log('[e05/bg-shim] onConnect port=' + JSON.stringify(summary));
                if (port && typeof port.postMessage === 'function'
                    && /^autofill-inline-menu-/.test(port.name || '')) {
                  var origPost = port.postMessage.bind(port);
                  port.postMessage = function(msg) {
                    try {
                      var cmd = (msg && typeof msg === 'object') ? (msg.command || '(no-command)') : String(typeof msg);
                      var keys = (msg && typeof msg === 'object') ? Object.keys(msg).slice(0, 8).join(',') : '';
                      console.log('[e05/bg-shim] bg→port[' + port.name + '] cmd=' + cmd + ' keys=' + keys);
                    } catch (_) {}
                    return origPost(msg);
                  };
                }
              } catch (e) {
                console.warn('[e05/bg-shim] onConnect introspect failed:', e);
              }
              return listener(port);
            };
            return origAdd(wrapped);
          };
          console.log('[e05/bg-shim] chrome.runtime.onConnect wrapped for sender + postMessage diagnostics at', location.href);
        }
      } catch (e) { console.warn('[e05/bg-shim] onConnect wrap failed:', e); }
      // Diagnose Cmd+Shift+L silently dropping autofill: log every
      // chrome.commands.onCommand fire so we can tell whether the
      // host's NSEvent monitor reaches the listener at all, what
      // command name was dispatched, and what tab WebKit attached.
      // If the listener never fires after `[e05/ext] performCommand
      // consumed`, the gap is between WKWebExtensionContext and the
      // bg's command dispatch (likely manifest commands not parsed,
      // or listener registered after the event fired).
      try {
        if (chrome.commands && chrome.commands.onCommand
            && typeof chrome.commands.onCommand.addListener === 'function') {
          var origCmdAdd = chrome.commands.onCommand.addListener.bind(chrome.commands.onCommand);
          chrome.commands.onCommand.addListener = function(listener) {
            var wrapped = function(command, tab) {
              try {
                console.log('[e05/bg-shim] commands.onCommand fired: ' + command
                  + ' tab=' + (tab ? JSON.stringify({id: tab.id, url: tab.url}) : 'null'));
              } catch (_) {}
              return listener(command, tab);
            };
            return origCmdAdd(wrapped);
          };
          console.log('[e05/bg-shim] chrome.commands.onCommand wrapped for diagnostics at', location.href);
        }
      } catch (e) { console.warn('[e05/bg-shim] commands wrap failed:', e); }
      // chrome.privacy: Apple's WKWebExtension does not bridge the
      // API at all, but 1Password's bg unconditionally touches
      // `chrome.privacy.services.{passwordSavingEnabled,
      // autofillEnabled, autofillAddressEnabled,
      // autofillCreditCardEnabled}` during init to negotiate
      // password-saving / autofill ownership with the host browser.
      // Without a stub the first property access throws TypeError,
      // the rejection bubbles up unhandled, bg init halts mid-way,
      // and the popup hangs forever waiting for a config message
      // that bg never gets around to sending. Default each value to
      // false with `controllable_by_this_extension` so callers see
      // "browser is not saving passwords / autofilling — feel free
      // to take over"; set/clear are no-ops since there is no real
      // preference store to mutate.
      try {
        if (!chrome.privacy) {
          var makeChromeSetting = function(defaultValue) {
            return {
              get: function(_details, cb) {
                var resp = {
                  value: defaultValue,
                  levelOfControl: 'controllable_by_this_extension',
                };
                if (typeof cb === 'function') cb(resp);
                return Promise.resolve(resp);
              },
              set: function(_details, cb) {
                if (typeof cb === 'function') cb();
                return Promise.resolve();
              },
              clear: function(_details, cb) {
                if (typeof cb === 'function') cb();
                return Promise.resolve();
              },
              onChange: stubEvent(),
            };
          };
          chrome.privacy = {
            network: {},
            services: {
              passwordSavingEnabled: makeChromeSetting(false),
              autofillEnabled: makeChromeSetting(false),
              autofillAddressEnabled: makeChromeSetting(false),
              autofillCreditCardEnabled: makeChromeSetting(false),
            },
            websites: {},
          };
          console.log('[e05/bg-shim] chrome.privacy stubbed at', location.href);
        }
      } catch (e) { console.warn('[e05/bg-shim] chrome.privacy stub failed:', e); }
      // chrome.tabs.remove: Apple WKWebExtension does not implement
      // closing a tab via this entry point. 1Password's bg calls
      // it once the migration / welcome tab work is done; the
      // "not implemented" rejection then surfaces as a noisy
      // unhandled-rejection log line. Match the specific error
      // shape so unrelated future failures (permission denied,
      // tab does not exist, …) keep propagating; log every
      // swallow at debug so a regression that pivots root cause
      // is still visible in a grep.
      try {
        if (chrome.tabs && typeof chrome.tabs.remove === 'function') {
          var origTabsRemove = chrome.tabs.remove.bind(chrome.tabs);
          var swallowNotImpl = function(e) {
            var msg = (e && e.message) || String(e);
            if (msg.indexOf('not implemented') >= 0
                || msg.indexOf('Invalid call to tabs.remove') >= 0) {
              console.debug('[e05/bg-shim] tabs.remove swallowed:', msg);
              return undefined;
            }
            throw e;
          };
          chrome.tabs.remove = function(tabIds, cb) {
            try {
              var p = origTabsRemove(tabIds, cb);
              if (p && typeof p.catch === 'function') {
                return p.catch(function(e) {
                  swallowNotImpl(e);
                  if (typeof cb === 'function') cb();
                });
              }
              return p;
            } catch (e) {
              swallowNotImpl(e);
              if (typeof cb === 'function') cb();
              return Promise.resolve();
            }
          };
          console.log('[e05/bg-shim] chrome.tabs.remove wrapped at', location.href);
        }
      } catch (e) { console.warn('[e05/bg-shim] tabs.remove wrap failed:', e); }
      // chrome.action.openPopup: WebKit rejects the call when the
      // popover is already on-screen ("Another popup is already
      // open"). 1Password calls it again after vault unlock to
      // refresh popup content; the redundant call is a no-op when
      // a popup already exists, so swallow that specific message.
      try {
        ['action', 'browserAction'].forEach(function(ns) {
          var api = chrome[ns];
          if (!api || typeof api.openPopup !== 'function') return;
          var origOpen = api.openPopup.bind(api);
          var swallowAlreadyOpen = function(e) {
            var msg = (e && e.message) || String(e);
            if (msg.indexOf('Another popup is already open') >= 0) {
              console.debug('[e05/bg-shim] action.openPopup swallowed:', msg);
              return undefined;
            }
            throw e;
          };
          api.openPopup = function(opts, cb) {
            try {
              var p = origOpen(opts, cb);
              if (p && typeof p.catch === 'function') {
                return p.catch(function(e) {
                  swallowAlreadyOpen(e);
                  if (typeof cb === 'function') cb();
                });
              }
              return p;
            } catch (e) {
              swallowAlreadyOpen(e);
              if (typeof cb === 'function') cb();
              return Promise.resolve();
            }
          };
        });
      } catch (e) { console.warn('[e05/bg-shim] action.openPopup wrap failed:', e); }
      // chrome.contextMenus.update: WebKit throws "Menu item not
      // found" when 1Password updates an entry that has not been
      // created (a race during init where the update fires before
      // create). The error is non-fatal — just swallow that one
      // shape so it stops surfacing as an unhandled-rejection.
      try {
        if (chrome.contextMenus && typeof chrome.contextMenus.update === 'function') {
          var origCmUpdate = chrome.contextMenus.update.bind(chrome.contextMenus);
          var swallowNotFound = function(e) {
            var msg = (e && e.message) || String(e);
            if (msg.indexOf('Menu item not found') >= 0
                || msg.indexOf('Invalid call to menus.update') >= 0) {
              console.debug('[e05/bg-shim] contextMenus.update swallowed:', msg);
              return undefined;
            }
            throw e;
          };
          chrome.contextMenus.update = function(id, props, cb) {
            try {
              var p = origCmUpdate(id, props, cb);
              if (p && typeof p.catch === 'function') {
                return p.catch(function(e) {
                  swallowNotFound(e);
                  if (typeof cb === 'function') cb();
                });
              }
              return p;
            } catch (e) {
              swallowNotFound(e);
              if (typeof cb === 'function') cb();
              return Promise.resolve();
            }
          };
          console.log('[e05/bg-shim] chrome.contextMenus.update wrapped at', location.href);
        }
      } catch (e) { console.warn('[e05/bg-shim] contextMenus.update wrap failed:', e); }
      // chrome.tabs.create: 1Password (and likely other Chrome-first
      // extensions) reopen their first-run migration / welcome pages
      // on every bg init because the in-extension storage flag they
      // use to gate the redirect does not persist the same way as in
      // Chrome. The user-visible result is two extension tabs
      // sprouting on every e05 launch. Suppress only calls that
      // target an extension's own `/page/migration` or
      // `/page/welcome` route — anything else (including extension
      // settings pages with a different fragment) passes through.
      try {
        if (chrome.tabs && typeof chrome.tabs.create === 'function') {
          var origTabsCreate = chrome.tabs.create.bind(chrome.tabs);
          chrome.tabs.create = function(opts, cb) {
            var url = (opts && opts.url) || '';
            var isExtPage = url.indexOf('webkit-extension://') === 0
              || url.indexOf('chrome-extension://') === 0;
            var isOnboarding = url.indexOf('/page/migration') >= 0
              || url.indexOf('/page/welcome') >= 0;
            if (isExtPage && isOnboarding) {
              console.log('[e05/bg-shim] tabs.create onboarding suppressed:', url);
              if (typeof cb === 'function') cb({});
              return Promise.resolve({});
            }
            return origTabsCreate(opts, cb);
          };
          console.log('[e05/bg-shim] chrome.tabs.create onboarding suppressor wrapped at', location.href);
        }
      } catch (e) { console.warn('[e05/bg-shim] tabs.create suppressor failed:', e); }
    })();
    """
}
