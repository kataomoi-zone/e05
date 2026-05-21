import Foundation
import Testing

@testable import E05Lib

@Suite("GhosttyConfigFileStore")
@MainActor
struct GhosttyConfigFileStoreTests {
  private func temporaryURL() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("e05-test-config-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("config.ghostty")
  }

  @Test("read returns empty when file is missing")
  func readMissingReturnsEmpty() {
    let url = temporaryURL()
    let store = GhosttyConfigFileStore(testURL: url)
    #expect(store.read() == "")
  }

  @Test("write then read round-trips utf8 content")
  func writeReadRoundTrip() throws {
    let url = temporaryURL()
    let store = GhosttyConfigFileStore(testURL: url)
    let payload = "font-family = Menlo\ncopy-on-select = clipboard\n# 日本語コメント OK\n"
    try store.write(payload)
    #expect(store.read() == payload)
  }

  @Test("write creates parent directory lazily")
  func writeCreatesParentDir() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("e05-test-nested-\(UUID().uuidString)")
      .appendingPathComponent("inner")
      .appendingPathComponent("config.ghostty")
    let store = GhosttyConfigFileStore(testURL: url)
    try store.write("font-size = 14\n")
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test("write posts didChangeNotification on success")
  func writeFiresNotification() throws {
    let url = temporaryURL()
    let store = GhosttyConfigFileStore(testURL: url)
    // The observer is registered with `queue: nil` so it fires
    // synchronously on the posting thread, which is also this test
    // method's thread (both are MainActor). That lets a plain
    // captured boolean serve the assertion without an NSLock.
    var fired = false
    let token = NotificationCenter.default.addObserver(
      forName: GhosttyConfigFileStore.didChangeNotification,
      object: store,
      queue: nil
    ) { _ in fired = true }
    defer { NotificationCenter.default.removeObserver(token) }
    try store.write("font-size = 12\n")
    #expect(fired == true)
  }
}

// GhosttyConfigValidator is intentionally not covered by unit tests.
// The validator calls into libghostty's C API (`ghostty_config_new`
// etc.), which depends on global state set up by `ghostty_init`. The
// swift-testing harness runs outside a `.app` bundle and never calls
// `ghostty_init`, so the first config allocation crashes the test
// process with SIGSEGV. Exercising the validator at runtime — through
// the Terminal settings tab — is the supported path; unit-level
// fixtures that mutate process-wide ghostty state would leak across
// every other suite in the package.

@Suite("GhosttyIncompatibleKeys")
@MainActor
struct GhosttyIncompatibleKeysTests {
  @Test("catalog hits a known ineffective key with line number")
  func catalogHitWithLineNumber() {
    let text = """
      font-family = Menlo
      window-decoration = none
      font-size = 14
      """
    let hits = GhosttyIncompatibleKeys.scan(text)
    #expect(hits.count == 1)
    #expect(hits.first?.key == "window-decoration")
    #expect(hits.first?.lineNumber == 2)
  }

  @Test("comments are skipped")
  func commentsSkipped() {
    let text = """
      # window-decoration = none
      #quick-terminal-position = top
      font-size = 14
      """
    let hits = GhosttyIncompatibleKeys.scan(text)
    #expect(hits.isEmpty)
  }

  @Test("leading whitespace on a hit is tolerated")
  func leadingWhitespace() {
    let text = "  window-decoration = none\n"
    let hits = GhosttyIncompatibleKeys.scan(text)
    #expect(hits.count == 1)
    #expect(hits.first?.key == "window-decoration")
  }

  @Test("known good keys do not produce hits")
  func recognisedKeysSilent() {
    let text = "font-family = Menlo\nbackground = #1e1e1e\ncursor-style = block\n"
    let hits = GhosttyIncompatibleKeys.scan(text)
    #expect(hits.isEmpty)
  }

  @Test("multiple hits preserve their line numbers")
  func multipleHits() {
    let text = """
      window-decoration = none
      font-family = Menlo
      quick-terminal-position = top
      auto-update-channel = stable
      """
    let hits = GhosttyIncompatibleKeys.scan(text)
    #expect(hits.count == 3)
    #expect(hits.map(\.lineNumber) == [1, 3, 4])
  }
}
