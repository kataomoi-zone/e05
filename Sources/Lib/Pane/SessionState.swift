import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "Session")

/// Serializable session layout state for save/restore.
public struct SessionState: Codable {
  public var workspaces: [WorkspaceState]
  public var focusedWorkspaceIndex: Int
  /// Window-global URL bar visibility. The toggle action flips this
  /// for every pane in lockstep; `.peek` reveals driven by ⌘L on a
  /// single pane are ephemeral and never persisted.
  public var urlBarVisible: Bool = false
  /// Sidebar pin state. Persists the user's choice between
  /// hover-only (false, default) and pinned-open (true) across
  /// restarts. `.hoverPeek` is ephemeral — only explicit pinning
  /// survives a session round-trip.
  public var sidebarPinned: Bool = false
  /// ULID strings of the worklane items (workspaces and / or
  /// columns) the user had collapsed at save time. Stored as a flat
  /// list because ULID's random bits make workspace and column ids
  /// collision-free, so the in-memory set on the sidebar VC can be
  /// rehydrated with one filter pass at restore. `Optional` so the
  /// on-disk payload omits the key entirely when nothing is
  /// collapsed; the in-code reader treats nil and empty as identical.
  public var collapsedIds: [String]?

  public struct WorkspaceState: Codable {
    /// Workspace ULID at save time. `Optional` so a session.json
    /// written before id round-trip existed decodes cleanly — the
    /// restore path falls back to a fresh ULID, which one-time
    /// drops any persisted `collapsedIds` entries that referenced
    /// the missing workspace.
    public var id: String?
    public var columns: [ColumnState]
    public var focusedColumnIndex: Int
    /// Horizontal scroll offset (in points) at the time of capture.
    public var scrollX: Double
  }

  public struct ColumnState: Codable {
    /// Column ULID at save time. See `WorkspaceState.id` for the
    /// optionality rationale.
    public var id: String?
    public var panes: [PaneState]
    public var focusedPaneIndex: Int
    public var width: Double
    /// Height ratios relative to the first pane. Empty for single-pane columns.
    public var heightRatios: [Double]
  }

  public struct PaneState: Codable {
    public var address: String
    /// Browser page title captured at save time. Primes the sidebar
    /// worklane on restore so browser rows don't flash the hostname
    /// fallback before WKWebView's title KVO settles after page load.
    /// Omitted for terminal panes — ghostty resets titles on restart.
    public var title: String?
    /// Browser back history URLs (oldest first). Empty for non-browser panes.
    public var backHistory: [String]?
    /// Browser forward history URLs. Empty for non-browser panes.
    public var forwardHistory: [String]?
  }

  // MARK: - File Path

  /// Production path for the saved session, resolved through
  /// `E05Paths.default.dataDir` so dev (`org.kawarimidoll.e05.debug`)
  /// and release (`org.kawarimidoll.e05`) builds keep separate
  /// session files without code branches. `save()` creates the
  /// directory on demand — `Application Support/<bundle-id>/` is
  /// not guaranteed to exist on first launch.
  private static var sessionFilePath: URL {
    E05Paths.default.dataDir.appendingPathComponent("session.json")
  }

  // MARK: - Save

  public func save() {
    let path = Self.sessionFilePath
    let dir = path.deletingLastPathComponent()

    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      logger.error("Failed to create session directory: \(error.localizedDescription)")
      return
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(self)
    } catch {
      logger.error("Failed to encode session: \(error.localizedDescription)")
      return
    }

    do {
      try data.write(to: path, options: .atomic)
    } catch {
      logger.error("Failed to write session file: \(error.localizedDescription)")
    }
  }

  // MARK: - Load

  public static func load() -> SessionState? {
    let path = sessionFilePath
    guard let data = try? Data(contentsOf: path) else { return nil }
    return try? JSONDecoder().decode(SessionState.self, from: data)
  }

  // MARK: - Delete

  public static func delete() {
    try? FileManager.default.removeItem(at: sessionFilePath)
  }
}
