import Foundation

/// Resolves the on-disk locations e05 reads and writes. Callers that need
/// production paths read `E05Paths.default`; tests construct an instance
/// with explicit seams so they never touch the user's real `~/.config` or
/// `~/Library` while still exercising the lookup precedence.
///
/// The split between `configDir`, `dataDir`, and `cacheDir` mirrors the
/// macOS convention used by every other browser on the platform: config
/// is human-edited and lives under `~/.config` (XDG-overridable so the
/// ghostty-compatible `config` keeps a familiar home), data and cache are
/// machine-managed and live under `~/Library/...` keyed on the bundle
/// identifier so dev (`org.kawarimidoll.e05.debug`) and release
/// (`org.kawarimidoll.e05`) builds stay isolated without code branches.
public struct E05Paths: Sendable {
  /// Directory holding the ghostty-compatible flat-key `config` file and
  /// any future hand-edited preferences. Lookup order:
  /// `E05_CONFIG_DIR` (e05-specific, treated as the e05 dir itself) then
  /// `XDG_CONFIG_HOME/e05` (XDG spec — env var points at the parent dir
  /// containing per-app folders) then `~/.config/e05` as the fallback.
  public let configDir: URL

  /// Persistent data and accumulated state. `~/Library/Application Support/<bid>/`.
  /// Falls back to `~/.config/e05` when `Bundle.main.bundleIdentifier`
  /// is nil so test harnesses (XCTest, `swift test`) still resolve to a
  /// writable location during the gap between this utility landing and
  /// the per-store migration.
  public let dataDir: URL

  /// Regenerable caches (filter lists, favicons). `~/Library/Caches/<bid>/`,
  /// with the same nil-bundle-id fallback as `dataDir` (`~/.cache/e05`).
  public let cacheDir: URL

  /// Production resolver. Reads `ProcessInfo.processInfo.environment`,
  /// `Bundle.main.bundleIdentifier`, and `FileManager.default.homeDirectoryForCurrentUser`
  /// at first access; the resulting `E05Paths` is then cached for the
  /// process lifetime so subsequent reads stay cheap. The environment
  /// snapshot is taken once — `setenv` calls made later in the process
  /// are not observed; callers that need a fresh read must construct a
  /// new instance via `init(env:bundleIdentifier:home:)`.
  public static let `default` = E05Paths()

  /// Shorthand initialiser used by `default`. Production code should
  /// reach this via `E05Paths.default` rather than constructing extra
  /// instances; the public `init()` exists only so the seam-based init
  /// stays the single source of truth.
  public init() {
    self.init(
      env: ProcessInfo.processInfo.environment,
      bundleIdentifier: Bundle.main.bundleIdentifier,
      home: FileManager.default.homeDirectoryForCurrentUser
    )
  }

  /// Test seam. `env` and `bundleIdentifier` and `home` are all injected
  /// so unit tests can verify the precedence rules without mutating the
  /// real process environment or relying on a host with `XDG_CONFIG_HOME`
  /// happening to be set.
  public init(env: [String: String], bundleIdentifier: String?, home: URL) {
    self.configDir = Self.resolveConfigDir(env: env, home: home)
    if let bid = bundleIdentifier, !bid.isEmpty {
      self.dataDir = home.appendingPathComponent("Library/Application Support/\(bid)", isDirectory: true)
      self.cacheDir = home.appendingPathComponent("Library/Caches/\(bid)", isDirectory: true)
    } else {
      self.dataDir = home.appendingPathComponent(".config/e05", isDirectory: true)
      self.cacheDir = home.appendingPathComponent(".cache/e05", isDirectory: true)
    }
  }

  /// Returns the full filesystem path to a SQLite database file inside
  /// `dataDir`, creating the parent directory if it does not yet exist.
  /// `String` return type matches what SQLite open APIs want and lets
  /// the `:memory:` sentinel flow through callers that share a single
  /// internal initialiser.
  public func databasePath(_ filename: String) -> String {
    try? FileManager.default.createDirectory(
      at: dataDir, withIntermediateDirectories: true)
    return dataDir.appendingPathComponent(filename).path
  }

  /// Returns a `URL` for a Codable on-disk store inside `dataDir`. The
  /// parent directory is not created here — Codable store implementations
  /// handle that at first save so the inMemory variant stays a pure value
  /// type with no filesystem side effects.
  public func dataFile(_ filename: String) -> URL {
    dataDir.appendingPathComponent(filename)
  }

  /// Returns a `URL` for a user-editable file inside `configDir`. The
  /// parent directory is not created here; the writer creates it lazily
  /// so a read-only consumer (e.g. the libghostty bootstrap) leaves the
  /// XDG dir untouched when no edits have happened yet.
  public func configFile(_ filename: String) -> URL {
    configDir.appendingPathComponent(filename)
  }

  static func resolveConfigDir(env: [String: String], home: URL) -> URL {
    if let custom = env["E05_CONFIG_DIR"], Self.isAbsolute(custom) {
      return Self.expand(custom, home: home)
    }
    if let xdg = env["XDG_CONFIG_HOME"], Self.isAbsolute(xdg) {
      return Self.expand(xdg, home: home).appendingPathComponent("e05", isDirectory: true)
    }
    // XDG Base Directory Specification: "If $XDG_CONFIG_HOME is either
    // not set or empty, or set to a relative path, the default ...
    // should be used." `E05_CONFIG_DIR` follows the same rule so the
    // resolved path never depends on the working directory e05 was
    // launched from. `~user/...` (other-user tilde) is also rejected
    // because `expand` cannot honour it without consulting `getpwnam`.
    return home.appendingPathComponent(".config/e05", isDirectory: true)
  }

  /// Whether `path` denotes an absolute filesystem location after
  /// `~` expansion against the user's home. `URL(fileURLWithPath:)`
  /// itself silently rebases relative paths against CWD, so the check
  /// has to run on the raw env-var string before any URL coercion.
  private static func isAbsolute(_ path: String) -> Bool {
    path == "~" || path.hasPrefix("/") || path.hasPrefix("~/")
  }

  /// Resolves a path that may begin with `~` against the supplied home
  /// directory. Callers must guard with `isAbsolute` first; this helper
  /// trusts that the input is `/...`, `~`, or `~/...`.
  private static func expand(_ path: String, home: URL) -> URL {
    if path == "~" {
      return home
    }
    if path.hasPrefix("~/") {
      return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
    }
    return URL(fileURLWithPath: path, isDirectory: true)
  }
}
