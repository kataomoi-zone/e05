import Foundation
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "Session")

/// Serializable session layout state for save/restore.
public struct SessionState: Codable {
  public var workspaces: [WorkspaceState]
  public var focusedWorkspaceIndex: Int
  public var urlBarVisible: Bool
  /// Sidebar pin state. Persists the user's choice between
  /// hover-only (false, default) and pinned-open (true) across
  /// restarts. `.hoverPeek` is ephemeral — only explicit pinning
  /// survives a session round-trip.
  public var sidebarPinned: Bool = false

  public struct WorkspaceState: Codable {
    public var columns: [ColumnState]
    public var focusedColumnIndex: Int
    /// Horizontal scroll offset (in points) at the time of capture.
    public var scrollX: Double
  }

  public struct ColumnState: Codable {
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

  private static var sessionFilePath: URL {
    let configDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/e05")
    return configDir.appendingPathComponent("session.json")
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
