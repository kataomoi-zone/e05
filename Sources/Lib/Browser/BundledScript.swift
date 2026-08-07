import Foundation

/// Locates a JavaScript runtime shipped with E05Lib.
///
/// `Bundle.module` cannot be the only answer inside a packaged app.
/// SwiftPM's generated accessor resolves the resource bundle against
/// `Bundle.main.bundleURL`, which for an `.app` is the bundle root — and
/// codesign rejects anything placed there outright ("unsealed contents
/// present in the bundle root"), so the resource bundle has nowhere to
/// sit that both the accessor and the signature accept. The accessor's
/// other candidate is an absolute `.build` path baked in at compile
/// time, which exists only on the machine that built the binary; that is
/// why a locally-built `.app` runs while a distributed one traps the
/// moment either engine is first touched.
///
/// So `build_app.sh` copies the scripts into `Contents/Resources` like
/// every other bundled resource, and this checks there first.
/// `Bundle.module` remains the answer for tests and any non-bundled run,
/// where `Bundle.main` is the test runner rather than e05.
enum BundledScript {
  static func url(named name: String) -> URL? {
    Bundle.main.url(forResource: name, withExtension: "js")
      ?? Bundle.module.url(forResource: name, withExtension: "js")
  }
}
