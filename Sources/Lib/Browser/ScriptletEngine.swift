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

  /// Hostname token (as written in a filter, matched against the
  /// page hostname and its parent domains) → scriptlet invocations,
  /// each encoded `[name, arg…]`. Currently a built-in set covering
  /// YouTube's player-response ad fields — the equivalent of the
  /// uAssets `##+js(...)` rules that uBlock Origin applies there,
  /// expressed against our reimplemented scriptlet library.
  public private(set) var index: [String: [[String]]] =
    ScriptletEngine.builtinRules

  /// YouTube embeds its ad schedule in the player API JSON
  /// (`ytInitialPlayerResponse` and the `youtubei/v1/player`
  /// response); ads share the `<video>` element and the stream with
  /// the main content, so neither network rules nor cosmetic hides
  /// can remove them. Pinning the ad fields to `undefined` before
  /// the player reads them is the only layer that works.
  static let builtinRules: [String: [[String]]] = [
    "youtube.com": [
      ["set-constant", "ytInitialPlayerResponse.playerAds", "undefined"],
      ["set-constant", "ytInitialPlayerResponse.adPlacements", "undefined"],
      ["set-constant", "ytInitialPlayerResponse.adSlots", "undefined"],
      [
        "json-prune",
        "adPlacements adSlots playerAds "
          + "playerResponse.adPlacements playerResponse.adSlots "
          + "playerResponse.playerAds",
        "",
      ],
    ]
  ]

  private init() {}

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
