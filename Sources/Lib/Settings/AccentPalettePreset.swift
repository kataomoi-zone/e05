import AppKit

/// Workspace accent palette preset. Each case maps to a four-colour
/// array used by ``PaneContainerViewController/accentColor(forWorkspaceAt:)``.
/// The default preset preserves the original hard-coded palette so an
/// install that has never touched ``E05Preferences/accentPalette``
/// renders the same workspace stripes as before.
///
/// Unknown identifiers resolve to ``subway`` so a hand-edited
/// `preferences.json` carrying a stale preset name doesn't strand any
/// workspace at a missing color.
public enum AccentPalettePreset: String, CaseIterable, Identifiable, Sendable {
  case subway
  case metro
  case unicorn

  public var id: String { rawValue }

  /// Human-readable name shown in the Settings picker.
  public var displayName: String {
    switch self {
    case .subway: "Subway"
    case .metro: "Metro"
    case .unicorn: "Unicorn"
    }
  }

  /// Four colors mapped positionally to workspace index. The view
  /// modulos the workspace position by the palette length so any
  /// preset of any length keeps rendering — four colors is the
  /// established floor matching the workspace cap.
  public var colors: [NSColor] {
    switch self {
    case .subway:
      [
        NSColor(srgbRed: 0xce / 255, green: 0x05 / 255, blue: 0x5b / 255, alpha: 1),
        NSColor(srgbRed: 0xb0 / 255, green: 0xbf / 255, blue: 0x1f / 255, alpha: 1),
        NSColor(srgbRed: 0xec / 255, green: 0x6e / 255, blue: 0x65 / 255, alpha: 1),
        NSColor(srgbRed: 0x02 / 255, green: 0x79 / 255, blue: 0xc2 / 255, alpha: 1),
      ]
    case .metro:
      [
        NSColor(srgbRed: 0xf6 / 255, green: 0x2e / 255, blue: 0x37 / 255, alpha: 1),
        NSColor(srgbRed: 0x00 / 255, green: 0x9b / 255, blue: 0xbf / 255, alpha: 1),
        NSColor(srgbRed: 0x03 / 255, green: 0xbb / 255, blue: 0x85 / 255, alpha: 1),
        NSColor(srgbRed: 0x8f / 255, green: 0x77 / 255, blue: 0xd7 / 255, alpha: 1),
      ]
    case .unicorn:
      [
        NSColor(srgbRed: 0x6d / 255, green: 0xc5 / 255, blue: 0xfb / 255, alpha: 1),
        NSColor(srgbRed: 0xf6 / 255, green: 0xf6 / 255, blue: 0x8c / 255, alpha: 1),
        NSColor(srgbRed: 0x8a / 255, green: 0xff / 255, blue: 0xa4 / 255, alpha: 1),
        NSColor(srgbRed: 0xf2 / 255, green: 0x83 / 255, blue: 0xd1 / 255, alpha: 1),
      ]
    }
  }

  /// Resolve a stored identifier to its preset. `nil` and any value
  /// that no longer matches a case both fall back to ``subway`` so
  /// the call site never has to handle an "unknown preset" error.
  public static func resolve(_ identifier: String?) -> AccentPalettePreset {
    guard let identifier else { return .subway }
    return AccentPalettePreset(rawValue: identifier) ?? .subway
  }
}
