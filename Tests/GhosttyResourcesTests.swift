import Foundation
import Testing

/// Guards the vendored ghostty runtime resources under `Resources/`.
/// These (terminfo / themes / shell-integration) are committed (the
/// xcframework is not) and copied into the app bundle by
/// `scripts/build_app.sh`. If they go missing, a release launched
/// without an inherited `GHOSTTY_RESOURCES_DIR` can't resolve the
/// `xterm-ghostty` terminfo or the built-in themes — so this suite
/// fails loudly rather than letting a broken bundle ship.
@Suite("Ghostty bundled resources")
struct GhosttyResourcesTests {
  /// Repo root resolved from this file: `Tests/GhosttyResourcesTests.swift`
  /// → two levels up to the repo root, then `Resources/`.
  static let resourcesDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")

  @Test("vendored xterm-ghostty terminfo is present")
  func terminfoPresent() {
    let entry = Self.resourcesDir.appendingPathComponent("terminfo/78/xterm-ghostty")
    #expect(FileManager.default.fileExists(atPath: entry.path))
  }

  @Test("vendored themes directory is present and non-empty")
  func themesPresent() throws {
    let themes = Self.resourcesDir.appendingPathComponent("ghostty/themes")
    let contents = try FileManager.default.contentsOfDirectory(atPath: themes.path)
    #expect(!contents.isEmpty)
  }

  @Test("vendored shell-integration is present")
  func shellIntegrationPresent() {
    let dir = Self.resourcesDir.appendingPathComponent("ghostty/shell-integration")
    #expect(FileManager.default.fileExists(atPath: dir.path))
  }
}
