import Foundation
import Testing

@testable import E05Lib

@Suite("E05Paths")
struct E05PathsTests {
  private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

  // MARK: - configDir precedence

  @Test("configDir falls back to ~/.config/e05 when no env vars are set")
  func configDirDefault() {
    let paths = E05Paths(env: [:], bundleIdentifier: "x", home: home)
    #expect(paths.configDir.path == "/Users/test/.config/e05")
  }

  @Test("configDir uses XDG_CONFIG_HOME with /e05 appended (XDG spec)")
  func configDirXDG() {
    let paths = E05Paths(
      env: ["XDG_CONFIG_HOME": "/Users/test/xdg"],
      bundleIdentifier: "x",
      home: home
    )
    #expect(paths.configDir.path == "/Users/test/xdg/e05")
  }

  @Test("configDir treats E05_CONFIG_DIR as the e05 dir directly, no append")
  func configDirE05Direct() {
    let paths = E05Paths(
      env: ["E05_CONFIG_DIR": "/tmp/e05-custom"],
      bundleIdentifier: "x",
      home: home
    )
    #expect(paths.configDir.path == "/tmp/e05-custom")
  }

  @Test("E05_CONFIG_DIR wins over XDG_CONFIG_HOME")
  func configDirE05BeatsXDG() {
    let paths = E05Paths(
      env: [
        "E05_CONFIG_DIR": "/tmp/e05-custom",
        "XDG_CONFIG_HOME": "/Users/test/xdg",
      ],
      bundleIdentifier: "x",
      home: home
    )
    #expect(paths.configDir.path == "/tmp/e05-custom")
  }

  @Test("configDir env values support ~ expansion against the seam-provided home")
  func configDirTildeExpansion() {
    let paths = E05Paths(
      env: ["E05_CONFIG_DIR": "~/custom"],
      bundleIdentifier: "x",
      home: home
    )
    #expect(paths.configDir.path == "/Users/test/custom")
  }

  @Test("empty env values are treated as unset and fall through")
  func configDirEmptyEnv() {
    let paths = E05Paths(
      env: ["E05_CONFIG_DIR": "", "XDG_CONFIG_HOME": ""],
      bundleIdentifier: "x",
      home: home
    )
    #expect(paths.configDir.path == "/Users/test/.config/e05")
  }

  @Test("relative XDG_CONFIG_HOME falls through to default per XDG spec")
  func configDirRelativeXDG() {
    let paths = E05Paths(
      env: ["XDG_CONFIG_HOME": "relative/path"],
      bundleIdentifier: "x",
      home: home
    )
    #expect(paths.configDir.path == "/Users/test/.config/e05")
  }

  @Test("relative E05_CONFIG_DIR falls through to default")
  func configDirRelativeE05() {
    let paths = E05Paths(
      env: ["E05_CONFIG_DIR": "relative/path"],
      bundleIdentifier: "x",
      home: home
    )
    #expect(paths.configDir.path == "/Users/test/.config/e05")
  }

  @Test("relative E05_CONFIG_DIR falls through to XDG_CONFIG_HOME when present")
  func configDirRelativeE05WithXDG() {
    let paths = E05Paths(
      env: [
        "E05_CONFIG_DIR": "relative/path",
        "XDG_CONFIG_HOME": "/Users/test/xdg",
      ],
      bundleIdentifier: "x",
      home: home
    )
    #expect(paths.configDir.path == "/Users/test/xdg/e05")
  }

  @Test("other-user tilde (~bob/...) falls through, not silently expanded")
  func configDirOtherUserTildeRejected() {
    let paths = E05Paths(
      env: ["E05_CONFIG_DIR": "~bob/conf"],
      bundleIdentifier: "x",
      home: home
    )
    #expect(paths.configDir.path == "/Users/test/.config/e05")
  }

  // MARK: - dataDir / cacheDir bundle id behaviour

  @Test("dataDir is keyed on the bundle identifier under Application Support")
  func dataDirRelease() {
    let paths = E05Paths(env: [:], bundleIdentifier: "org.kawarimidoll.e05", home: home)
    #expect(paths.dataDir.path == "/Users/test/Library/Application Support/org.kawarimidoll.e05")
  }

  @Test("cacheDir is keyed on the bundle identifier under Caches")
  func cacheDirRelease() {
    let paths = E05Paths(env: [:], bundleIdentifier: "org.kawarimidoll.e05", home: home)
    #expect(paths.cacheDir.path == "/Users/test/Library/Caches/org.kawarimidoll.e05")
  }

  @Test("dev and release bundle ids resolve to disjoint directories")
  func dataDirDevReleaseSplit() {
    let release = E05Paths(env: [:], bundleIdentifier: "org.kawarimidoll.e05", home: home)
    let dev = E05Paths(env: [:], bundleIdentifier: "org.kawarimidoll.e05.debug", home: home)
    #expect(release.dataDir != dev.dataDir)
    #expect(release.cacheDir != dev.cacheDir)
  }

  @Test("nil bundle id falls back to ~/.config/e05 for data and ~/.cache/e05 for cache")
  func nilBundleIdFallback() {
    let paths = E05Paths(env: [:], bundleIdentifier: nil, home: home)
    #expect(paths.dataDir.path == "/Users/test/.config/e05")
    #expect(paths.cacheDir.path == "/Users/test/.cache/e05")
  }

  @Test("empty bundle id is treated as unset and falls back like nil")
  func emptyBundleIdFallback() {
    let paths = E05Paths(env: [:], bundleIdentifier: "", home: home)
    #expect(paths.dataDir.path == "/Users/test/.config/e05")
    #expect(paths.cacheDir.path == "/Users/test/.cache/e05")
  }
}
