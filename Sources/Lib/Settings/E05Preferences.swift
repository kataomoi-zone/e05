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

  /// Identifier of the pane gap preset. `nil` keeps the historical
  /// 6pt resize-handle thickness and matching workspace outer margin.
  /// Same unknown-value tolerance as ``accentPalette``.
  public var paneGap: String?

  /// Identifier of the app-wide theme preset (System / Light /
  /// Dark). `nil` defers to the macOS Appearance preference. Same
  /// unknown-value tolerance as ``accentPalette``.
  public var theme: String?

  /// User-defined overrides for ``Action`` key chords, keyed by the
  /// action's stable `id`. `nil` (or an absent key) keeps the static
  /// default baked into the registry; a present ``ShortcutBinding``
  /// with `keyEquivalent: nil` is the explicit "unbound" form.
  /// Unknown ids (e.g. an action removed in a later release) sit
  /// dormant until the entry is rewritten or the file is reset.
  public var keyboardShortcuts: [String: ShortcutBinding]?

  /// Identifiers of the ``AdBlocker/FilterSource`` entries the user
  /// wants active. `nil` enables the catalog's default-enabled subset
  /// (i.e. every `.core` source); an explicit list opts in only to the
  /// named ids and ignores `defaultEnabled` entirely. Unknown ids are
  /// dropped at apply time so a removed source does not quarantine the
  /// preferences file.
  public var adblockerEnabledSources: [String]?

  /// Interval, in hours, between automatic filterlist refreshes.
  /// `nil` keeps the historical weekly default; `0` disables the
  /// automatic refresh entirely (the user can still run a manual
  /// refresh from the Settings tab); positive values run on that
  /// cadence. Sane upper bound is enforced at the input site.
  public var adblockerAutoUpdateIntervalHours: Int?

  /// Wall-clock timestamp of the most recent successful filterlist
  /// refresh. `nil` indicates "never refreshed yet" and triggers the
  /// auto-update scheduler on the next launch. Updated by
  /// ``AdBlocker.refreshFilterlists()`` and surfaced in the Settings
  /// tab as a "Last updated" label.
  public var adblockerLastRefreshedAt: Date?

  /// User-defined filterlist URLs concatenated onto the shipped
  /// catalog at runtime. Entries whose `url` does not parse to a
  /// `http`/`https` URL are silently dropped by the adapter so a
  /// hand-edited preferences file with a typo does not quarantine.
  public var adblockerCustomSources: [AdblockerCustomSource]?

  /// Ordered list the Cycle Width action steps through. `nil` keeps
  /// the built-in default (`PaneContainerViewController
  /// .defaultWidthCycle`); an empty list also falls back to the
  /// default with a warning so a hand-edited preferences file does
  /// not permanently disable the action. Entries below the 450pt
  /// floor are still kept in cycle order — Auto Layout clamps them
  /// silently via the column's minimum-width constraint.
  public var widthCyclePresets: [PaneWidthPreset]?

  /// Identifier of the pane kind seeded into a freshly created
  /// workspace (see ``InitialPaneKindPreset``). `nil` defaults to the
  /// start page. Unknown values resolve back to start at the call site
  /// so a typo doesn't quarantine the file. Link-opened workspaces
  /// ("Open in New Workspace") ignore this and seed the destination
  /// browser pane instead.
  public var initialPaneKind: String?

  /// Whether `Next Pane` / `Previous Pane` wrap from the last pane back
  /// to the first (and vice versa). `nil` keeps the historical wrapping
  /// behaviour; `false` stops focus at the first / last pane instead.
  public var wrapPaneFocus: Bool?

  /// Whether `Next Workspace` / `Previous Workspace` wrap from the last
  /// workspace back to the first (and vice versa). `nil` keeps the
  /// historical wrapping behaviour; `false` stops at the first / last
  /// workspace instead.
  public var wrapWorkspaceSwitch: Bool?

  /// Whether the command palette's dynamic "Focus: <pane>" entries are
  /// limited to the focused workspace. `nil`/`false` keeps the
  /// historical behaviour of listing panes across every workspace;
  /// `true` restricts the list to the current workspace.
  public var paletteFocusCurrentWorkspaceOnly: Bool?

  /// Pane kind opened by `Split Vertical`. Resolved through
  /// ``SplitPaneKindPreset`` (default ``SplitPaneKindPreset/duplicate``).
  /// `nil` / an unknown name resolves to a duplicate of the focused pane.
  public var splitPaneKind: String?

  /// Launch directory for a freshly opened terminal pane (one that
  /// does not restore a saved cwd). `nil` / empty leaves
  /// `working_directory` unset so libghostty inherits from the focused
  /// surface; a non-empty path (`~` expanded at use) becomes the cwd.
  public var newTerminalDirectory: String?

  /// Root directory for a freshly opened finder pane. `nil` / empty
  /// roots at the home directory (the historical default); a non-empty
  /// path (`~` expanded at use) roots there instead.
  public var newFinderDirectory: String?

  /// Whether a terminal pane's screen is written to disk at quit so the
  /// next launch can replay it. `nil` means on, the behaviour that
  /// shipped before the setting existed. Off is worth having because a
  /// capture is the pane's screen verbatim: whatever was displayed —
  /// an echoed token, the output of `env` — is in the file.
  ///
  /// Read through ``restoresTerminalScrollback`` rather than directly:
  /// the default lives there, in one place, where a test can reach it.
  public var restoreTerminalScrollback: Bool?

  /// ``restoreTerminalScrollback`` with its default applied.
  public var restoresTerminalScrollback: Bool { restoreTerminalScrollback ?? true }

  public init(
    homeURL: String? = nil,
    searchTemplate: String = "https://duckduckgo.com/?q={query}",
    alwaysPromptDownload: Bool = true,
    defaultDownloadDir: String? = nil,
    suspendIdleMinutes: Int? = nil,
    accentPalette: String? = nil,
    surfaceCornerRadius: String? = nil,
    paneBorderWidth: String? = nil,
    paneGap: String? = nil,
    theme: String? = nil,
    keyboardShortcuts: [String: ShortcutBinding]? = nil,
    adblockerEnabledSources: [String]? = nil,
    adblockerAutoUpdateIntervalHours: Int? = nil,
    adblockerLastRefreshedAt: Date? = nil,
    adblockerCustomSources: [AdblockerCustomSource]? = nil,
    widthCyclePresets: [PaneWidthPreset]? = nil,
    initialPaneKind: String? = nil,
    wrapPaneFocus: Bool? = nil,
    wrapWorkspaceSwitch: Bool? = nil,
    paletteFocusCurrentWorkspaceOnly: Bool? = nil,
    splitPaneKind: String? = nil,
    newTerminalDirectory: String? = nil,
    newFinderDirectory: String? = nil,
    restoreTerminalScrollback: Bool? = nil
  ) {
    self.homeURL = homeURL
    self.searchTemplate = searchTemplate
    self.alwaysPromptDownload = alwaysPromptDownload
    self.defaultDownloadDir = defaultDownloadDir
    self.suspendIdleMinutes = suspendIdleMinutes
    self.accentPalette = accentPalette
    self.surfaceCornerRadius = surfaceCornerRadius
    self.paneBorderWidth = paneBorderWidth
    self.paneGap = paneGap
    self.theme = theme
    self.keyboardShortcuts = keyboardShortcuts
    self.adblockerEnabledSources = adblockerEnabledSources
    self.adblockerAutoUpdateIntervalHours = adblockerAutoUpdateIntervalHours
    self.adblockerLastRefreshedAt = adblockerLastRefreshedAt
    self.adblockerCustomSources = adblockerCustomSources
    self.widthCyclePresets = widthCyclePresets
    self.initialPaneKind = initialPaneKind
    self.wrapPaneFocus = wrapPaneFocus
    self.wrapWorkspaceSwitch = wrapWorkspaceSwitch
    self.paletteFocusCurrentWorkspaceOnly = paletteFocusCurrentWorkspaceOnly
    self.splitPaneKind = splitPaneKind
    self.newTerminalDirectory = newTerminalDirectory
    self.newFinderDirectory = newFinderDirectory
    self.restoreTerminalScrollback = restoreTerminalScrollback
  }

  /// Factory used when the on-disk file is missing or quarantined.
  /// Keeping it a `static let` makes it cheap to reach from any
  /// caller that needs the baseline (tests, listener fan-out at
  /// first launch, etc.).
  public static let `default` = E05Preferences()
}
