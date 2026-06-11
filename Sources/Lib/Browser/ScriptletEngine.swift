import Foundation
import WebKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "Scriptlet")

/// Main-world scriptlet injection for the built-in content blocker.
///
/// Scriptlets patch page globals (`JSON.parse`, `ytInitialPlayerResponse`,
/// …) and must run before the page's own scripts read them, so the
/// cosmetic engine's page-commit IPC round-trip is not an option: an
/// async query loses the race. The engine instead bakes a
/// host → invocation index into a single document-start `WKUserScript`
/// targeted at `WKContentWorld.page` — the world page content itself
/// uses. The isolated `.defaultClient` world the cosmetic runtime
/// lives in cannot reach page globals at all.
///
/// The baked index and whitelist are snapshotted when the web view is
/// built; later changes reach existing panes on the next web view
/// rebuild (suspend → restore), the same staleness contract the
/// cosmetic index has.
@MainActor
public final class ScriptletEngine {
  public static let shared = ScriptletEngine()

  /// Host token (as written in a filter, matched against the page
  /// hostname and its parent domains in the runtime) → scriptlet
  /// invocations, each encoded `[name, arg…]`. Built from the
  /// `##+js(...)` rules of the enabled filter sources by ``start()``;
  /// empty until that runs. The published filterlists drive which
  /// hosts are covered — YouTube's player-response ad pruning is one
  /// such rule set, not a special case here.
  public private(set) var index: [String: [[String]]] = [:]

  /// Scriptlet names the bundled library implements, kept in sync by
  /// hand with the `registry` object in scriptlets.js. A name listed
  /// here that the library lacks would admit a rule the runtime then
  /// silently skips; a name the library has but is missing here drops
  /// a rule we could otherwise run.
  nonisolated static let supportedScriptlets: Set<String> = [
    "set-constant", "set",
    "json-prune",
    "json-prune-fetch-response",
    "json-prune-xhr-response",
  ]

  private init() {}

  // MARK: - Index build

  /// Build the scriptlet index from the cached filter sources. Call
  /// after ``AdBlocker/start()`` has warmed the cache, alongside the
  /// cosmetic engine. Reads cache only; a missing entry is skipped and
  /// picked up on the next launch once AdBlocker finishes downloading.
  ///
  /// Like the cosmetic index, this populates state read at web view
  /// construction. A web view built before it completes — the first
  /// few hundred ms of a launch, or any pane on the very first launch
  /// before the initial download — carries an empty index until it is
  /// rebuilt on suspend → restore.
  public func start() async {
    var texts: [String] = []
    for source in AdBlocker.allSources where AdBlocker.isSourceEnabled(source) {
      if let text = await readCached(source.cacheFilename) {
        texts.append(text)
      }
    }
    let built = await Task.detached(priority: .userInitiated) {
      Self.buildIndex(from: texts)
    }.value
    self.index = built
    logger.info("index built: hosts=\(built.count, privacy: .public)")
  }

  private func readCached(_ filename: String) async -> String? {
    let url = AdBlocker.cacheRoot.appendingPathComponent(filename)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  /// Parse the `##+js(...)` rules out of the given filter texts into a
  /// host → invocation index, keeping only invocations whose scriptlet
  /// the library implements. Host-less (generic) scriptlets are
  /// dropped: a page-wide global patch with no host scope is too blunt
  /// to ship from a third-party list.
  nonisolated static func buildIndex(from texts: [String]) -> [String: [[String]]] {
    var index: [String: [[String]]] = [:]
    for text in texts {
      text.enumerateLines { line, _ in
        guard let parsed = ScriptletParser.parseLine(line),
          !parsed.domains.isEmpty,
          let name = parsed.invocation.first,
          supportedScriptlets.contains(name)
        else { return }
        for domain in parsed.domains {
          index[domain, default: []].append(parsed.invocation)
        }
      }
    }
    return index
  }

  /// Install the scriptlet user script into a pane's configuration.
  /// Must run before the `WKWebView` is constructed — the
  /// configuration is snapshotted at init time, like the other
  /// content-blocker layers wired in `makeWebView`.
  public func attach(to config: WKWebViewConfiguration) {
    guard AdBlocker.allSources.contains(where: { AdBlocker.isSourceEnabled($0) })
    else {
      // The content blocker as a whole is switched off; injecting
      // main-world patches anyway would be the one layer the user
      // cannot disable.
      logger.info("attach skipped — every filter source is disabled")
      return
    }
    let whitelist = AdBlockerWhitelistStore.shared.allHosts
    let source = Self.makeSource(index: index, whitelist: whitelist)
    guard let source else {
      logger.error("attach skipped — scriptlet source could not be built")
      return
    }
    config.userContentController.addUserScript(
      WKUserScript(
        source: source,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: .page
      )
    )
    attachCounter += 1
    logger.info(
      """
      attach → pane #\(self.attachCounter) \
      (hosts=\(self.index.count) whitelist=\(whitelist.count) world=page)
      """
    )
  }

  /// Incremented on every ``attach(to:)`` call so pane log lines
  /// carry a monotonic id; instance property for the same `@MainActor`
  /// isolation reason as the cosmetic engine's counter.
  private var attachCounter: Int = 0

  // MARK: - Source assembly

  /// Compose the injected script: the index and whitelist baked as
  /// `const` declarations plus the scriptlet library, wrapped in one
  /// IIFE so neither const leaks into the page's global scope. JSON
  /// is emitted with sorted keys so the source is deterministic for
  /// a given index (stable across launches, diffable in logs).
  static func makeSource(
    index: [String: [[String]]],
    whitelist: [String]
  ) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard
      let indexData = try? encoder.encode(index),
      let indexJSON = String(data: indexData, encoding: .utf8),
      let whitelistData = try? encoder.encode(whitelist.sorted()),
      let whitelistJSON = String(data: whitelistData, encoding: .utf8)
    else {
      return nil
    }
    return """
      (() => {
      const __E05_SCRIPTLET_INDEX__ = \(indexJSON);
      const __E05_SCRIPTLET_WHITELIST__ = \(whitelistJSON);
      \(Self.librarySource)
      })();
      """
  }

  /// The scriptlet library, read once from the bundled resource. A
  /// missing resource means Package.swift's `resources:` declaration
  /// and the Resources/ directory have drifted apart — same failure
  /// contract as the cosmetic runtime.
  private static let librarySource: String = {
    guard
      let url = Bundle.module.url(
        forResource: "scriptlets", withExtension: "js"
      )
    else {
      logger.error("scriptlets.js missing from E05Lib bundle resources")
      preconditionFailure("scriptlets.js missing from E05Lib bundle resources")
    }
    do {
      return try String(contentsOf: url, encoding: .utf8)
    } catch {
      logger.error(
        "failed to read scriptlets.js: \(error.localizedDescription, privacy: .public)"
      )
      preconditionFailure("failed to read scriptlets.js: \(error)")
    }
  }()
}

/// Parser for ABP `##+js(...)` scriptlet-injection rules, the cosmetic
/// shape ``CosmeticFilterEngine`` deliberately drops. The grammar is
/// `domains##+js(name, arg, …)`: the prefix is the same comma-separated
/// hostname list cosmetic rules use, and the body is the scriptlet name
/// followed by its arguments.
public enum ScriptletParser {
  public struct ParsedScriptlet: Equatable, Sendable {
    /// Positive hostname tokens. Empty = generic (host-less) rule.
    public let domains: [String]
    /// Hostname tokens with a leading `~` stripped. Carried through
    /// for the host-matching follow-up; not yet acted on.
    public let excludedDomains: [String]
    /// `[name, arg…]`, ready to encode into the injected index.
    public let invocation: [String]
  }

  public static func parseLine(_ raw: String) -> ParsedScriptlet? {
    let line = raw.trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else {
      return nil
    }
    // `#@#+js(...)` cancels a scriptlet on this host. Rare; dropping
    // it leaves the scriptlet applied, the safe default when we cannot
    // model the exception.
    if line.contains("#@#+js(") { return nil }
    guard let open = line.range(of: "##+js(") else { return nil }
    let prefix = line[..<open.lowerBound]
    let afterOpen = line[open.upperBound...]
    guard let close = afterOpen.lastIndex(of: ")") else { return nil }
    let body = String(afterOpen[..<close])

    var domains: [String] = []
    var excluded: [String] = []
    for token in prefix.split(separator: ",") {
      let t = token.trimmingCharacters(in: .whitespaces)
      guard !t.isEmpty else { continue }
      if t.hasPrefix("~") {
        let d = String(t.dropFirst()).lowercased()
        if !d.isEmpty { excluded.append(d) }
      } else {
        domains.append(t.lowercased())
      }
    }

    let invocation = splitArgs(body)
    guard let name = invocation.first, !name.isEmpty else { return nil }
    return ParsedScriptlet(
      domains: domains, excludedDomains: excluded, invocation: invocation)
  }

  /// Split a scriptlet argument body on commas, honouring `\,` as a
  /// literal comma (uBO's escape for arguments — notably regex values —
  /// that contain commas). Other backslash escapes pass through
  /// untouched so regex bodies survive intact.
  static func splitArgs(_ body: String) -> [String] {
    var args: [String] = []
    var current = ""
    var escaped = false
    for ch in body {
      if escaped {
        if ch != "," { current.append("\\") }
        current.append(ch)
        escaped = false
      } else if ch == "\\" {
        escaped = true
      } else if ch == "," {
        args.append(current.trimmingCharacters(in: .whitespaces))
        current = ""
      } else {
        current.append(ch)
      }
    }
    if escaped { current.append("\\") }
    args.append(current.trimmingCharacters(in: .whitespaces))
    return args
  }
}
