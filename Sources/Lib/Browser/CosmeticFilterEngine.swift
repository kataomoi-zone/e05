import AppKit
import Foundation
import WebKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "CosmeticFilter")

/// Parsed representation of a single ABP cosmetic line. The parser
/// recognises the three markers this engine cares about:
/// `##` hide, `#@#` unhide, `#?#` procedural hide. Other AdGuard / uBO
/// extended markers (`#$#`, `#%#`, `#$?#`, `%%`, `$$`) are rejected at
/// parse time because they require a runtime that Safari / WebKit does
/// not ship (scriptlets, response-body rewriting, extended CSS style).
public enum ABPCosmeticParser {
  public struct ParsedRule: Equatable, Sendable {
    public enum Kind: Sendable { case hide, unhide }
    public let kind: Kind
    /// Positive hostname tokens. Empty array = generic rule.
    public let domains: [String]
    /// Hostname tokens with a leading `~` stripped. Exclusions from
    /// an otherwise generic rule or from the positive set.
    public let excludedDomains: [String]
    public let selector: String
    /// True for `#?#` lines — they contain at least one procedural
    /// operator such as `:has-text()` or `:upward(...)` and have
    /// to be evaluated by the content-script runtime rather than
    /// applied as a plain CSS selector.
    public let isProcedural: Bool
  }

  /// Markers that disqualify a line before we commit to the cosmetic
  /// path. Checked in descending length order so `#@$#` takes
  /// precedence over `#$#` and doesn't get mistaken for `##`.
  private static let unsupportedMarkers = [
    "#@$?#", "#$?#",  // AdGuard extended CSS + style
    "#@$#", "#$#",  // AdGuard style / scriptlet
    "#@%#", "#%#",  // AdGuard JS rule
    "%%",  // AdGuard extended CSS prefix
  ]

  /// Parse a single filterlist line into a cosmetic rule. Returns nil
  /// for comments, blanks, network rules, and any cosmetic variant
  /// this engine does not support.
  public static func parseLine(_ raw: String) -> ParsedRule? {
    let line = raw.trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else {
      return nil
    }

    for marker in unsupportedMarkers where line.contains(marker) {
      return nil
    }

    // Marker probe order: exceptions before hides, procedural before
    // plain, so `#@#` does not swallow `#@?#`'s body and `#?#` does
    // not parse as `##` + leading `?`.
    if let result = detect(line: line, marker: "#@?#", kind: .unhide, procedural: true) {
      return result
    }
    if let result = detect(line: line, marker: "#?#", kind: .hide, procedural: true) {
      return result
    }
    if let result = detect(line: line, marker: "#@#", kind: .unhide, procedural: false) {
      return result
    }
    if let result = detect(line: line, marker: "##", kind: .hide, procedural: false) {
      return result
    }
    return nil
  }

  public static func parseAll(_ text: String) -> [ParsedRule] {
    var out: [ParsedRule] = []
    text.enumerateLines { line, _ in
      if let rule = parseLine(line) {
        out.append(rule)
      }
    }
    return out
  }

  private static func detect(
    line: String,
    marker: String,
    kind: ParsedRule.Kind,
    procedural: Bool
  ) -> ParsedRule? {
    guard let range = line.range(of: marker) else { return nil }
    let prefix = String(line[..<range.lowerBound])
    let selector = String(line[range.upperBound...])
      .trimmingCharacters(in: .whitespaces)
    guard !selector.isEmpty else { return nil }

    // Refuse surface shapes that are cosmetic-adjacent but require
    // runtime we do not have: scriptlets (`+js(...)`), HTML filters
    // (`^script...`), and AdGuard's inline `:style(...)` applicator.
    if selector.hasPrefix("+js(") { return nil }
    if selector.hasPrefix("^") { return nil }
    if selector.contains(":style(") { return nil }

    var domains: [String] = []
    var excluded: [String] = []
    for token in prefix.split(separator: ",") {
      let t = token.trimmingCharacters(in: .whitespaces)
      guard !t.isEmpty else { continue }
      if t.hasPrefix("~") {
        let dom = String(t.dropFirst()).lowercased()
        if !dom.isEmpty { excluded.append(dom) }
      } else {
        domains.append(t.lowercased())
      }
    }

    return ParsedRule(
      kind: kind,
      domains: domains,
      excludedDomains: excluded,
      selector: selector,
      isProcedural: procedural
    )
  }
}

/// Index of cosmetic rules built from a list of ``ABPCosmeticParser.ParsedRule``.
/// The structure mirrors Brave `adblock-rust`'s ``CosmeticFilterCache``:
/// seven buckets that separate generic from hostname-scoped and split
/// class-first / id-first selectors into simple (the full selector is
/// `.className`) vs complex (the class is a qualifier inside a larger
/// selector).
///
/// The runtime queries this in two stages:
/// 1. `queryHostname(_:)` at page commit returns hostname-scoped hides,
///    the global misc bucket, and procedural filter bodies (the latter
///    are forwarded unchanged for the content script's procedural
///    runtime to evaluate).
/// 2. `queryClassesAndIds(hostname:classes:ids:)` on each MutationObserver
///    batch looks up the newly observed class / id names against the
///    simple sets and complex maps, returning the CSS to inject.
public struct CosmeticIndex: Sendable {
  /// Generic rules whose selector is exactly `.className`.
  public internal(set) var simpleClassRules: Set<String> = []
  /// Generic rules where `className` is a qualifier inside a larger
  /// selector — dictionary from class name to the full selector list.
  public internal(set) var complexClassRules: [String: [String]] = [:]
  public internal(set) var simpleIdRules: Set<String> = []
  public internal(set) var complexIdRules: [String: [String]] = [:]
  /// Generic rules whose selector starts with neither `.class` nor
  /// `#id` (tag, attribute, sibling combinator at the root, etc.).
  /// Always injected eagerly at page commit — there is no class/id
  /// key to defer the lookup on.
  public internal(set) var miscGenericSelectors: Set<String> = []
  /// Hostname-scoped non-procedural hides. Key is the exact hostname
  /// token as it appeared in the filter (e.g. `example.com`).
  public internal(set) var hostnameHide: [String: [String]] = [:]
  /// Hostname-scoped `#@#` exceptions. Selectors in this bucket are
  /// subtracted from the hide output at query time.
  public internal(set) var hostnameUnhide: [String: [String]] = [:]
  /// Hostname-scoped `#?#` procedural filter bodies. Forwarded to JS
  /// untouched; the content-script procedural runtime parses and
  /// evaluates them against the live DOM.
  public internal(set) var hostnameProcedural: [String: [String]] = [:]
  /// Generic `#?#` procedural bodies applied on every page.
  public internal(set) var genericProcedural: Set<String> = []

  public init() {}

  public mutating func add(_ rule: ABPCosmeticParser.ParsedRule) {
    // Defensive gate: a valid CSS selector cannot contain `{` or `}`
    // at the top level. The filter text itself is fetched over HTTPS,
    // but the on-disk cache under `AdBlocker.cacheRoot` is user-
    // writable; reject any selector that could escape the CSS rule
    // boundary before it reaches `document.adoptedStyleSheets`.
    if rule.selector.contains("{") || rule.selector.contains("}") {
      return
    }
    // `rule.excludedDomains` (e.g. `example.com,~sub.example.com##.ad`)
    // is parsed but currently ignored. The hide stays active on every
    // positive domain; implementing "positive minus excluded" requires
    // either materialising the difference at index-build time or a
    // second lookup at query time, and is deferred to the procedural
    // runtime follow-up.
    let isGeneric = rule.domains.isEmpty
    if rule.isProcedural {
      // Procedural unhide rules (`#@?#selector`) are rare and
      // dropping them is safe: without a matching procedural hide
      // there is nothing to cancel, and with one the worst case
      // is leaving a rare exception un-applied.
      if rule.kind == .unhide { return }
      if isGeneric {
        genericProcedural.insert(rule.selector)
      } else {
        for domain in rule.domains {
          hostnameProcedural[domain, default: []].append(rule.selector)
        }
      }
      return
    }

    switch rule.kind {
    case .hide:
      if isGeneric {
        classifyGeneric(rule.selector)
      } else {
        for domain in rule.domains {
          hostnameHide[domain, default: []].append(rule.selector)
        }
      }
    case .unhide:
      // Generic unhide (`~domain##selector` with no positive
      // domain) is not implemented. It is rare in the shipped
      // filterlists and would need either a materialised
      // "positive minus excluded" set at index-build time, or a
      // second lookup at query time; neither is justified by
      // observed filter traffic.
      guard !isGeneric else { return }
      for domain in rule.domains {
        hostnameUnhide[domain, default: []].append(rule.selector)
      }
    }
  }

  /// Classify a generic selector into the simple/complex/misc bucket.
  /// The heuristic looks at the leftmost `.class` or `#id` token: if
  /// the whole selector is exactly that token it is "simple"; if the
  /// token is followed by any combinator / qualifier it is "complex"
  /// and keyed by the token so a MutationObserver sighting of that
  /// class / id can pull the full selector back out.
  private mutating func classifyGeneric(_ selector: String) {
    if let (name, isComplex) = Self.extractHead(selector, prefix: ".") {
      if isComplex {
        complexClassRules[name, default: []].append(selector)
      } else {
        simpleClassRules.insert(name)
      }
      return
    }
    if let (name, isComplex) = Self.extractHead(selector, prefix: "#") {
      if isComplex {
        complexIdRules[name, default: []].append(selector)
      } else {
        simpleIdRules.insert(name)
      }
      return
    }
    miscGenericSelectors.insert(selector)
  }

  /// Characters that terminate a CSS identifier. Hitting any of these
  /// after the leading `.` or `#` means the token is a qualifier in a
  /// larger selector, so the rule goes in the complex bucket.
  private static let identifierBreakers: Set<Character> = [
    " ", "\t", ".", "#", ":", "[", ",", ">", "+", "~", "*",
  ]

  /// Given a selector and a leading marker (`.` or `#`), return the
  /// identifier immediately after the marker plus a flag marking
  /// whether the identifier continues into further selector syntax.
  static func extractHead(_ selector: String, prefix: String) -> (String, Bool)? {
    guard selector.hasPrefix(prefix) else { return nil }
    let tail = selector.dropFirst(prefix.count)
    var end = tail.startIndex
    while end < tail.endIndex {
      let c = tail[end]
      if identifierBreakers.contains(c) { break }
      end = tail.index(after: end)
    }
    let name = String(tail[..<end])
    guard Self.isValidIdentifier(name) else { return nil }
    let isComplex = end < tail.endIndex
    return (name, isComplex)
  }

  private static func isValidIdentifier(_ s: String) -> Bool {
    guard let first = s.first else { return false }
    guard first.isLetter || first == "_" || first == "-" else { return false }
    for c in s.dropFirst() {
      guard c.isLetter || c.isNumber || c == "_" || c == "-" else {
        return false
      }
    }
    return true
  }

  /// Response for the page-commit-time hostname lookup. `misc` is
  /// the static set of generic selectors that apply regardless of
  /// class / id matches; callers inject these immediately alongside
  /// the hostname-specific hides.
  public struct HostnameQueryResult: Encodable, Sendable {
    public let hostnameHide: [String]
    public let misc: [String]
    public let procedural: [String]
  }

  /// Look up every hide rule that should apply at the given hostname,
  /// subtract its matching `#@#` exceptions, and bundle the global
  /// misc generics + procedural bodies in one round-trip so the
  /// content script only needs a single IPC at page commit.
  public func queryHostname(_ hostname: String) -> HostnameQueryResult {
    let parents = Self.parentHostnames(hostname)
    var hide: [String] = []
    var procedural: [String] = []
    for parent in parents {
      if let list = hostnameHide[parent] { hide.append(contentsOf: list) }
      if let list = hostnameProcedural[parent] {
        procedural.append(contentsOf: list)
      }
    }
    var unhide: Set<String> = []
    for parent in parents {
      if let list = hostnameUnhide[parent] { unhide.formUnion(list) }
    }
    hide = hide.filter { !unhide.contains($0) }
    procedural.append(contentsOf: genericProcedural)
    return HostnameQueryResult(
      hostnameHide: hide,
      misc: Array(miscGenericSelectors),
      procedural: procedural
    )
  }

  /// Look up generic class / id hide selectors for names observed in
  /// the live DOM. Simple rules contribute `.name` / `#name` directly,
  /// complex rules contribute their full selector strings; both are
  /// filtered against the hostname's `#@#` exceptions before return.
  public func queryClassesAndIds(
    hostname: String,
    classes: [String],
    ids: [String]
  ) -> [String] {
    var out: [String] = []
    for name in classes {
      if simpleClassRules.contains(name) {
        out.append(".\(name)")
      }
      if let list = complexClassRules[name] {
        out.append(contentsOf: list)
      }
    }
    for name in ids {
      if simpleIdRules.contains(name) {
        out.append("#\(name)")
      }
      if let list = complexIdRules[name] {
        out.append(contentsOf: list)
      }
    }
    // Apply hostname-scoped `#@#` exceptions. Generic exceptions
    // ("~example.com##.ad") are still unimplemented (see `add`).
    let parents = Self.parentHostnames(hostname)
    var unhide: Set<String> = []
    for parent in parents {
      if let list = hostnameUnhide[parent] { unhide.formUnion(list) }
    }
    return out.filter { !unhide.contains($0) }
  }

  /// Walk from the full hostname up toward the registrable domain,
  /// stopping just above it so we never return a bare TLD. `a.b.com`
  /// yields `["a.b.com", "b.com"]` — `com` is dropped because a
  /// filter keyed on it would fire on every site on the planet and
  /// no published filterlist uses that shape intentionally.
  static func parentHostnames(_ hostname: String) -> [String] {
    let normalized = hostname.lowercased()
    guard !normalized.isEmpty else { return [] }
    var result: [String] = [normalized]
    var current = normalized[...]
    while let dot = current.firstIndex(of: ".") {
      let next = current[current.index(after: dot)...]
      if next.contains(".") {
        result.append(String(next))
        current = next
      } else {
        break
      }
    }
    return result
  }
}

/// Static + dynamic cosmetic filter injection for the built-in
/// content blocker.
///
/// Reads the same filter sources that ``AdBlocker`` downloads, parses
/// the cosmetic half into a ``CosmeticIndex``, and exposes it to every
/// ``BrowserPaneView`` through a `WKUserScript` content script bound
/// to ``WKContentWorld.defaultClient``. The content script injects
/// hostname-scoped CSS at page commit and runs a MutationObserver that
/// feeds newly observed class / id names back through the reply-handler
/// IPC so generic rules expand to match the live DOM.
///
/// Procedural filters (`:has-text()`, `:upward()`, …) are parsed into
/// the procedural buckets and evaluated by the content-script runtime
/// against the live DOM, subject to per-selector budget enforcement.
///
/// Pairs with ``AdBlocker``: the network half + the declarative CSS
/// cosmetic continue to run through `WKContentRuleList`. The two
/// layers double-hide for non-procedural cosmetic, which is idempotent
/// (CSS `display:none` is stable under repetition); retiring the
/// ``WKContentRuleList`` cosmetic path is a possible follow-up once
/// the JS side has enough soak time to be the single source of truth.
@MainActor
public final class CosmeticFilterEngine {
  public static let shared = CosmeticFilterEngine()

  public static let scriptHandlerName = "e05cosmetic"
  public static let contentWorld: WKContentWorld = .defaultClient

  /// The bucket index that `attach(to:)` consumers query through the
  /// IPC handler. Written once from ``start()`` on the main actor and
  /// read-only afterwards, so no mutation protection is needed.
  public private(set) var index = CosmeticIndex()

  /// Flips to `true` after ``start()`` finishes populating ``index``.
  /// The IPC handler uses it to reply with `ready: false` on queries
  /// that arrive before the cache has been parsed; the content script
  /// then retries with exponential backoff so session-restored panes
  /// do not permanently miss their first page load.
  public private(set) var isReady: Bool = false

  private let messageHandler: CosmeticMessageHandler

  private init() {
    self.messageHandler = CosmeticMessageHandler()
    self.messageHandler.engine = self
  }

  /// Load the cosmetic half of each filter source and populate
  /// ``index``. Meant to be called after ``AdBlocker/start()`` so
  /// the filter text cache under `AdBlocker.cacheRoot` is already
  /// warm — this method reads cache only and does not fall back to
  /// the network. Missing cache entries are skipped; the next launch
  /// will have them after AdBlocker finishes.
  public func start() async {
    let startedAt = Date()
    logger.info(
      """
      start → reading cosmetic sources from \
      '\(AdBlocker.cacheRoot.path, privacy: .public)'
      """
    )
    let enabledIds = PreferencesStore.shared.preferences.adblockerEnabledSources
    var parsedRules: [ABPCosmeticParser.ParsedRule] = []
    for source in AdBlocker.allSources {
      if let enabledIds, !enabledIds.contains(source.id) {
        logger.info(
          "skipping disabled source '\(source.id, privacy: .public)'"
        )
        continue
      }
      guard let text = await readCached(filename: source.cacheFilename) else {
        logger.warning(
          """
          cache miss for '\(source.name, privacy: .public)' \
          ('\(source.cacheFilename, privacy: .public)') \
          — AdBlocker may still be downloading; retry next launch
          """
        )
        continue
      }
      let textBytes = text.utf8.count
      let rules = await Task.detached(priority: .userInitiated) {
        ABPCosmeticParser.parseAll(text)
      }.value
      logger.info(
        """
        parsed '\(source.name, privacy: .public)': \
        \(rules.count) cosmetic rules from \(textBytes) bytes
        """
      )
      parsedRules.append(contentsOf: rules)
    }

    var newIndex = CosmeticIndex()
    for rule in parsedRules {
      newIndex.add(rule)
    }
    self.index = newIndex
    self.isReady = true
    let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
    logger.info(
      """
      index built in \(elapsedMs)ms: \
      simpleClass=\(newIndex.simpleClassRules.count) \
      complexClass=\(newIndex.complexClassRules.count) \
      simpleId=\(newIndex.simpleIdRules.count) \
      complexId=\(newIndex.complexIdRules.count) \
      misc=\(newIndex.miscGenericSelectors.count) \
      hostHide=\(newIndex.hostnameHide.count) \
      hostUnhide=\(newIndex.hostnameUnhide.count) \
      procedural=host:\(newIndex.hostnameProcedural.count)/generic:\(newIndex.genericProcedural.count)
      """
    )
  }

  /// Install the content script and IPC handler into a pane's
  /// configuration. Must run before the `WKWebView` is constructed —
  /// ``WKWebViewConfiguration`` is snapshotted at init time, so a
  /// post-init `userContentController` mutation for these APIs is
  /// silently ignored.
  public func attach(to config: WKWebViewConfiguration) {
    let ucc = config.userContentController
    ucc.addUserScript(Self.makeContentScript())
    ucc.addScriptMessageHandler(
      messageHandler,
      contentWorld: Self.contentWorld,
      name: Self.scriptHandlerName
    )
    attachCounter += 1
    logger.info(
      """
      attach → pane #\(self.attachCounter) \
      (handler='\(Self.scriptHandlerName, privacy: .public)' world=defaultClient \
      indexReady=\(self.isReady))
      """
    )
  }

  /// Incremented on every ``attach(to:)`` call so pane log lines carry
  /// a monotonic id without needing access to the pane's ULID. Stored
  /// as an instance property so it inherits the class's `@MainActor`
  /// isolation cleanly — static stored properties on a `@MainActor`
  /// class do not.
  private var attachCounter: Int = 0

  // MARK: - Filter source IO

  private func readCached(filename: String) async -> String? {
    let url = AdBlocker.cacheRoot.appendingPathComponent(filename)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  // MARK: - Content script

  private static func makeContentScript() -> WKUserScript {
    WKUserScript(
      source: contentScriptSource,
      injectionTime: .atDocumentStart,
      forMainFrameOnly: false,
      in: contentWorld
    )
  }

  /// The content script injected into every browser pane. Responsibilities:
  /// - idempotent load guard (subframes and SPA navigations can
  ///   re-trigger injection on the same realm)
  /// - page-commit hostname query that injects hostname-specific
  ///   CSS + the global misc bucket as one `CSSStyleSheet`
  /// - MutationObserver that harvests newly inserted class / id
  ///   names and feeds them back through `queryClassesAndIds`
  /// - rAF-throttled batching to keep the IPC rate bounded
  /// - procedural selector runtime (`:has-text()`, `:contains()`,
  ///   `:upward(N|selector)`) with per-selector budget enforcement
  ///
  /// The procedural runtime is an independent reimplementation of the
  /// uBlock Origin / AdGuard operator semantics — no code is lifted
  /// from their repositories. Hidden elements carry a marker class
  /// that a globally-installed `CSSStyleSheet` maps to
  /// `display: none !important`, which is more resilient to
  /// per-element style overrides from third-party scripts than
  /// writing to the element's `style` attribute directly.
  private static let contentScriptSource: String = {
    guard
      let url = Bundle.module.url(
        forResource: "cosmetic-runtime", withExtension: "js"
      )
    else {
      // Log before trapping so `log stream` surfaces the cause
      // immediately, without waiting for the crash report to be
      // generated and opened. The Package.swift `resources:`
      // declaration is what makes this url resolvable; a nil
      // here means the target spec and the Resources/ directory
      // have drifted apart.
      logger.error("cosmetic-runtime.js missing from E05Lib bundle resources")
      preconditionFailure(
        "cosmetic-runtime.js missing from E05Lib bundle resources"
      )
    }
    do {
      return try String(contentsOf: url, encoding: .utf8)
    } catch {
      logger.error(
        "failed to read cosmetic-runtime.js: \(error.localizedDescription, privacy: .public)"
      )
      preconditionFailure(
        "failed to read cosmetic-runtime.js: \(error)"
      )
    }
  }()
}

/// Bridges the ``CosmeticFilterEngine`` onto the
/// ``WKScriptMessageHandlerWithReply`` protocol. Kept as its own class
/// so the controller's weak delegate pointer retains it; an inner
/// struct would be deallocated the moment ``attach(to:)`` returned.
@MainActor
final class CosmeticMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
  weak var engine: CosmeticFilterEngine?

  func userContentController(
    _: WKUserContentController,
    didReceive message: WKScriptMessage,
    replyHandler: @escaping @MainActor (Any?, String?) -> Void
  ) {
    guard let body = message.body as? [String: Any],
      let type = body["type"] as? String
    else {
      replyHandler(nil, "invalid-body")
      return
    }
    guard let engine = engine else {
      replyHandler(nil, "no-engine")
      return
    }

    switch type {
    case "queryHostname":
      let hostname = (body["hostname"] as? String) ?? ""
      guard engine.isReady else {
        // The index is still being parsed — the content script
        // will retry on a backoff. Returning `ready: false` is
        // the signal; an error string would be surfaced as a
        // thrown Promise rejection on the JS side and drop the
        // retry opportunity.
        logger.info(
          """
          ipc queryHostname hostname='\(hostname, privacy: .public)' \
          → not-ready (index still building)
          """
        )
        replyHandler(["ready": false], nil)
        return
      }
      if AdBlockerWhitelistStore.shared.isWhitelisted(host: hostname) {
        // Cosmetic suppression applies to rules requested *after*
        // this point. CSS hides the content script already added
        // to `document.adoptedStyleSheets` on a previous page
        // commit stay attached until the next navigation, so
        // adding a host to the whitelist while a page is open
        // bypasses network blocking immediately but cosmetic
        // hides only clear after a reload.
        logger.info(
          """
          ipc queryHostname hostname='\(hostname, privacy: .public)' \
          → whitelisted (cosmetic suppressed)
          """
        )
        replyHandler(
          [
            "ready": true,
            "hostnameHide": [String](),
            "misc": [String](),
            "procedural": [String](),
          ], nil)
        return
      }
      let result = engine.index.queryHostname(hostname)
      logger.info(
        """
        ipc queryHostname hostname='\(hostname, privacy: .public)' \
        → hide=\(result.hostnameHide.count) misc=\(result.misc.count) \
        procedural=\(result.procedural.count)
        """
      )
      let payload: [String: Any] = [
        "ready": true,
        "hostnameHide": result.hostnameHide,
        "misc": result.misc,
        "procedural": result.procedural,
      ]
      replyHandler(payload, nil)
    case "queryClassesAndIds":
      let hostname = (body["hostname"] as? String) ?? ""
      let classes = (body["classes"] as? [String]) ?? []
      let ids = (body["ids"] as? [String]) ?? []
      if AdBlockerWhitelistStore.shared.isWhitelisted(host: hostname) {
        replyHandler(["hideSelectors": [String]()], nil)
        return
      }
      let hide = engine.index.queryClassesAndIds(
        hostname: hostname,
        classes: classes,
        ids: ids
      )
      logger.info(
        """
        ipc queryClassesAndIds hostname='\(hostname, privacy: .public)' \
        classes=\(classes.count) ids=\(ids.count) → hide=\(hide.count)
        """
      )
      replyHandler(["hideSelectors": hide], nil)
    case "log":
      // JS-side diagnostic channel. The content script posts
      // lifecycle milestones (boot, first inject, periodic stats)
      // so `log stream` surfaces both sides of the IPC without
      // needing the Web Inspector open.
      let level = (body["level"] as? String) ?? "info"
      let msg = (body["message"] as? String) ?? ""
      switch level {
      case "debug": logger.debug("[js] \(msg, privacy: .public)")
      case "warn": logger.warning("[js] \(msg, privacy: .public)")
      case "error": logger.error("[js] \(msg, privacy: .public)")
      default: logger.info("[js] \(msg, privacy: .public)")
      }
      replyHandler(nil, nil)
    default:
      logger.warning("ipc unknown type='\(type, privacy: .public)'")
      replyHandler(nil, "unknown-type")
    }
  }
}
