import AppKit
import CryptoKit
import WebKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "AdBlocker")

/// Layer A of the e05 adblocker stack: a built-in content blocker that
/// compiles a Safari Content Blocker rule list from an ABP/EasyList-format
/// filter and attaches it to every browser pane's ``WKWebViewConfiguration``.
///
/// WebKit evaluates ``WKContentRuleList`` natively in the network
/// process, so network blocks and declarative `css-display-none`
/// selectors apply without any JS on the page. Procedural cosmetic
/// (`:has-text()`, `:upward()` …) runs in a separate content-script
/// runtime inside ``CosmeticFilterEngine``; scriptlet injection is
/// not implemented.
///
/// Extensions that ship their own ad filtering (layer B, `WKWebExtension`)
/// stay out of this path entirely; placing an adblocker extension under
/// `ExtensionController.extensionsRoot` on top of this would double-block
/// and is not a supported configuration.
///
/// ## Multi-list trade-off
/// Sources are compiled into one ``WKContentRuleList`` per source and all
/// installed together on each browser pane. WebKit caps a single compiled
/// list at roughly 150,000 rules; merging every source into one list
/// overruns that ceiling and makes the blocker non-installable. The cost
/// of this split is that `ignore-previous-rules` (`@@` in ABP) acts only
/// within its own list — an exception declared in EasyPrivacy cannot
/// cancel a block declared in EasyList. Filterlists are authored with
/// the intra-list assumption anyway, so the practical impact is limited
/// to cross-list overlaps that are already rare by design.
///
/// On-disk filterlist copies live under
/// `~/Library/Caches/<bundle-id>/adblocker/` rather than
/// `Application Support` because they are regenerable from the
/// upstream URL on the next refresh — losing them costs only one
/// extra fetch on next launch, so Time Machine and other backup
/// tooling can skip them.
@MainActor
public final class AdBlocker {
  public static let shared = AdBlocker()

  /// Posted on ``NotificationCenter.default`` when ``ruleList`` becomes
  /// available. Browser panes created before compilation finishes use
  /// this to attach the rule list retroactively.
  public static let ruleListDidChangeNotification = Notification.Name(
    "e05.AdBlocker.ruleListDidChange"
  )

  /// A filterlist source used to build the combined rule list. Each
  /// source is downloaded on first run, cached under the directory
  /// returned by `cacheRoot` (see class doc for the
  /// `Caches`-vs-`Application Support` rationale), converted to
  /// Safari JSON, and merged before compilation.
  ///
  /// `homepage` is the project page surfaced in the Settings Content
  /// Blocker tab so users can read the upstream filterlist's terms
  /// before relying on it. The raw `url` itself points at the
  /// filterlist text and is unsuited for a credit link.
  public struct FilterSource: Identifiable, Sendable {
    /// Identifier-safe token used as part of the compiled rule
    /// list's store key (`e05-adblocker-v1-<id>-<hash>`) and as the
    /// per-source enable flag persisted in preferences.
    public let id: String
    public let name: String
    /// Upstream filterlist URL and the on-disk cache filename are
    /// internal-only — UI callers should never need either, and
    /// keeping them out of the public surface keeps a future
    /// schema change cheap.
    let url: URL
    let cacheFilename: String
    public let homepage: URL?

    init(
      id: String,
      name: String,
      url: URL,
      cacheFilename: String,
      homepage: URL?
    ) {
      self.id = id
      self.name = name
      self.url = url
      self.cacheFilename = cacheFilename
      self.homepage = homepage
    }
  }

  /// The filterlist bundle. EasyList + EasyPrivacy give broad coverage
  /// of global ad networks and trackers; AdGuard Japanese layers in
  /// local networks that the English lists miss.
  public static let allSources: [FilterSource] = [
    FilterSource(
      id: "easylist",
      name: "EasyList",
      url: URL(string: "https://easylist.to/easylist/easylist.txt")!,
      cacheFilename: "easylist.txt",
      homepage: URL(string: "https://easylist.to/")
    ),
    FilterSource(
      id: "easyprivacy",
      name: "EasyPrivacy",
      url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
      cacheFilename: "easyprivacy.txt",
      homepage: URL(string: "https://easylist.to/")
    ),
    FilterSource(
      id: "adguard-japanese",
      name: "AdGuard Japanese Filter",
      url: URL(string: "https://filters.adtidy.org/extension/safari/filters/7.txt")!,
      cacheFilename: "adguard-japanese.txt",
      homepage: URL(string: "https://adguard.com/kb/general/ad-filtering/adguard-filters/")
    ),
  ]

  /// Re-download a cached filterlist when its on-disk copy is older
  /// than this. EasyList publishes daily; a week is generous enough to
  /// survive short outages while keeping rule rot bounded.
  private static let cacheMaxAge: TimeInterval = 7 * 24 * 60 * 60

  /// Prefix for identifiers stored in ``WKContentRuleListStore``. Each
  /// compiled list's full identifier is
  /// `e05-adblocker-v1-<sourceName>-<contentHash>`; changing the
  /// converter output or a source's text flips the hash, which makes
  /// WebKit recompile that source on the next launch.
  private static let ruleListIdentifierPrefix = "e05-adblocker-v1-"

  public private(set) var ruleLists: [WKContentRuleList] = []

  private init() {}

  /// Root directory for cached filterlist sources. Resolved via
  /// `E05Paths.default.cacheDir` — `Caches/<bundle-id>/` is not
  /// guaranteed to exist on first launch, so callers writing to
  /// this dir must ensure it exists (`download(...)` does so via
  /// `createDirectory(withIntermediateDirectories: true)`).
  public static var cacheRoot: URL {
    E05Paths.default.cacheDir.appendingPathComponent(
      "adblocker", isDirectory: true)
  }

  /// Drop the on-disk filterlist cache. The compiled
  /// `WKContentRuleList` objects already attached to live web views
  /// stay active for the rest of the session — the next launch goes
  /// through `start()` which re-downloads, re-converts, and re-
  /// compiles. Used by the Settings Reset "Clear Cache" action;
  /// matches `FaviconCache.shared.clearAll` as an instance API on
  /// the shared singleton so call sites stay symmetric.
  public func clearCache() {
    let dir = Self.cacheRoot
    let fm = FileManager.default
    guard fm.fileExists(atPath: dir.path) else { return }
    do {
      let entries = try fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)
      for entry in entries {
        try fm.removeItem(at: entry)
      }
    } catch {
      logger.error(
        "Failed to clear adblocker cache: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Ensure a compiled ``WKContentRuleList`` is available. Fast path
  /// (all sources cached and fresh) hits the precompiled binary that
  /// ``WKContentRuleListStore`` keeps around; slow path downloads,
  /// converts, merges, and compiles a new list keyed by a content
  /// hash so filterlist updates invalidate stale binaries.
  public func start() async {
    // `WKContentRuleListStore.default()` is bridged as Optional even
    // though the ObjC signature returns `instancetype`. Keep the
    // guard so a nil store (unlikely but possible under unusual
    // sandbox configurations) fails gracefully.
    guard let store = WKContentRuleListStore.default() else {
      logger.error("WKContentRuleListStore.default() returned nil")
      return
    }

    do {
      try FileManager.default.createDirectory(
        at: Self.cacheRoot,
        withIntermediateDirectories: true
      )
    } catch {
      logger.error(
        """
        Failed to create adblocker cache dir: \
        \(String(describing: error), privacy: .public)
        """
      )
      return
    }

    // Compile each source into its own ``WKContentRuleList``. WebKit
    // caps a single compiled list at ~150,000 rules, so merging
    // EasyList + EasyPrivacy + AdGuard Japanese into one list blows
    // past the ceiling and makes the entire blocker non-installable.
    // `WKUserContentController.add(_:)` accepts multiple rule lists
    // per web view, so the natural fix is one list per source.
    var compiledIdentifiers: [String] = []
    let enabledIds = PreferencesStore.shared.preferences.adblockerEnabledSources
    for source in Self.allSources {
      if let enabledIds, !enabledIds.contains(source.id) {
        logger.info(
          "Skipping disabled source '\(source.id, privacy: .public)'"
        )
        continue
      }
      guard let text = await loadFilterText(source: source) else { continue }
      let hash = Self.shortHash(for: [text])
      let identifier = "\(Self.ruleListIdentifierPrefix)\(source.id)-\(hash)"
      compiledIdentifiers.append(identifier)

      if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
        self.ruleLists.append(cached)
        logger.info(
          """
          Loaded compiled '\(source.name, privacy: .public)' \
          '\(identifier, privacy: .public)' from WebKit store
          """
        )
        continue
      }

      // Convert off the main actor — each source is multi-megabyte
      // text and parsing blocks the UI if kept on MainActor. The
      // `maxRules` ceiling sits just under WebKit's documented
      // per-list limit (150,000) so a large source truncates
      // gracefully rather than forcing a blanket compile reject.
      let sourceName = source.name
      let (rules, skipped) = await Task.detached(priority: .userInitiated) {
        ABPtoSafariConverter.convert(text, maxRules: 140_000)
      }.value
      logger.info(
        """
        Converted '\(sourceName, privacy: .public)': \
        \(rules.count) rules, \(skipped) skipped
        """
      )
      guard !rules.isEmpty else { continue }

      if let compiled = await compile(
        rules: rules,
        store: store,
        identifier: identifier
      ) {
        self.ruleLists.append(compiled)
        logger.info(
          """
          Compiled '\(source.name, privacy: .public)' \
          '\(identifier, privacy: .public)' (\(rules.count) rules)
          """
        )
        continue
      }

      // Per-source compile rejected. Salvage by dropping the
      // individual offending rules, then install the remainder.
      if let salvaged = await salvageCompile(
        rules: rules,
        store: store,
        identifier: identifier,
        sourceName: source.name
      ) {
        self.ruleLists.append(salvaged)
      }
    }

    if ruleLists.isEmpty {
      logger.error("No sources produced a usable rule list")
      return
    }
    logger.info(
      "Installed \(self.ruleLists.count) rule lists across \(Self.allSources.count) sources"
    )
    broadcastRuleListChange()
    Task {
      await self.cleanupStaleStoreEntries(
        current: compiledIdentifiers,
        store: store
      )
    }
  }

  /// Notify every observer that the rule list set has changed.
  /// Browser panes observe this once at first compile and re-observe
  /// on every reload (e.g. whitelist edit), each time removing the
  /// previous lists from their `WKUserContentController` before
  /// adding the current `ruleLists`.
  private func broadcastRuleListChange() {
    NotificationCenter.default.post(
      name: Self.ruleListDidChangeNotification,
      object: self
    )
  }

  /// Re-run the compile path so the live web views pick up a
  /// per-source enable change. The previously installed
  /// ``WKContentRuleList`` objects are dropped from this store's
  /// `ruleLists` array; the per-pane observer rebuilds the user
  /// content controller's rule list set from the new array on the
  /// `ruleListDidChange` notification that `start()` re-posts at
  /// the end. The procedural cosmetic engine is rebuilt against
  /// the same per-source enable state in lock-step — a disabled
  /// source has to drop both its declarative and its cosmetic
  /// contributions for the user to see a change.
  public func reload() async {
    ruleLists = []
    await start()
    await CosmeticFilterEngine.shared.start()
  }

  /// Force a fresh download of every enabled filterlist source by
  /// dropping the on-disk cache first, then re-running the compile
  /// path. The disk wipe means ``loadFilterText`` cannot fall back
  /// to a stale cached copy, so the refresh genuinely fetches from
  /// upstream regardless of the 7-day staleness window. Failure to
  /// reach the upstream still leaves the user covered: the previous
  /// compiled binary lives in ``WKContentRuleListStore`` keyed by
  /// content hash, and ``start()`` re-attaches it when the converter
  /// produces no rules.
  public func refreshFilterlists() async {
    clearCache()
    await reload()
    PreferencesStore.shared.update {
      $0.adblockerLastRefreshedAt = Date()
    }
  }

  /// Default cadence between automatic filterlist refreshes, in
  /// hours. EasyList publishes daily; weekly keeps the install
  /// fresh enough for rule rot to stay bounded while leaving room
  /// for outage tolerance via the existing 7-day cache staleness
  /// window in ``loadFilterText``.
  public static let defaultAutoUpdateIntervalHours: Int = 168

  /// Short hex digest used to key compiled rule lists. Changing the
  /// converter or any source text flips this, which makes WebKit
  /// recompile on the next launch without a manual identifier bump.
  private static func shortHash(for texts: [String]) -> String {
    var hasher = SHA256()
    for t in texts {
      hasher.update(data: Data(t.utf8))
    }
    let digest = hasher.finalize()
    return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
  }

  /// Remove stale entries the store may be hanging on to from previous
  /// launches (old content hashes, leftover probe identifiers). Safe
  /// to run opportunistically in the background.
  private func cleanupStaleStoreEntries(
    current: [String],
    store: WKContentRuleListStore
  ) async {
    // Offline / download-failed launches can leave `current` empty.
    // Skip the sweep in that case so a transient outage does not
    // wipe the previous launch's valid compiled artifacts and force
    // a re-download on the next startup.
    guard !current.isEmpty else { return }
    let keep = Set(current)
    let identifiers = await store.availableIdentifiers() ?? []
    for id in identifiers
    where !keep.contains(id)
      && (id.hasPrefix(Self.ruleListIdentifierPrefix)
        || id.hasPrefix(Self.probeIdentifierPrefix)
        || id.hasPrefix("e05-combined-v1-"))
    {
      do {
        try await store.removeContentRuleList(forIdentifier: id)
        logger.debug(
          "Removed stale rule list '\(id, privacy: .public)' from WebKit store"
        )
      } catch {
        logger.debug(
          """
          Failed to remove stale rule list '\(id, privacy: .public)': \
          \(String(describing: error), privacy: .public)
          """
        )
      }
    }
  }

  // MARK: - Compile

  private static let probeIdentifierPrefix = "e05-adblocker-probe-"

  private func compile(
    rules: [ABPtoSafariConverter.Rule],
    store: WKContentRuleListStore,
    identifier: String
  ) async -> WKContentRuleList? {
    guard let json = encode(rules: rules) else { return nil }
    do {
      return try await store.compileContentRuleList(
        forIdentifier: identifier,
        encodedContentRuleList: json
      )
    } catch {
      return nil
    }
  }

  private func encode(rules: [ABPtoSafariConverter.Rule]) -> String? {
    do {
      let data = try JSONEncoder().encode(rules)
      return String(data: data, encoding: .utf8)
    } catch {
      logger.error(
        "Rule list JSON encoding failed: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  /// Tries to probe-compile the full rule set; if that fails, splits
  /// the slice into halves and recurses. Single rules that still fail
  /// are logged and dropped. Accepted rules accumulate into the final
  /// install set so a handful of bad rules can't poison the whole
  /// filterlist.
  private func salvageCompile(
    rules: [ABPtoSafariConverter.Rule],
    store: WKContentRuleListStore,
    identifier: String,
    sourceName: String
  ) async -> WKContentRuleList? {
    let accepted = await salvageProbe(
      rules: rules,
      store: store,
      offsetInOriginal: 0,
      depth: 0
    )

    guard !accepted.isEmpty else {
      logger.error(
        """
        No rules from '\(sourceName, privacy: .public)' survived \
        salvage — list not installed
        """
      )
      return nil
    }

    if let compiled = await compile(
      rules: accepted,
      store: store,
      identifier: identifier
    ) {
      let dropped = rules.count - accepted.count
      logger.info(
        """
        Installed salvaged '\(sourceName, privacy: .public)' \
        '\(identifier, privacy: .public)' \
        (\(accepted.count) / \(rules.count) rules, \(dropped) dropped)
        """
      )
      return compiled
    }

    logger.error(
      """
      Salvage of '\(sourceName, privacy: .public)' succeeded on \
      chunks but final compile failed — likely exceeds the per-list limit
      """
    )
    return nil
  }

  /// Divide-and-conquer: probe-compile `rules`; on failure split in half
  /// and recurse. Single-rule slices that still fail are logged as the
  /// offending rule and dropped from the returned array. Probe entries
  /// are removed from the store eagerly so the traversal doesn't
  /// accumulate tens of megabytes of compiled artifacts on disk.
  private func salvageProbe(
    rules: [ABPtoSafariConverter.Rule],
    store: WKContentRuleListStore,
    offsetInOriginal: Int,
    depth: Int
  ) async -> [ABPtoSafariConverter.Rule] {
    if rules.isEmpty { return [] }

    let probeID = "\(Self.probeIdentifierPrefix)\(offsetInOriginal)-\(rules.count)-d\(depth)"
    if await compile(
      rules: rules,
      store: store,
      identifier: probeID
    ) != nil {
      try? await store.removeContentRuleList(forIdentifier: probeID)
      return rules
    }

    if rules.count == 1 {
      let json = encode(rules: rules) ?? "(unencodable)"
      logger.error(
        """
        Dropping unsupported rule at source index \(offsetInOriginal): \
        \(json, privacy: .public)
        """
      )
      return []
    }

    let mid = rules.count / 2
    let left = Array(rules.prefix(mid))
    let right = Array(rules.suffix(rules.count - mid))
    let lAccepted = await salvageProbe(
      rules: left,
      store: store,
      offsetInOriginal: offsetInOriginal,
      depth: depth + 1
    )
    let rAccepted = await salvageProbe(
      rules: right,
      store: store,
      offsetInOriginal: offsetInOriginal + mid,
      depth: depth + 1
    )
    return lAccepted + rAccepted
  }

  // MARK: - Attach

  /// Attach every compiled rule list to a configuration. Must be
  /// called before the ``WKWebView`` is initialized because
  /// ``WKWebViewConfiguration`` is snapshotted at init time. When
  /// ``start()`` has not yet completed the pane observes
  /// ``ruleListDidChangeNotification`` and attaches to its live
  /// ``WKUserContentController`` once available.
  public func attach(to config: WKWebViewConfiguration) {
    if ruleLists.isEmpty {
      logger.debug(
        "No rule lists available yet — pane will attach on ruleListDidChange"
      )
      return
    }
    for list in ruleLists {
      config.userContentController.add(list)
    }
  }

  // MARK: - Filterlist IO

  private func loadFilterText(source: FilterSource) async -> String? {
    let cacheURL = Self.cacheRoot.appendingPathComponent(source.cacheFilename)
    let fm = FileManager.default

    if fm.fileExists(atPath: cacheURL.path),
      let cached = try? String(contentsOf: cacheURL, encoding: .utf8),
      !cached.isEmpty
    {
      let attrs = try? fm.attributesOfItem(atPath: cacheURL.path)
      let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
      let age = Date().timeIntervalSince(mtime)
      if age < Self.cacheMaxAge {
        logger.info(
          """
          Loaded '\(source.name, privacy: .public)' from cache \
          (\(cached.count) bytes, age \(Int(age))s)
          """
        )
        return cached
      }
      logger.info(
        """
        '\(source.name, privacy: .public)' cache is \(Int(age))s old \
        — refreshing
        """
      )
      if let fresh = await downloadFilterText(source: source, cacheURL: cacheURL) {
        return fresh
      }
      // Refresh failed; fall back to the stale cached copy rather
      // than leaving the user unprotected.
      logger.warning(
        """
        Refresh failed for '\(source.name, privacy: .public)' \
        — using stale cache
        """
      )
      return cached
    }

    return await downloadFilterText(source: source, cacheURL: cacheURL)
  }

  private func downloadFilterText(
    source: FilterSource,
    cacheURL: URL
  ) async -> String? {
    logger.info(
      """
      Downloading '\(source.name, privacy: .public)' from \
      \(source.url.absoluteString, privacy: .public)
      """
    )
    do {
      let (data, response) = try await URLSession.shared.data(from: source.url)
      if let http = response as? HTTPURLResponse,
        !(200..<300).contains(http.statusCode)
      {
        logger.error(
          """
          '\(source.name, privacy: .public)' HTTP \(http.statusCode) \
          — skipping this source
          """
        )
        return nil
      }
      guard let text = String(data: data, encoding: .utf8) else {
        logger.error(
          "'\(source.name, privacy: .public)' payload is not valid UTF-8"
        )
        return nil
      }
      try? text.write(to: cacheURL, atomically: true, encoding: .utf8)
      logger.info(
        """
        Downloaded '\(source.name, privacy: .public)' \
        (\(text.count) bytes), cached
        """
      )
      return text
    } catch {
      logger.error(
        """
        '\(source.name, privacy: .public)' download failed: \
        \(String(describing: error), privacy: .public)
        """
      )
      return nil
    }
  }
}
