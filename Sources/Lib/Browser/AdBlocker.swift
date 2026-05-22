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

  /// Coarse grouping a ``FilterSource`` falls into. Drives both the
  /// Settings UI sectioning (Default vs Optional) and the
  /// initial-enable computation when the user has not made an explicit
  /// per-source choice yet.
  public enum SourceCategory: String, Sendable {
    /// Default-enabled global coverage (ads + privacy + cookie banners).
    /// Removing one of these noticeably degrades blocking on most sites.
    case core
    /// Default-disabled built-in source. Mostly regional filters and
    /// niche categories (mobile-app promo, malware) the user opts in
    /// to from the Settings tab.
    case optional
  }

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
    public let category: SourceCategory
    /// Initial enable state when the user has not made a choice yet
    /// (i.e. `adblockerEnabledSources == nil`). Almost always tracks
    /// `category` (`.core` true, `.optional` false) but the two stay
    /// decoupled so a future category can pick its own default.
    public let defaultEnabled: Bool

    init(
      id: String,
      name: String,
      url: URL,
      cacheFilename: String,
      homepage: URL?,
      category: SourceCategory,
      defaultEnabled: Bool
    ) {
      self.id = id
      self.name = name
      self.url = url
      self.cacheFilename = cacheFilename
      self.homepage = homepage
      self.category = category
      self.defaultEnabled = defaultEnabled
    }
  }

  /// The shipped catalog. Default sources cover global ads + privacy +
  /// cookie banners with no locale bias; optional sources expose
  /// regional and niche lists the user opts in to from Settings.
  ///
  /// Curation references Brave's `brave/adblock-resources` (MPL 2.0)
  /// `filter_lists/list_catalog.json`. Each list's text content stays
  /// under its upstream license — e05 ships no filterlist bytes, only
  /// URLs the user agrees to fetch.
  public static let builtInSources: [FilterSource] = [
    // MARK: Core (default enabled)
    FilterSource(
      id: "easylist",
      name: "EasyList",
      url: URL(string: "https://easylist.to/easylist/easylist.txt")!,
      cacheFilename: "easylist.txt",
      homepage: URL(string: "https://easylist.to/"),
      category: .core, defaultEnabled: true
    ),
    FilterSource(
      id: "easyprivacy",
      name: "EasyPrivacy",
      url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
      cacheFilename: "easyprivacy.txt",
      homepage: URL(string: "https://easylist.to/"),
      category: .core, defaultEnabled: true
    ),
    FilterSource(
      id: "ubo-filters",
      name: "uBlock Origin Filters",
      url: URL(
        string:
          "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt"
      )!,
      cacheFilename: "ubo-filters.txt",
      homepage: URL(string: "https://github.com/uBlockOrigin/uAssets"),
      category: .core, defaultEnabled: true
    ),
    FilterSource(
      id: "ubo-privacy",
      name: "uBlock Origin Privacy",
      url: URL(
        string:
          "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/privacy.txt"
      )!,
      cacheFilename: "ubo-privacy.txt",
      homepage: URL(string: "https://github.com/uBlockOrigin/uAssets"),
      category: .core, defaultEnabled: true
    ),
    FilterSource(
      id: "fanboy-cookie",
      name: "EasyList Cookie",
      url: URL(string: "https://secure.fanboy.co.nz/fanboy-cookiemonster_ubo.txt")!,
      cacheFilename: "fanboy-cookie.txt",
      homepage: URL(string: "https://www.fanboy.co.nz/"),
      category: .core, defaultEnabled: true
    ),
    // MARK: Optional (off by default)
    FilterSource(
      id: "fanboy-mobile",
      name: "Mobile App Promo Blocker",
      url: URL(string: "https://secure.fanboy.co.nz/fanboy-mobile-notifications.txt")!,
      cacheFilename: "fanboy-mobile.txt",
      homepage: URL(string: "https://www.fanboy.co.nz/"),
      category: .optional, defaultEnabled: false
    ),
    FilterSource(
      id: "fanboy-annoyances",
      name: "Fanboy's Annoyances",
      url: URL(string: "https://secure.fanboy.co.nz/fanboy-annoyance.txt")!,
      cacheFilename: "fanboy-annoyances.txt",
      homepage: URL(string: "https://www.fanboy.co.nz/"),
      category: .optional, defaultEnabled: false
    ),
    FilterSource(
      id: "urlhaus-malware",
      name: "URLhaus Malware",
      url: URL(
        string:
          "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-agh-online.txt"
      )!,
      cacheFilename: "urlhaus-malware.txt",
      homepage: URL(string: "https://urlhaus.abuse.ch/"),
      category: .optional, defaultEnabled: false
    ),
    FilterSource(
      id: "adguard-japanese",
      name: "Japanese (AdGuard)",
      url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/7.txt")!,
      // Renamed from `adguard-japanese.txt` when the URL moved from the
      // safari/ to the ublock/ variant — keeping the filename invalidates
      // any pre-existing on-disk cache so the next launch fetches the
      // fresh ublock variant rather than re-using stale text.
      cacheFilename: "adguard-japanese-ubo.txt",
      homepage: URL(string: "https://adguard.com/kb/general/ad-filtering/adguard-filters/"),
      category: .optional, defaultEnabled: false
    ),
    FilterSource(
      id: "adguard-german",
      name: "German (AdGuard)",
      url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/6.txt")!,
      cacheFilename: "adguard-german.txt",
      homepage: URL(string: "https://adguard.com/kb/general/ad-filtering/adguard-filters/"),
      category: .optional, defaultEnabled: false
    ),
    FilterSource(
      id: "adguard-russian",
      name: "Russian (AdGuard)",
      url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/1.txt")!,
      cacheFilename: "adguard-russian.txt",
      homepage: URL(string: "https://adguard.com/kb/general/ad-filtering/adguard-filters/"),
      category: .optional, defaultEnabled: false
    ),
    FilterSource(
      id: "adguard-chinese",
      name: "Chinese (AdGuard)",
      url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/224.txt")!,
      cacheFilename: "adguard-chinese.txt",
      homepage: URL(string: "https://adguard.com/kb/general/ad-filtering/adguard-filters/"),
      category: .optional, defaultEnabled: false
    ),
    FilterSource(
      id: "adguard-spanish",
      name: "Spanish/Portuguese (AdGuard)",
      url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/9.txt")!,
      cacheFilename: "adguard-spanish.txt",
      homepage: URL(string: "https://adguard.com/kb/general/ad-filtering/adguard-filters/"),
      category: .optional, defaultEnabled: false
    ),
  ]

  /// Prefix applied to the `id` and `cacheFilename` of every
  /// user-defined source so the namespace stays disjoint from the
  /// shipped catalog. Stripping the prefix recovers the underlying
  /// ``AdblockerCustomSource.id``.
  public static let customSourceIdPrefix = "custom-"

  /// Sources visible to the rest of the app: shipped catalog first,
  /// then user-defined custom URLs in addition order. Order matters
  /// because rule lists are attached to ``WKWebView`` in this order
  /// and a `@@`-exception in an earlier list cannot cancel a block in
  /// a later one (and vice versa).
  public static var allSources: [FilterSource] {
    builtInSources + customSources()
  }

  /// Adapter from the preferences-side ``AdblockerCustomSource`` shape
  /// to runtime ``FilterSource`` entries. Entries with an invalid URL
  /// (unparseable or non-http(s) scheme) are silently dropped so a
  /// hand-edited preferences file does not quarantine.
  ///
  /// The `raw` parameter is a test seam: production callers pass
  /// `nil` and the adapter reads the live ``PreferencesStore``. Tests
  /// pass an explicit array to exercise the mapping without touching
  /// the shared store.
  static func customSources(
    _ raw: [AdblockerCustomSource]? = nil
  ) -> [FilterSource] {
    let entries =
      raw
      ?? PreferencesStore.shared.preferences.adblockerCustomSources
      ?? []
    return entries.compactMap { custom -> FilterSource? in
      guard let url = URL(string: custom.url),
        let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https"
      else { return nil }
      let homepage = custom.homepage.flatMap(URL.init(string:))
      return FilterSource(
        id: "\(customSourceIdPrefix)\(custom.id)",
        name: custom.name,
        url: url,
        cacheFilename: "\(customSourceIdPrefix)\(custom.id).txt",
        homepage: homepage,
        // Treat customs as `.optional` so the Settings UI groups them
        // alongside other opt-in sources; the per-source toggle still
        // honours `defaultEnabled` for the implicit-nil branch.
        category: .optional,
        defaultEnabled: true
      )
    }
  }

  /// Set of source ids enabled when the user has not made a per-source
  /// choice yet (i.e. ``E05Preferences/adblockerEnabledSources`` is
  /// `nil`). Used both at compile time and as the collapse target for
  /// the Settings toggle so a user who lands on the default set ends
  /// up with `nil` persisted (a smaller preferences.json). Includes
  /// custom sources because customs default-enable when added.
  public static var defaultEnabledSourceIds: Set<String> {
    Set(allSources.filter(\.defaultEnabled).map(\.id))
  }

  /// Whether the given source should be loaded at compile time given
  /// the current preferences snapshot. Centralises the
  /// nil-enabled-set fallback so `AdBlocker.start()` and
  /// `CosmeticFilterEngine.start()` stay in lock-step.
  public static func isSourceEnabled(_ source: FilterSource) -> Bool {
    isSourceEnabled(
      source,
      enabledIds: PreferencesStore.shared.preferences.adblockerEnabledSources
    )
  }

  /// Pure overload that takes the enabled set explicitly. Lets tests
  /// exercise the fallback / explicit-list branches without racing on
  /// the shared `PreferencesStore`.
  static func isSourceEnabled(
    _ source: FilterSource, enabledIds: [String]?
  ) -> Bool {
    if let enabledIds {
      return enabledIds.contains(source.id)
    }
    return source.defaultEnabled
  }

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
    for source in Self.allSources {
      if !Self.isSourceEnabled(source) {
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
      """
      Installed \(self.ruleLists.count) rule lists \
      (\(compiledIdentifiers.count) enabled / \
      \(Self.allSources.count) catalog)
      """
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
