import AppKit
import Foundation
import WebKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "CosmeticFilter")

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
        "#@$?#", "#$?#",      // AdGuard extended CSS + style
        "#@$#", "#$#",        // AdGuard style / scriptlet
        "#@%#", "#%#",        // AdGuard JS rule
        "%%",                 // AdGuard extended CSS prefix
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
        // but the on-disk cache under `~/.config/e05/adblocker/` is
        // user-writable; reject any selector that could escape the CSS
        // rule boundary before it reaches `document.adoptedStyleSheets`.
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
    /// the filter text cache under `~/.config/e05/adblocker/` is
    /// already warm — this method reads cache only and does not fall
    /// back to the network. Missing cache entries are skipped; the
    /// next launch will have them after AdBlocker finishes.
    public func start() async {
        let startedAt = Date()
        logger.info(
            """
            start → reading cosmetic sources from \
            '\(AdBlocker.cacheRoot.path, privacy: .public)'
            """
        )
        let sources = Self.cosmeticSources
        var parsedRules: [ABPCosmeticParser.ParsedRule] = []
        for source in sources {
            guard let text = await readCached(source) else {
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

    private struct CosmeticSource {
        let name: String
        let cacheFilename: String
    }

    /// Filter sources whose cosmetic rules feed the index. Must stay
    /// aligned with ``AdBlocker.sources`` cache filenames — the cache
    /// is the hand-off channel between the two engines.
    private static let cosmeticSources: [CosmeticSource] = [
        CosmeticSource(name: "EasyList", cacheFilename: "easylist.txt"),
        CosmeticSource(name: "EasyPrivacy", cacheFilename: "easyprivacy.txt"),
        CosmeticSource(name: "AdGuard Japanese", cacheFilename: "adguard-japanese.txt"),
    ]

    private func readCached(_ source: CosmeticSource) async -> String? {
        let url = AdBlocker.cacheRoot.appendingPathComponent(source.cacheFilename)
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
    private static let contentScriptSource: String = #"""
    (() => {
      if (window.__e05AdblockCosmetic) return;
      window.__e05AdblockCosmetic = true;

      const handler = window.webkit
        && window.webkit.messageHandlers
        && window.webkit.messageHandlers.e05cosmetic;
      if (!handler) return;

      const MAX_BATCH_SELECTORS = 4096;
      const seenClasses = new Set();
      const seenIds = new Set();
      const pendingClasses = new Set();
      const pendingIds = new Set();
      let flushScheduled = false;
      let injectedCount = 0;
      let injectedSheetCount = 0;
      let flushCount = 0;

      // Procedural runtime state. Everything is lazily initialised so
      // pages that receive zero procedural rules pay nothing beyond the
      // declaration cost of these bindings.
      const PROC_HIDDEN_CLASS = "e05-proc-hidden";
      const PROC_PER_RUN_LIMIT_MS = 200;     // soft ceiling per selector per pass
      const PROC_TOTAL_BUDGET_MS = 500;      // cumulative budget before disable
      const PROC_RECOVERY_INTERVAL_MS = 2000;
      const PROC_RECOVERY_AMOUNT_MS = 50;
      const PROC_MAX_CLIMB_DEPTH = 256;      // cap for `:upward(N)` numeric arg
      // Defensive caps against filterlist authors writing pathological
      // `:has-text(/.../)` patterns (e.g. nested quantifiers that
      // trigger catastrophic backtracking). The regex engine is not
      // sandboxed, and filter text comes from third-party maintainers,
      // so a single bad rule without these caps can freeze the UI.
      const PROC_PATTERN_MAX_LENGTH = 200;   // source length cap for `/regex/flags`
      const PROC_TEXT_SCAN_LIMIT = 10_000;   // max chars fed to the text matcher
      const proceduralFilters = [];          // array of parsed PSelector objects
      const proceduralBudgets = new Map();   // raw selector → {totalMs, disabled}
      const proceduralSeenBodies = new Set();// raw body strings already processed
      let proceduralEvalScheduled = false;
      let proceduralHiddenCount = 0;
      let proceduralRecoveryStarted = false;
      let proceduralStyleSheetInstalled = false;
      let proceduralPassCount = 0;

      function sendLog(level, message) {
        // Diagnostic channel — the Swift side routes this into os.Logger
        // so `log stream` shows a single interleaved timeline for both
        // sides of the IPC. The reply is discarded.
        try {
          handler.postMessage({ type: "log", level: level, message: message });
        } catch (_) { /* drop */ }
      }

      function injectCSS(selectors) {
        if (!selectors || selectors.length === 0) return;
        const unique = Array.from(new Set(selectors));
        // One sheet per injection; `adoptedStyleSheets` is append-only
        // in practice so an errant sheet does not invalidate siblings.
        const sheet = new CSSStyleSheet();
        const rule = unique.join(",") + "{display:none !important;}";
        try {
          sheet.replaceSync(rule);
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
          injectedCount += unique.length;
          injectedSheetCount += 1;
        } catch (e) {
          // A single invalid selector poisons the whole declaration —
          // fall back to per-selector sheets so the valid majority
          // still lands.
          let ok = 0;
          let fail = 0;
          for (const sel of unique) {
            try {
              const s = new CSSStyleSheet();
              s.replaceSync(sel + "{display:none !important;}");
              document.adoptedStyleSheets = [...document.adoptedStyleSheets, s];
              ok += 1;
            } catch (_) { fail += 1; }
          }
          injectedCount += ok;
          injectedSheetCount += ok;
          sendLog("warn", `injectCSS bulk-rule failed, per-selector fallback ok=${ok} fail=${fail}`);
        }
      }

      // --- Procedural runtime ----------------------------------------

      // Supported procedural operator names. Looked up by direct string
      // comparison while scanning selector bodies; adding a new operator
      // is a two-step change (extend this list + implement the branch
      // in applyOperator).
      // Single source of truth for procedural operator dispatch.
      // Function declarations below are hoisted, so referencing them
      // here at the top of the IIFE is safe. Adding a new operator is
      // one entry here; `PROC_KNOWN_OPS` and `applyOperator` both
      // read from this table, so there is no chance of the parser
      // accepting a name the evaluator silently ignores.
      const PROC_OP_HANDLERS = {
        "has-text":        applyHasText,       // text matching (literal + regex)
        "contains":        applyHasText,       // alias of has-text
        "upward":          applyUpward,        // ancestor climb (numeric or selector)
        "nth-ancestor":    applyNthAncestor,   // numeric-only ancestor climb
        "matches-attr":    applyMatchesAttr,   // attribute name/value filter
        "matches-css":     applyMatchesCss,    // computed style filter
        "xpath":           applyXpath,         // XPath snapshot (replaces candidate set)
        "min-text-length": applyMinTextLength, // textContent length threshold
      };
      // `remove` is a terminal action resolved in `evalProcedural`
      // rather than a filter — it gets recognised by the parser but
      // is intentionally absent from the handler table.
      const PROC_KNOWN_OPS = Object.keys(PROC_OP_HANDLERS).concat(["remove"]);

      function installProceduralStyleSheet() {
        if (proceduralStyleSheetInstalled) return;
        proceduralStyleSheetInstalled = true;
        try {
          const sheet = new CSSStyleSheet();
          sheet.replaceSync("." + PROC_HIDDEN_CLASS + "{display:none !important;}");
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        } catch (e) {
          sendLog("error", `procedural stylesheet install failed: ${String(e)}`);
        }
      }

      function ensureProceduralRecovery() {
        if (proceduralRecoveryStarted) return;
        proceduralRecoveryStarted = true;
        // Every PROC_RECOVERY_INTERVAL_MS we credit each active budget
        // back by PROC_RECOVERY_AMOUNT_MS, so selectors that are
        // occasionally slow recover naturally. Disabled selectors stay
        // disabled — re-enabling after a hard trip would fight the
        // script that caused them to trip in the first place.
        setInterval(() => {
          for (const b of proceduralBudgets.values()) {
            if (b.disabled) continue;
            b.totalMs = Math.max(0, b.totalMs - PROC_RECOVERY_AMOUNT_MS);
          }
        }, PROC_RECOVERY_INTERVAL_MS);
      }

      // Parse a procedural selector body (the text after `#?#`) into a
      // { plain, ops, raw } record. `plain` is a standard CSS selector
      // suitable for querySelectorAll; `ops` is the ordered list of
      // procedural operators to filter those candidates through.
      // Returns null on structural failure (unbalanced parens etc.).
      function parseProcedural(raw) {
        const len = raw.length;
        let inBracket = 0;  // track [...] so a `:` inside attribute selectors is ignored
        let opStart = -1;
        for (let i = 0; i < len; i++) {
          const c = raw[i];
          if (c === "[") { inBracket++; continue; }
          if (c === "]") { inBracket--; continue; }
          if (inBracket !== 0 || c !== ":") continue;
          for (const name of PROC_KNOWN_OPS) {
            if (raw.substr(i + 1, name.length) === name && raw[i + 1 + name.length] === "(") {
              opStart = i;
              break;
            }
          }
          if (opStart >= 0) break;
        }
        if (opStart < 0) {
          // No procedural op present — caller should not reach this path
          // for such rules, but return a record that makes evalProcedural
          // a safe no-op.
          return { plain: raw.trim() || "*", ops: [], raw };
        }
        const plain = raw.slice(0, opStart).trim() || "*";
        const ops = [];
        let pos = opStart;
        while (pos < len) {
          if (raw[pos] !== ":") break;
          let foundOp = null;
          for (const name of PROC_KNOWN_OPS) {
            if (raw.substr(pos + 1, name.length) === name && raw[pos + 1 + name.length] === "(") {
              foundOp = name;
              break;
            }
          }
          if (!foundOp) return null;
          const argStart = pos + 1 + foundOp.length + 1;  // past "("
          let depth = 1;
          let cursor = argStart;
          while (cursor < len && depth > 0) {
            const ch = raw[cursor];
            if (ch === "(") depth++;
            else if (ch === ")") depth--;
            if (depth > 0) cursor++;
          }
          if (depth !== 0) return null;  // unbalanced
          ops.push({ kind: foundOp, arg: raw.slice(argStart, cursor) });
          pos = cursor + 1;
        }
        return { plain, ops, raw };
      }

      // Build a predicate for the argument to `:has-text()` /
      // `:contains()`. Accepts either a literal substring (case-
      // sensitive, matching uBO / AdGuard default) or the `/pattern/flags`
      // regex form. Returns null if the regex fails to compile, if the
      // argument is empty (a literal empty-string match would hide
      // every candidate), or if the regex source exceeds the length cap.
      function compileTextMatcher(arg) {
        const trimmed = arg.trim();
        if (trimmed.length === 0) return null;
        if (trimmed.length >= 2 && trimmed[0] === "/") {
          const lastSlash = trimmed.lastIndexOf("/");
          if (lastSlash > 0) {
            const pattern = trimmed.slice(1, lastSlash);
            const flags = trimmed.slice(lastSlash + 1);
            if (pattern.length > PROC_PATTERN_MAX_LENGTH) return null;
            try {
              const re = new RegExp(pattern, flags);
              return (text) => re.test(text);
            } catch (_) { return null; }
          }
        }
        return (text) => text.indexOf(trimmed) >= 0;
      }

      function applyHasText(candidates, arg) {
        const matcher = compileTextMatcher(arg);
        if (!matcher) return [];
        const out = [];
        for (const el of candidates) {
          // textContent includes descendants, which matches the uBO
          // behaviour: a label buried inside a child element still
          // qualifies the ancestor for the match. Slice at a hard cap
          // so a gigantic article page does not feed a MB-scale string
          // through a regex engine that cannot be interrupted.
          const full = el.textContent || "";
          const text = full.length > PROC_TEXT_SCAN_LIMIT
            ? full.slice(0, PROC_TEXT_SCAN_LIMIT)
            : full;
          if (matcher(text)) out.push(el);
        }
        return out;
      }

      function applyUpward(candidates, arg) {
        const trimmed = arg.trim();
        const asNum = parseInt(trimmed, 10);
        if (!isNaN(asNum) && String(asNum) === trimmed) {
          // uBO treats `:upward(0)` as self (noop); we return empty
          // because 0 has never been observed in shipped filterlists
          // and emptying is the safer default for an author typo.
          if (asNum < 1 || asNum > PROC_MAX_CLIMB_DEPTH) return [];
          const out = [];
          for (const el of candidates) {
            let cur = el;
            for (let k = 0; k < asNum && cur; k++) cur = cur.parentElement;
            if (cur) out.push(cur);
          }
          return out;
        }
        // Selector form: climb from the *parent* so we do not match the
        // candidate itself — :upward(X) is "nearest ancestor matching X",
        // not "self or ancestor".
        const out = [];
        for (const el of candidates) {
          const parent = el.parentElement;
          const hit = parent ? parent.closest(trimmed) : null;
          if (hit) out.push(hit);
        }
        return out;
      }

      function applyNthAncestor(candidates, arg) {
        // Numeric-only variant of `:upward(N)` — filter authors use
        // it when they mean "go up exactly N" and want the selector
        // form (`:upward(selector)`) disabled. Reject non-integer
        // arguments rather than silently accepting them.
        const trimmed = arg.trim();
        const asNum = parseInt(trimmed, 10);
        if (isNaN(asNum) || String(asNum) !== trimmed) return [];
        if (asNum < 1 || asNum > PROC_MAX_CLIMB_DEPTH) return [];
        const out = [];
        for (const el of candidates) {
          let cur = el;
          for (let k = 0; k < asNum && cur; k++) cur = cur.parentElement;
          if (cur) out.push(cur);
        }
        return out;
      }

      function applyMinTextLength(candidates, arg) {
        const n = parseInt(arg.trim(), 10);
        if (isNaN(n) || n < 0) return [];
        const out = [];
        for (const el of candidates) {
          if ((el.textContent || "").length >= n) out.push(el);
        }
        return out;
      }

      // Compile a string predicate used for `:matches-attr` name or
      // value matching, and for `:matches-css` value matching. Three
      // input shapes are accepted, checked in this order so a quoted
      // literal that happens to contain slashes is not misread as a
      // regex pattern:
      //
      //   "foo" / 'foo'       → literal (quotes stripped)
      //   /pattern/flags      → compiled RegExp
      //   foo                 → literal
      //
      // `substring` picks the matcher semantic for the literal paths:
      // true → substring test (value side), false → exact equality
      // (name side). Returns null if the input is empty or if regex
      // compilation fails.
      function compileProcMatcher(spec, substring) {
        const trimmed = spec.trim();
        if (trimmed.length === 0) return null;
        if (trimmed.length >= 2) {
          const first = trimmed[0];
          const last = trimmed[trimmed.length - 1];
          if ((first === "\"" || first === "'") && first === last) {
            const literal = trimmed.slice(1, -1);
            return substring
              ? (text) => (text || "").indexOf(literal) >= 0
              : (text) => (text || "") === literal;
          }
        }
        if (trimmed.length >= 2 && trimmed[0] === "/") {
          const lastSlash = trimmed.lastIndexOf("/");
          if (lastSlash > 0) {
            const pattern = trimmed.slice(1, lastSlash);
            const flags = trimmed.slice(lastSlash + 1);
            if (pattern.length > PROC_PATTERN_MAX_LENGTH) return null;
            try {
              const re = new RegExp(pattern, flags);
              return (text) => re.test(text || "");
            } catch (_) { return null; }
          }
        }
        return substring
          ? (text) => (text || "").indexOf(trimmed) >= 0
          : (text) => (text || "") === trimmed;
      }

      // Parse the `:matches-attr(...)` argument into name and value
      // predicates. Splits on the first top-level `=` that is not
      // inside a quoted string or `/regex/` literal — the same syntax
      // uBO / AdGuard accept.
      function parseAttrSpec(arg) {
        const trimmed = arg.trim();
        if (trimmed.length === 0) return null;
        let inStr = null;
        let inRegex = false;
        let prev = "";
        let eqPos = -1;
        for (let i = 0; i < trimmed.length; i++) {
          const c = trimmed[i];
          if (inStr) {
            if (c === inStr && prev !== "\\") inStr = null;
          } else if (inRegex) {
            if (c === "/" && prev !== "\\") inRegex = false;
          } else if (c === "\"" || c === "'") {
            inStr = c;
          } else if (c === "/") {
            inRegex = true;
          } else if (c === "=") {
            eqPos = i;
            break;
          }
          prev = c;
        }
        const namePart = eqPos < 0 ? trimmed : trimmed.slice(0, eqPos).trim();
        const valuePart = eqPos < 0 ? null : trimmed.slice(eqPos + 1).trim();
        // Attribute names are well-defined, so literal name match is
        // exact equality; attribute values can be substring-matched
        // which is what filter authors normally want ("title contains
        // 'Sponsored'" etc.).
        const nameMatcher = compileProcMatcher(namePart, false);
        if (!nameMatcher) return null;
        let valueMatcher = null;
        if (valuePart !== null) {
          valueMatcher = compileProcMatcher(valuePart, true);
          if (!valueMatcher) return null;
        }
        return { nameMatcher, valueMatcher };
      }

      function applyMatchesAttr(candidates, arg) {
        const parsed = parseAttrSpec(arg);
        if (!parsed) return [];
        const out = [];
        for (const el of candidates) {
          const attrs = el.attributes;
          if (!attrs || !attrs.length) continue;
          let hit = false;
          for (let i = 0; i < attrs.length; i++) {
            const a = attrs[i];
            if (!parsed.nameMatcher(a.name)) continue;
            if (parsed.valueMatcher && !parsed.valueMatcher(a.value)) continue;
            hit = true;
            break;
          }
          if (hit) out.push(el);
        }
        return out;
      }

      function applyMatchesCss(candidates, arg) {
        const trimmed = arg.trim();
        const colon = trimmed.indexOf(":");
        if (colon < 0) return [];
        const prop = trimmed.slice(0, colon).trim();
        const valSpec = trimmed.slice(colon + 1).trim();
        if (!prop || !valSpec) return [];
        const matcher = compileProcMatcher(valSpec, true);
        if (!matcher) return [];
        const out = [];
        for (const el of candidates) {
          let value = "";
          try { value = getComputedStyle(el).getPropertyValue(prop); } catch (_) {}
          if (matcher(value)) out.push(el);
        }
        return out;
      }

      function applyXpath(candidates, arg) {
        // XPath context is the document rather than each candidate —
        // uBO and AdGuard both discard the incoming candidate set
        // because filter authors write `*:xpath(//...)` expecting a
        // fresh document-wide match.
        const expr = arg.trim();
        if (!expr) return [];
        const out = [];
        const seen = new Set();
        try {
          const snap = document.evaluate(
            expr,
            document,
            null,
            XPathResult.ORDERED_NODE_SNAPSHOT_TYPE,
            null
          );
          for (let i = 0; i < snap.snapshotLength; i++) {
            const node = snap.snapshotItem(i);
            if (node && node.nodeType === 1 && !seen.has(node)) {
              seen.add(node);
              out.push(node);
            }
          }
        } catch (_) { /* invalid xpath — drop */ }
        return out;
      }

      function applyOperator(candidates, op) {
        // `:remove` is a terminal action hoisted by `evalProcedural`
        // into the action flag before this function is reached. Any
        // other unknown opcode returns `undefined` from the table and
        // yields an empty candidate set, dropping the chain.
        const fn = PROC_OP_HANDLERS[op.kind];
        return fn ? fn(candidates, op.arg) : [];
      }

      // Evaluate a parsed procedural filter against the live DOM.
      // Returns { elements: Element[], action: "hide" | "remove" };
      // an empty `elements` means no match this pass and the caller
      // can skip the hide/remove work entirely.
      function evalProcedural(pf) {
        let candidates;
        try {
          candidates = Array.from(document.querySelectorAll(pf.plain || "*"));
        } catch (_) { return { elements: [], action: "hide" }; }
        let action = "hide";
        for (const op of pf.ops) {
          if (op.kind === "remove") {
            // `:remove()` is a terminal action marker, not a filter.
            // Switch mode and let the remaining chain (if any) run —
            // uBO places it at the tail, but being permissive here
            // avoids throwing on an early `:remove()`.
            action = "remove";
            continue;
          }
          candidates = applyOperator(candidates, op);
          if (candidates.length === 0) return { elements: [], action };
        }
        // Dedupe — chained `:upward` on sibling candidates can converge
        // on the same ancestor and we only need to act on it once.
        if (candidates.length > 1) {
          const seen = new Set();
          const unique = [];
          for (const el of candidates) {
            if (seen.has(el)) continue;
            seen.add(el);
            unique.push(el);
          }
          return { elements: unique, action };
        }
        return { elements: candidates, action };
      }

      function execWithBudget(pf, fn) {
        const key = pf.raw;
        let b = proceduralBudgets.get(key);
        if (!b) { b = { totalMs: 0, disabled: false }; proceduralBudgets.set(key, b); }
        if (b.disabled) return 0;
        const start = performance.now();
        let hidden = 0;
        try {
          hidden = fn();
        } catch (e) {
          sendLog("error", `procedural exec threw for '${key}': ${String(e)}`);
        }
        const dt = performance.now() - start;
        b.totalMs += dt;
        if (dt > PROC_PER_RUN_LIMIT_MS) {
          sendLog(
            "warn",
            `procedural slow single-pass: '${key}' ${dt.toFixed(1)}ms ` +
            `(total=${b.totalMs.toFixed(1)}ms)`
          );
        }
        if (b.totalMs > PROC_TOTAL_BUDGET_MS && !b.disabled) {
          b.disabled = true;
          sendLog(
            "warn",
            `procedural selector disabled (budget exhausted): '${key}' ` +
            `totalMs=${b.totalMs.toFixed(1)}ms`
          );
        }
        return hidden;
      }

      function evaluateAllProcedural() {
        if (proceduralFilters.length === 0) return;
        proceduralPassCount += 1;
        let totalHidden = 0;
        let totalRemoved = 0;
        for (const pf of proceduralFilters) {
          execWithBudget(pf, () => {
            const result = evalProcedural(pf);
            let added = 0;
            if (result.action === "remove") {
              for (const el of result.elements) {
                // `el.remove()` is a no-op on an orphaned node; the
                // parent check short-circuits so a previous pass that
                // already removed this element does not inflate the
                // counter.
                if (el.parentNode) {
                  el.remove();
                  added++;
                }
              }
              totalRemoved += added;
            } else {
              for (const el of result.elements) {
                if (!el.classList.contains(PROC_HIDDEN_CLASS)) {
                  el.classList.add(PROC_HIDDEN_CLASS);
                  added++;
                }
              }
              totalHidden += added;
            }
            return added;
          });
        }
        if (totalHidden > 0 || totalRemoved > 0) {
          proceduralHiddenCount += totalHidden + totalRemoved;
          sendLog(
            "info",
            `procedural pass#${proceduralPassCount} hid=${totalHidden} removed=${totalRemoved} ` +
            `(cumulative=${proceduralHiddenCount})`
          );
        }
      }

      function scheduleProceduralEval() {
        if (proceduralEvalScheduled) return;
        if (proceduralFilters.length === 0) return;
        proceduralEvalScheduled = true;
        requestAnimationFrame(() => {
          proceduralEvalScheduled = false;
          evaluateAllProcedural();
        });
      }

      function applyProcedural(bodies) {
        if (!bodies || !bodies.length) return;
        installProceduralStyleSheet();
        ensureProceduralRecovery();
        let added = 0;
        let skippedPlain = 0;
        let skippedParse = 0;
        let skippedDup = 0;
        for (const body of bodies) {
          // A filter source may list the same selector under more than
          // one hostname scope — for example in the hostname index
          // under both `example.com` and `sub.example.com` — and the
          // hostname-parent walk then emits it twice. Dedup on the raw
          // body so `proceduralFilters` does not grow duplicates that
          // waste budget on identical `querySelectorAll` work.
          if (proceduralSeenBodies.has(body)) { skippedDup++; continue; }
          proceduralSeenBodies.add(body);
          const parsed = parseProcedural(body);
          if (!parsed) {
            skippedParse++;
            // Slice in the log to keep a pathological filter line
            // from flooding the diagnostic stream.
            sendLog(
              "debug",
              `procedural parse failed: '${body.slice(0, 120)}'`
            );
            continue;
          }
          // A body with no procedural op is a plain CSS selector that
          // the non-procedural pipeline already turned into CSS; drop
          // it here rather than double-hide.
          if (parsed.ops.length === 0) { skippedPlain++; continue; }
          proceduralFilters.push(parsed);
          added++;
        }
        sendLog(
          "info",
          `procedural activated: ${added} rules ` +
          `(total=${proceduralFilters.length}, skipped plain=${skippedPlain} ` +
          `parse=${skippedParse} dup=${skippedDup})`
        );
        if (added > 0) scheduleProceduralEval();
      }

      // Caps at 3 retries with 200/400/800 ms delays, covering the
      // ~800 ms index-build window observed on cold launch. If the
      // engine is still not ready after ~1.4 s the pane gives up — a
      // later navigation on the same pane will try again from scratch.
      const QUERY_HOSTNAME_MAX_RETRIES = 3;

      async function queryHostname(retriesLeft) {
        if (retriesLeft === undefined) retriesLeft = QUERY_HOSTNAME_MAX_RETRIES;
        try {
          const resp = await handler.postMessage({
            type: "queryHostname",
            hostname: location.hostname || ""
          });
          if (!resp) {
            sendLog("warn", "queryHostname reply was null");
            return;
          }
          if (resp.ready === false) {
            if (retriesLeft > 0) {
              const attempt = QUERY_HOSTNAME_MAX_RETRIES - retriesLeft + 1;
              const delay = 200 * Math.pow(2, attempt - 1);
              sendLog(
                "info",
                `queryHostname not-ready, retry#${attempt} in ${delay}ms (remaining=${retriesLeft - 1})`
              );
              setTimeout(() => queryHostname(retriesLeft - 1), delay);
            } else {
              sendLog("warn", "queryHostname gave up waiting for index build");
            }
            return;
          }
          const hide = (resp.hostnameHide && resp.hostnameHide.length) || 0;
          const misc = (resp.misc && resp.misc.length) || 0;
          const proc = (resp.procedural && resp.procedural.length) || 0;
          sendLog(
            "info",
            `queryHostname reply hide=${hide} misc=${misc} procedural=${proc} → injecting`
          );
          const all = [];
          if (resp.hostnameHide) all.push(...resp.hostnameHide);
          if (resp.misc) all.push(...resp.misc);
          injectCSS(all);
          if (resp.procedural) applyProcedural(resp.procedural);
        } catch (e) {
          sendLog("error", `queryHostname threw: ${String(e)}`);
        }
      }

      async function flushClassId() {
        flushScheduled = false;
        if (pendingClasses.size === 0 && pendingIds.size === 0) return;
        const classes = Array.from(pendingClasses);
        const ids = Array.from(pendingIds);
        pendingClasses.clear();
        pendingIds.clear();
        flushCount += 1;
        try {
          const resp = await handler.postMessage({
            type: "queryClassesAndIds",
            hostname: location.hostname || "",
            classes, ids
          });
          const hideLen = (resp && resp.hideSelectors && resp.hideSelectors.length) || 0;
          if (hideLen > 0) {
            const capped = resp.hideSelectors.length > MAX_BATCH_SELECTORS
              ? resp.hideSelectors.slice(0, MAX_BATCH_SELECTORS)
              : resp.hideSelectors;
            injectCSS(capped);
            sendLog(
              "debug",
              `flush#${flushCount} in classes=${classes.length} ids=${ids.length} → inject=${capped.length}`
            );
          }
        } catch (e) {
          sendLog("error", `flushClassId threw: ${String(e)}`);
        }
      }

      function scheduleFlush() {
        if (flushScheduled) return;
        flushScheduled = true;
        // rAF keeps bursts (common on SPA first-paint) collapsed into
        // one IPC per frame; Brave / uBO use the same pacing.
        requestAnimationFrame(flushClassId);
      }

      function harvestNode(node) {
        if (!node || node.nodeType !== 1) return;
        const cl = node.classList;
        if (cl && cl.length) {
          for (let i = 0; i < cl.length; i++) {
            const c = cl[i];
            if (!seenClasses.has(c)) {
              seenClasses.add(c);
              pendingClasses.add(c);
            }
          }
        }
        const id = node.id;
        if (id && !seenIds.has(id)) {
          seenIds.add(id);
          pendingIds.add(id);
        }
      }

      function harvestSubtree(root) {
        harvestNode(root);
        if (root && root.querySelectorAll) {
          const all = root.querySelectorAll("*");
          for (let i = 0; i < all.length; i++) harvestNode(all[i]);
        }
      }

      const observer = new MutationObserver((mutations) => {
        let dirty = false;
        for (const m of mutations) {
          if (m.type === "childList") {
            for (const node of m.addedNodes) {
              harvestSubtree(node);
              dirty = true;
            }
          } else if (m.type === "attributes") {
            harvestNode(m.target);
            dirty = true;
          }
        }
        if (dirty) {
          scheduleFlush();
          // Procedural rules can match on freshly inserted elements or on
          // text that arrived via a `textContent` mutation — piggy-back
          // on the same dirty signal rather than observe twice.
          scheduleProceduralEval();
        }
      });

      function boot() {
        if (!document.documentElement) {
          // `atDocumentStart` races the parser: the element can be nil
          // on the very first tick. Yielding once is enough.
          setTimeout(boot, 0);
          return;
        }
        observer.observe(document.documentElement, {
          childList: true,
          subtree: true,
          attributes: true,
          attributeFilter: ["class", "id"]
        });
        harvestSubtree(document.documentElement);
        sendLog(
          "info",
          `boot hostname='${location.hostname || ""}' url='${(location.href || "").slice(0, 120)}' ` +
          `documentState=${document.readyState} initialHarvest classes=${pendingClasses.size} ids=${pendingIds.size}`
        );
        scheduleFlush();
        queryHostname();

        // Emit a once-off summary 5 s after boot so the user can tell
        // from `log stream` whether the engine produced any effect on
        // this page without opening Web Inspector.
        setTimeout(() => {
          // Count selectors that hit the budget ceiling so the summary
          // line surfaces broken filter authoring without needing to
          // grep the full log.
          let procDisabled = 0;
          for (const b of proceduralBudgets.values()) {
            if (b.disabled) procDisabled++;
          }
          sendLog(
            "info",
            `+5s summary seenClasses=${seenClasses.size} seenIds=${seenIds.size} ` +
            `flushes=${flushCount} injectedSheets=${injectedSheetCount} injectedSelectors=${injectedCount} ` +
            `proceduralRules=${proceduralFilters.length} proceduralPasses=${proceduralPassCount} ` +
            `proceduralHidden=${proceduralHiddenCount} proceduralDisabled=${procDisabled}`
          );
        }, 5000);
      }
      boot();
    })();
    """#
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
              let type = body["type"] as? String else {
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
            case "warn":  logger.warning("[js] \(msg, privacy: .public)")
            case "error": logger.error("[js] \(msg, privacy: .public)")
            default:      logger.info("[js] \(msg, privacy: .public)")
            }
            replyHandler(nil, nil)
        default:
            logger.warning("ipc unknown type='\(type, privacy: .public)'")
            replyHandler(nil, "unknown-type")
        }
    }
}
