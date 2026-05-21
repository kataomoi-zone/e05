import Foundation
import GhosttyKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "GhosttyConfigValidator")

/// Parser diagnostic raised by libghostty while loading a candidate
/// config. Wraps the C-level `ghostty_diagnostic_s.message` into a
/// Swift-native value so the Settings UI never sees ghostty's C
/// types directly.
public struct GhosttyConfigDiagnostic: Sendable, Equatable, Hashable {
  public let message: String

  public init(message: String) {
    self.message = message
  }
}

/// Validates candidate `config.ghostty` text through libghostty's
/// parser without disturbing the live runtime. The Terminal settings
/// tab calls this on every debounced edit and surfaces the result
/// next to the editor.
@MainActor
public enum GhosttyConfigValidator {
  /// Parse `text` as a ghostty config and return every diagnostic
  /// libghostty raised. An empty list means a clean parse. `nil`
  /// signals that validation could not be attempted — either
  /// libghostty refused to allocate a config handle, or the tempfile
  /// required to drive the parser could not be written. The
  /// distinction matters because the Settings UI must NOT render a
  /// "clean" verdict when no parse happened.
  public static func validate(_ text: String) -> [GhosttyConfigDiagnostic]? {
    guard let cfg = ghostty_config_new() else {
      logger.error("[ghostty/validate] ghostty_config_new failed")
      return nil
    }
    defer { ghostty_config_free(cfg) }

    // libghostty exposes `load_file` but no "load from a buffer"
    // entry point, so route through a tempfile to reuse the runtime
    // path that the live config takes at launch — same parser,
    // same diagnostic surface.
    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("e05-config-validate-\(UUID().uuidString).ghostty")
    do {
      try text.write(to: tempURL, atomically: true, encoding: .utf8)
    } catch {
      logger.error(
        "[ghostty/validate] tempfile write failed: \(error.localizedDescription, privacy: .public)"
      )
      return nil
    }
    defer { try? FileManager.default.removeItem(at: tempURL) }

    tempURL.path.withCString { ghostty_config_load_file(cfg, $0) }
    ghostty_config_finalize(cfg)

    let count = ghostty_config_diagnostics_count(cfg)
    var diagnostics: [GhosttyConfigDiagnostic] = []
    diagnostics.reserveCapacity(Int(count))
    for i in 0..<count {
      let raw = ghostty_config_get_diagnostic(cfg, i)
      guard let ptr = raw.message else { continue }
      let message = String(cString: ptr)
      diagnostics.append(GhosttyConfigDiagnostic(message: message))
    }
    return diagnostics
  }
}
