import Foundation

/// App-wide user preferences. Persisted as JSON in
/// `<dataDir>/preferences.json` through ``PreferencesStore``. New
/// fields must land here as `Optional` so the synthesised Codable
/// decoder keeps loading older on-disk files after a schema bump —
/// non-Optional fields with default values appear to be tolerant
/// but `JSONDecoder` does not consult init defaults for missing
/// keys, so an older snapshot would quarantine on first read.
public struct E05Preferences: Codable, Equatable, Sendable {
  /// Home URL for newly-created browser panes. `nil` keeps the
  /// historical `about:blank` behaviour so a fresh install or a
  /// user who has never touched the setting sees no surprise
  /// network traffic on the first pane.
  public var homeURL: String?

  /// URL template used when the URL bar input does not parse as a
  /// URL. `{query}` is substituted with the percent-encoded user
  /// input. The default points at DuckDuckGo because that is what
  /// the hard-coded path used before the setting existed.
  public var searchTemplate: String

  /// When true (default), every download routes through
  /// `NSSavePanel`. When false, downloads land directly in
  /// ``defaultDownloadDir`` (or `~/Downloads` when that is `nil`)
  /// using the same `<name> (N).<ext>` dedup as the panel-less
  /// fallback already does.
  public var alwaysPromptDownload: Bool

  /// Default download directory used when ``alwaysPromptDownload``
  /// is false. `nil` falls back to `~/Downloads` so a user who
  /// flips the prompt off without picking a dir still gets a
  /// sensible default.
  public var defaultDownloadDir: String?

  /// Minutes a browser pane can sit idle before the automatic
  /// suspend sweep reclaims its `WKWebView`. `nil` keeps the
  /// historical 60-minute default. Non-positive values (`0` and
  /// any negative ints a hand-edited file might leave behind)
  /// disable the idle sweep entirely — memory-pressure-driven
  /// suspends still run because those come from the OS, not the
  /// per-tick idle gate.
  public var suspendIdleMinutes: Int?

  /// Identifier of the workspace accent palette preset. `nil` keeps
  /// the historical four-colour default (pink / yellow-green /
  /// coral / blue). Unknown or hand-edited values resolve back to
  /// the default at the call site so a typo in `preferences.json`
  /// doesn't quarantine the file.
  public var accentPalette: String?

  /// Identifier of the surface corner-radius preset. `nil` keeps
  /// the historical 12pt default. Same unknown-value tolerance as
  /// ``accentPalette``.
  public var surfaceCornerRadius: String?

  /// Identifier of the pane border width preset. `nil` keeps the
  /// historical 2pt focused-pane border. Same unknown-value
  /// tolerance as ``accentPalette``.
  public var paneBorderWidth: String?

  public init(
    homeURL: String? = nil,
    searchTemplate: String = "https://duckduckgo.com/?q={query}",
    alwaysPromptDownload: Bool = true,
    defaultDownloadDir: String? = nil,
    suspendIdleMinutes: Int? = nil,
    accentPalette: String? = nil,
    surfaceCornerRadius: String? = nil,
    paneBorderWidth: String? = nil
  ) {
    self.homeURL = homeURL
    self.searchTemplate = searchTemplate
    self.alwaysPromptDownload = alwaysPromptDownload
    self.defaultDownloadDir = defaultDownloadDir
    self.suspendIdleMinutes = suspendIdleMinutes
    self.accentPalette = accentPalette
    self.surfaceCornerRadius = surfaceCornerRadius
    self.paneBorderWidth = paneBorderWidth
  }

  /// Factory used when the on-disk file is missing or quarantined.
  /// Keeping it a `static let` makes it cheap to reach from any
  /// caller that needs the baseline (tests, listener fan-out at
  /// first launch, etc.).
  public static let `default` = E05Preferences()
}
