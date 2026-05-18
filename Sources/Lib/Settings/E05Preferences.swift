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

  public init(
    homeURL: String? = nil,
    searchTemplate: String = "https://duckduckgo.com/?q={query}",
    alwaysPromptDownload: Bool = true,
    defaultDownloadDir: String? = nil
  ) {
    self.homeURL = homeURL
    self.searchTemplate = searchTemplate
    self.alwaysPromptDownload = alwaysPromptDownload
    self.defaultDownloadDir = defaultDownloadDir
  }

  /// Factory used when the on-disk file is missing or quarantined.
  /// Keeping it a `static let` makes it cheap to reach from any
  /// caller that needs the baseline (tests, listener fan-out at
  /// first launch, etc.).
  public static let `default` = E05Preferences()
}
