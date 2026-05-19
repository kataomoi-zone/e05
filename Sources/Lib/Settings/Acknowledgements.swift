import Foundation

/// One acknowledged open-source dependency. Bundled at compile time
/// — the list lives in this file (rather than a resource bundle) so
/// adding a credit is a one-line PR with no plist / Markdown
/// roundtrip and no Resources-copy step in `build_app.sh`.
public struct OSSCredit: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let license: String
  public let url: URL
  public let description: String

  public init(id: String, name: String, license: String, url: URL, description: String) {
    self.id = id
    self.name = name
    self.license = license
    self.url = url
    self.description = description
  }
}

/// Open-source projects whose binaries are bundled with e05. Apple
/// system frameworks (WebKit / AppKit / Foundation / etc.) follow
/// the App Store convention of not requiring per-app credit; the
/// internal adblocker engine, Netscape bookmarks parser, and other
/// in-tree code lives under e05's own LICENSE and is not listed
/// here either.
///
/// Concept-only references — Brave's adblock-rust (MPL-2.0),
/// uBlock Origin (GPL-3.0), AdGuard ExtendedCSS (GPL-3.0), zentty
/// (GPL-3.0) — informed the design but ship no code in e05 (GPL is
/// incompatible with e05's MIT license), so they do not belong in
/// the Acknowledgements list either.
public enum Acknowledgements {
  public static let all: [OSSCredit] = [
    OSSCredit(
      id: "ghostty",
      name: "Ghostty",
      license: "MIT License",
      url: URL(string: "https://github.com/ghostty-org/ghostty")!,
      description: "Terminal emulator embedded through libghostty (GhosttyKit.xcframework)."
    )
  ]
}
