/// Canonical filenames for every store that lives inside `E05Paths.default.dataDir`.
/// Centralising the literals here keeps `MutedSitesStore` / `PermissionsStore` /
/// `Bookmarks` / etc. from carrying their own string and lets future tooling
/// (e.g. a "data dir listing" or migration helper) enumerate every well-known
/// file without grepping.
public enum E05Filenames {
  public static let bookmarks = "bookmarks.db"
  public static let downloads = "downloads.db"
  public static let history = "history.db"
  public static let inputHistory = "input-history.db"
  public static let mutedSites = "muted-sites.json"
  public static let permissions = "permissions.json"
  public static let suspendExempt = "suspend-exempt.json"
  public static let finderModes = "finder-modes.json"
  public static let session = "session.json"
  public static let preferences = "preferences.json"
  public static let adblockerWhitelist = "adblocker-whitelist.json"
  /// Unix-domain control socket the `e05` CLI connects to. The CLI
  /// target does not depend on `E05Lib`, so `Sources/CLI/main.swift`
  /// hardcodes this same literal — keep the two in sync.
  public static let controlSocket = "control.sock"
  /// User-editable ghostty config inside `configDir` (XDG). Used by
  /// the Terminal settings tab and the libghostty runtime at launch.
  public static let terminalConfig = "config.ghostty"
}
