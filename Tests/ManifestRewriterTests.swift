import Foundation
import Testing

@testable import E05Lib

@Suite("ManifestRewriter.chromeExtensionID")
struct ChromeExtensionIDTests {
  @Test("matches Chromium GenerateId for a known vector")
  func matchesChromiumVector() {
    // Chromium's crx_file id_util_unittest pins
    // GenerateId("test") == "jpignaibiiemhngfjkcpokkamffknabf".
    // Our function base64-decodes first, so feed base64("test").
    #expect(
      ManifestRewriter.chromeExtensionID(fromBase64DERKey: "dGVzdA==")
        == "jpignaibiiemhngfjkcpokkamffknabf")
  }

  @Test("returns a 32-char id in the a-p alphabet")
  func idShapeIsValid() {
    let id = ManifestRewriter.chromeExtensionID(fromBase64DERKey: "dGVzdA==")
    #expect(id?.count == 32)
    #expect(id?.allSatisfy { ("a"..."p").contains($0) } == true)
  }

  @Test("is deterministic for the same key")
  func deterministic() {
    let a = ManifestRewriter.chromeExtensionID(fromBase64DERKey: "aGVsbG8gd29ybGQ=")
    let b = ManifestRewriter.chromeExtensionID(fromBase64DERKey: "aGVsbG8gd29ybGQ=")
    #expect(a != nil)
    #expect(a == b)
  }

  @Test("returns nil for input that isn't base64")
  func rejectsNonBase64() {
    #expect(ManifestRewriter.chromeExtensionID(fromBase64DERKey: "not base64!!!") == nil)
  }
}

@Suite("ManifestRewriter.mv3ToMV2")
struct ManifestRewriterMV2Tests {
  private func withTempDir(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("manifest-rewriter-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
  }

  private func writeManifest(_ obj: [String: Any], to dir: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: obj)
    try data.write(to: dir.appendingPathComponent("manifest.json"))
  }

  private func readManifest(_ dir: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
  }

  @Test("converts an MV3 manifest to MV2 in place and backs up the original")
  func convertsMV3() throws {
    try withTempDir { dir in
      try writeManifest(
        [
          "manifest_version": 3,
          "name": "Test",
          "version": "1.0",
          "action": ["default_popup": "popup.html"],
          "background": ["service_worker": "bg.js"],
          "host_permissions": ["https://example.com/*"],
          "permissions": ["storage"],
        ], to: dir)

      let changed = try ManifestRewriter.mv3ToMV2(at: dir)
      #expect(changed)

      let m = try readManifest(dir)
      #expect(m["manifest_version"] as? Int == 2)
      // action → browser_action (rename)
      #expect(m["action"] == nil)
      #expect(m["browser_action"] != nil)
      // service_worker → page/persistent
      let bg = m["background"] as? [String: Any]
      #expect(bg?["service_worker"] == nil)
      #expect(bg?["page"] as? String == "_e05_bg.html")
      #expect(bg?["persistent"] as? Bool == false)
      // host_permissions merged into permissions
      #expect(m["host_permissions"] == nil)
      let perms = m["permissions"] as? [String] ?? []
      #expect(perms.contains("storage"))
      #expect(perms.contains("https://example.com/*"))

      // The original MV3 manifest is preserved next to it, and the
      // synthesized background page + shim are written.
      let fm = FileManager.default
      #expect(fm.fileExists(atPath: dir.appendingPathComponent("manifest.json.e05-original").path))
      #expect(fm.fileExists(atPath: dir.appendingPathComponent("_e05_bg.html").path))
      #expect(fm.fileExists(atPath: dir.appendingPathComponent("_e05_bg_shim.js").path))
    }
  }

  @Test("leaves an MV2 manifest untouched")
  func skipsMV2() throws {
    try withTempDir { dir in
      try writeManifest(
        ["manifest_version": 2, "name": "Test", "version": "1.0"], to: dir)
      #expect(try ManifestRewriter.mv3ToMV2(at: dir) == false)
      #expect(try readManifest(dir)["manifest_version"] as? Int == 2)
    }
  }

  @Test("honors the .e05-skip-rewrite marker")
  func honorsSkipMarker() throws {
    try withTempDir { dir in
      try writeManifest(["manifest_version": 3, "name": "T", "version": "1"], to: dir)
      try Data().write(to: dir.appendingPathComponent(".e05-skip-rewrite"))
      #expect(try ManifestRewriter.mv3ToMV2(at: dir) == false)
      // Untouched: still MV3.
      #expect(try readManifest(dir)["manifest_version"] as? Int == 3)
    }
  }

  @Test("throws when manifest.json is missing")
  func throwsOnMissing() throws {
    try withTempDir { dir in
      #expect(throws: ManifestRewriter.RewriteError.self) {
        try ManifestRewriter.mv3ToMV2(at: dir)
      }
    }
  }

  @Test("throws when manifest.json isn't valid JSON")
  func throwsOnInvalidJSON() throws {
    try withTempDir { dir in
      try Data("{ not json".utf8).write(to: dir.appendingPathComponent("manifest.json"))
      #expect(throws: ManifestRewriter.RewriteError.self) {
        try ManifestRewriter.mv3ToMV2(at: dir)
      }
    }
  }
}
