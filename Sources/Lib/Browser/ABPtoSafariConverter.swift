import Foundation
import os.log

private let logger = Logger(
  subsystem: LogSubsystem.app,
  category: "AdBlockerConverter"
)

/// Convert a subset of the Adblock Plus / EasyList filter language into the
/// Safari Content Blocker JSON format documented at
/// https://developer.apple.com/documentation/safariservices/creating_a_content_blocker.
///
/// The compiled JSON is fed into ``WKContentRuleListStore`` which WebKit
/// evaluates natively in the network process — no JS runtime on the
/// hot path. Procedural and text-matching cosmetic filters live in a
/// separate content-script engine.
///
/// ## Supported
/// - Network block: `||domain.com^`, `|http://...|`, `example.com/ads/*`
/// - Network exception: `@@||domain.com^`
/// - `$third-party` / `$3p` (and the `$~third-party` / `$first-party` /
///   `$1p` / `$~1p` family), `$domain=a.com|~b.com`, `$script`, `$image`,
///   `$xhr`, `$subdocument` / `$frame`, `$stylesheet`, `$media`,
///   `$websocket`, `$font`, `$document`, `$popup`, `$object`, `$ping`
/// - Cosmetic hide: `##selector`, `domain.com,~sub.com##selector`
///
/// ## Skipped (silently, with per-line debug log)
/// - Cosmetic exception `#@#` — Safari cannot express declaratively
/// - Procedural cosmetic (`:has-text()`, `:upward()`, `:xpath()`, `:style(...)`)
/// - HTML filter `##^script`, `$$` — no response-body rewrite in WebKit
/// - Scriptlet `+js(...)` — not implemented; would need a separate
///   JS injection pipeline outside the content rule list
/// - Rare options: `$csp`, `$redirect`, `$replace`, `$removeparam`,
///   `$important`, `$badfilter`, `$generichide`, `$elemhide`
/// - Regex literals with lookbehind
public enum ABPtoSafariConverter {
  /// A single Safari Content Blocker rule — matches the JSON shape expected
  /// by ``WKContentRuleListStore.compileContentRuleList``.
  public struct Rule: Encodable, Sendable {
    public let trigger: Trigger
    public let action: Action
  }

  public struct Trigger: Encodable, Sendable {
    public var urlFilter: String
    public var urlFilterIsCaseSensitive: Bool?
    public var resourceType: [String]?
    public var loadType: [String]?
    public var ifDomain: [String]?
    public var unlessDomain: [String]?

    enum CodingKeys: String, CodingKey {
      case urlFilter = "url-filter"
      case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
      case resourceType = "resource-type"
      case loadType = "load-type"
      case ifDomain = "if-domain"
      case unlessDomain = "unless-domain"
    }
  }

  public struct Action: Encodable, Sendable {
    public let type: String
    public let selector: String?
  }

  /// Version of the converter's output shape. Folded into the compiled
  /// rule-list cache key by ``AdBlocker`` — bump it whenever a converter
  /// change alters what a given filterlist text converts to, so WebKit's
  /// precompiled binaries (keyed by source text otherwise) recompile on
  /// the next launch. Starts at 3: 1 names the implicit pre-constant
  /// output and 2 an interim build, and compiled caches keyed by either
  /// may survive on disk, so neither value is safe to reuse.
  public static let outputVersion = 3

  /// Convert a full filterlist text into Safari rules. `maxRules` guards
  /// against the WebKit compiler's hard limit (50k on older targets,
  /// 150k on macOS 11+); callers trim to the platform-specific ceiling
  /// before serializing.
  public static func convert(
    _ text: String,
    maxRules: Int = 150_000
  ) -> (rules: [Rule], skipped: Int) {
    var rules: [Rule] = []
    var skipped = 0
    var truncated = false
    // enumerateLines handles both LF and CRLF line endings and strips
    // the terminator from the callback argument. Using
    // `split(separator: "\n")` silently collapses to a single
    // subsequence when the compiler picks up the String-separator
    // overload, which makes a large filterlist look empty.
    text.enumerateLines { rawLine, stop in
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { return }
      guard !line.hasPrefix("!"), !line.hasPrefix("[") else { return }

      let produced = convertLine(line)
      if produced.isEmpty {
        skipped += 1
      } else {
        rules.append(contentsOf: produced)
        if rules.count >= maxRules {
          truncated = true
          stop = true
        }
      }
    }
    if truncated {
      logger.warning(
        "ABP converter reached \(maxRules) rule cap — truncating"
      )
    }
    return (rules, skipped)
  }

  // MARK: - Line dispatcher

  /// Markers that flag non-declarative or otherwise non-convertible
  /// rule bodies. Checked before the `##` split so AdGuard and uBO
  /// extensions aren't mistakenly handled as network rules.
  private static let skipMarkers: [String] = [
    "#@#",  // ABP cosmetic exception
    "#?#",  // uBO procedural cosmetic
    "#$#",  // uBO style/scriptlet
    "#%#",  // AdGuard JS rule / scriptlet (`#%#//scriptlet(...)`)
    "#@%#",  // AdGuard JS exception
    "#$?#",  // AdGuard extended CSS with style
    "#@$#",  // AdGuard style exception
    "$$",  // AdGuard HTML filter
    "$@$",  // AdGuard HTML exception
    "%%",  // AdGuard extended CSS marker
  ]

  /// Network-option substrings that require body-rewriting or
  /// response-body access that WebKit's Content Blocker cannot express.
  /// Presence of any one of these anywhere in the options string drops
  /// the whole line.
  private static let unsupportedNetworkOptionFragments: [String] = [
    "$replace=",
    "$hls=",
    "$jsonprune=",
    "$xmlprune=",
    "$removeparam",
    "$csp=",
    "$redirect=",
    "$redirect-rule=",
    "$rewrite=",
    "$method=",
    "$app=",
    "$referrerpolicy=",
    "$permissions=",
    "$cookie=",
    "$all",
  ]

  /// Line dispatcher. Returns zero, one, or two Safari rules: some ABP
  /// shapes (notably network patterns ending in `^`) need to be split
  /// into a separator-char variant plus a URL-end variant so each
  /// regex stays expressible in WebKit's Content Blocker subset.
  private static func convertLine(_ line: String) -> [Rule] {
    for marker in skipMarkers {
      if line.contains(marker) { return [] }
    }
    for fragment in unsupportedNetworkOptionFragments {
      if line.contains(fragment) { return [] }
    }
    // Regex-literal rules (`/.../` or `@@/.../`, optionally with
    // `$options`) exercise a far larger regex surface than WebKit's
    // Content Blocker compiler accepts. Skipping them before the
    // cosmetic/network split keeps us from mistaking a slash in the
    // regex body for the `##` marker.
    let regexHead = line.hasPrefix("@@") ? String(line.dropFirst(2)) : line
    if regexHead.hasPrefix("/") { return [] }
    if let range = line.range(of: "##") {
      let prefix = String(line[..<range.lowerBound])
      let selector = String(line[range.upperBound...])
        .trimmingCharacters(in: .whitespaces)
      if let rule = convertCosmetic(domainList: prefix, selector: selector) {
        return [rule]
      }
      return []
    }
    return convertNetwork(line)
  }

  /// ABP option names the converter does not implement but recognises so
  /// the `$` boundary still detects when one of them appears alongside
  /// implemented options. Treating these as valid here keeps the rule
  /// from being misparsed as a literal URL pattern (which would smuggle
  /// the `|` separators in `domain=a|b` into WebKit's regex compiler
  /// and trip a stderr spam). The rule itself drops in
  /// `convertNetwork` because `recognizedOptions` still excludes them.
  private static let tolerableUnsupportedOptions: Set<String> = [
    "important", "badfilter",
    "generichide", "ghide", "elemhide", "ehide", "specifichide", "shide",
    "inline-script", "inline-font",
    "strict3p", "strict1p",
    "all", "empty", "mp4", "popunder",
    "removeparam", "cookie",
  ]

  /// Option keys that always carry a value (`key=...`). Recognising
  /// the `key=` prefix lets `looksLikeOptionList` accept them without
  /// inspecting the value — and accept the *rest of the suffix* along
  /// with them, because these values are free-form (uBO allows
  /// `/regex/` bodies whose `{n,m}` quantifiers embed commas) and
  /// naive comma tokenisation cannot tell a value fragment from the
  /// next option. Bare-name variants (no `=`) live in
  /// ``tolerableUnsupportedOptions`` so the prefix match here never
  /// accidentally swallows tokens that share a name root (e.g. a
  /// hypothetical `cookieless`).
  private static let tolerableUnsupportedKeyedOptions: [String] = [
    "redirect=", "redirect-rule=",
    "csp=", "replace=", "removeparam=",
    "denyallow=", "permissions=", "header=",
    "cookie=",
    "app=", "method=", "to=", "from=",
    "urlskip=", "ipaddress=",
    "rewrite=",
  ]

  /// Heuristic: does the given suffix look like a comma-separated list
  /// of ABP options (`third-party`, `script`, `domain=...`, etc.) rather
  /// than part of a URL body? True if every non-empty token either
  /// appears in `recognizedOptions`, starts with `~`, or begins with a
  /// known option prefix such as `domain=`, `match-case`, `sitekey=` —
  /// or once a free-form keyed option from
  /// ``tolerableUnsupportedKeyedOptions`` shows up, in which case the
  /// remaining tokens are accepted wholesale (they may be fragments of
  /// that option's comma-bearing value, and the rule drops in
  /// `convertNetwork` regardless). Otherwise conservative by design:
  /// an unfamiliar token downgrades the whole suffix to "not options"
  /// so we keep scanning left for a better split point.
  private static func looksLikeOptionList(_ suffix: Substring) -> Bool {
    guard !suffix.isEmpty else { return false }
    let tokens = suffix.split(separator: ",")
    guard !tokens.isEmpty else { return false }
    for raw in tokens {
      let t = raw.trimmingCharacters(in: .whitespaces)
      if t.isEmpty { return false }
      let name = t.hasPrefix("~") ? String(t.dropFirst()) : t
      if recognizedOptions.contains(name) { continue }
      if name.hasPrefix("domain=")
        || name.hasPrefix("sitekey=")
        || name == "match-case"
        || name == "~match-case"
      {
        continue
      }
      if tolerableUnsupportedOptions.contains(name) { continue }
      if tolerableUnsupportedKeyedOptions.contains(where: { name.hasPrefix($0) }) {
        return true
      }
      return false
    }
    return true
  }

  // MARK: - Cosmetic

  private static func convertCosmetic(
    domainList: String,
    selector: String
  ) -> Rule? {
    guard !selector.isEmpty else { return nil }
    // Reject procedural / ABP-extended syntax the CSS parser can't read.
    if selector.contains(":-abp-")
      || selector.contains(":style(")
      || selector.contains(":has-text(")
      || selector.contains(":matches-css(")
      || selector.contains(":min-text-length(")
      || selector.contains(":upward(")
      || selector.contains(":nth-ancestor(")
      || selector.contains(":xpath(")
      || selector.contains(":remove(")
      || selector.hasPrefix("+js(")
      || selector.hasPrefix("^")
    {
      return nil
    }

    var ifDomain: [String] = []
    var unlessDomain: [String] = []
    if !domainList.isEmpty {
      for token in domainList.split(separator: ",") {
        let t = token.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { continue }
        if t.hasPrefix("~") {
          unlessDomain.append("*" + String(t.dropFirst()))
        } else {
          ifDomain.append("*" + t)
        }
      }
    }
    // WebKit rejects triggers that combine `if-domain` and
    // `unless-domain`. When both are specified, keep the positive
    // list and drop the negative exclusions; the block then fires
    // on the author-intended domains even if a few exceptions leak.
    if !ifDomain.isEmpty, !unlessDomain.isEmpty {
      unlessDomain = []
    }

    let trigger = Trigger(
      urlFilter: ".*",
      urlFilterIsCaseSensitive: nil,
      resourceType: nil,
      loadType: nil,
      ifDomain: ifDomain.isEmpty ? nil : ifDomain,
      unlessDomain: unlessDomain.isEmpty ? nil : unlessDomain
    )
    let action = Action(type: "css-display-none", selector: selector)
    return Rule(trigger: trigger, action: action)
  }

  // MARK: - Network

  /// Known ABP option names. Options outside this set cause the whole
  /// rule to be skipped — partial mapping risks false positives.
  private static let recognizedOptions: Set<String> = [
    "third-party", "3p", "~third-party", "~3p",
    "first-party", "1p", "~first-party", "~1p",
    "script", "~script",
    "image", "~image",
    "xhr", "xmlhttprequest", "~xhr", "~xmlhttprequest",
    "subdocument", "frame", "~subdocument", "~frame",
    "stylesheet", "css", "~stylesheet", "~css",
    "media", "~media",
    "websocket", "~websocket",
    "font", "~font",
    "document", "doc", "~document", "~doc",
    "popup", "~popup",
    "object", "~object",
    "ping", "~ping",
    "other", "~other",
  ]

  private static func convertNetwork(_ line: String) -> [Rule] {
    var body = line
    let isException = body.hasPrefix("@@")
    if isException { body.removeFirst(2) }

    // Reject raw regex literals outright. ABP allows `/regex/` and
    // `/regex/$options` rule bodies, but the published regex bodies
    // in AdGuard Japanese filter 7 routinely use alternation, nested
    // groups, and lookbehind that WebKit's Content Blocker compiler
    // rejects. Dropping them wholesale is less risky than trying to
    // translate an unconstrained regex subset.
    if body.hasPrefix("/") {
      return []
    }

    // Split pattern and options at an ABP-valid `$` boundary. We scan
    // from the right and accept the first `$` whose suffix parses as
    // a comma-separated list of known options; this avoids splitting
    // on `$` characters that are part of the URL body itself.
    var optionText: Substring = ""
    var searchEnd = body.endIndex
    while let dollarIdx = body[..<searchEnd].lastIndex(of: "$") {
      let suffix = body[body.index(after: dollarIdx)...]
      if looksLikeOptionList(suffix) {
        optionText = suffix
        body = String(body[..<dollarIdx])
        break
      }
      searchEnd = dollarIdx
    }

    let patterns = patternToRegexes(body)
    guard !patterns.isEmpty else { return [] }

    var resourceType: [String] = []
    var loadType: String? = nil
    var ifDomain: [String] = []
    var unlessDomain: [String] = []

    if !optionText.isEmpty {
      for raw in optionText.split(separator: ",") {
        let opt = raw.trimmingCharacters(in: .whitespaces)
        if opt.hasPrefix("domain=") {
          let list = opt.dropFirst("domain=".count)
          for token in list.split(separator: "|") {
            let t = token.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if t.hasPrefix("~") {
              unlessDomain.append("*" + String(t.dropFirst()))
            } else {
              ifDomain.append("*" + t)
            }
          }
          continue
        }
        // `match-case` and `sitekey=...` are valid ABP options
        // that have no Safari equivalent but don't change block
        // semantics on their own. Accept them so the rule isn't
        // rejected, but map them to no trigger field.
        if opt == "match-case" || opt == "~match-case" { continue }
        if opt.hasPrefix("sitekey=") { continue }
        guard recognizedOptions.contains(opt) else {
          // Unknown option → reject the whole rule to avoid
          // incorrect behaviour.
          return []
        }
        if let mapped = mapResourceType(opt) {
          resourceType.append(mapped)
        }
        // WebKit accepts exactly one load-type value. Later
        // specifiers win; `$~third-party,first-party` collapses
        // to `first-party`.
        if opt == "third-party" || opt == "3p" || opt == "~first-party"
          || opt == "~1p"
        {
          loadType = "third-party"
        }
        if opt == "~third-party" || opt == "~3p" || opt == "first-party"
          || opt == "1p"
        {
          loadType = "first-party"
        }
      }
    }

    // WebKit's Content Blocker compiler rejects triggers that carry
    // both `if-domain` and `unless-domain`. When the rule asks for
    // both, honour the positive list (where the filter author most
    // wants the block to fire); dropping the negative domains keeps
    // the rule useful on the rest of its intended scope rather than
    // forcing a compile-time reject that takes the whole batch down.
    if !ifDomain.isEmpty, !unlessDomain.isEmpty {
      unlessDomain = []
    }

    let actionType = isException ? "ignore-previous-rules" : "block"
    return patterns.map { pattern in
      let trigger = Trigger(
        urlFilter: pattern,
        urlFilterIsCaseSensitive: nil,
        resourceType: resourceType.isEmpty ? nil : resourceType,
        loadType: loadType.map { [$0] },
        ifDomain: ifDomain.isEmpty ? nil : ifDomain,
        unlessDomain: unlessDomain.isEmpty ? nil : unlessDomain
      )
      return Rule(
        trigger: trigger,
        action: Action(type: actionType, selector: nil)
      )
    }
  }

  private static func mapResourceType(_ opt: String) -> String? {
    switch opt {
    case "script": return "script"
    case "image": return "image"
    case "xhr", "xmlhttprequest": return "raw"
    case "subdocument", "frame": return "document"
    case "stylesheet", "css": return "style-sheet"
    case "media": return "media"
    case "websocket": return "websocket"
    case "font": return "font"
    case "document", "doc": return "document"
    case "popup": return "popup"
    case "object": return "raw"
    case "ping": return "raw"
    case "other": return "other"
    default: return nil
    }
  }

  // MARK: - Pattern → regex

  /// Convert an ABP pattern body (no `$options`, no `@@` prefix) into
  /// regex strings that Safari's NSRegularExpression-based matcher
  /// accepts. Returns one or two variants because the ABP separator
  /// `^` covers both "separator character" and "URL end"; expressing
  /// that as `|$` alternation is rejected by WebKit's compiler, so a
  /// trailing `^` fans out into two rules — one matching a separator
  /// char, one matching URL end.
  static func patternToRegexes(_ pattern: String) -> [String] {
    var input = pattern[...]

    let anchorStart = input.hasPrefix("||")
    let plainStart = input.hasPrefix("|") && !anchorStart
    let anchorEnd = input.hasSuffix("|")

    var prefix = ""
    if anchorStart {
      input = input.dropFirst(2)
      // Match http(s):// plus optional subdomain — the standard
      // ABP `||domain^` semantics. WebKit's Content Blocker regex
      // subset rejects capturing groups in many positions, so use
      // a non-capturing group.
      prefix = #"^https?://(?:[^/]+\.)?"#
    } else if plainStart {
      input = input.dropFirst()
      prefix = "^"
    } else {
      prefix = ".*"
    }
    if anchorEnd {
      input = input.dropLast()
    }

    // Detect a trailing ABP separator so we can emit a URL-end
    // variant alongside the separator-char variant.
    let trailingSeparator = input.last == "^"
    if trailingSeparator {
      input = input.dropLast()
    }

    var body = ""
    for ch in input {
      switch ch {
      case "*":
        body += ".*"
      case "^":
        // Interior separator: a single separator char. The
        // "or URL end" half of the ABP definition is handled
        // only for the trailing occurrence (see above).
        body += #"[/:?=&]"#
      case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "$":
        body += "\\" + String(ch)
      default:
        body.append(ch)
      }
    }

    let endAnchor = anchorEnd ? "$" : ""

    var results: [String] = []
    if trailingSeparator {
      // Variant 1: URL ends exactly here (e.g. root domain with
      // no path), using the end-of-string anchor.
      let endVariant = prefix + body + "$"
      if endVariant != ".*" { results.append(endVariant) }
      // Variant 2: separator character at this position.
      let sepVariant = prefix + body + #"[/:?=&]"# + endAnchor
      if sepVariant != ".*" { results.append(sepVariant) }
    } else {
      let single = prefix + body + endAnchor
      if single != ".*" { results.append(single) }
    }
    return results
  }
}
