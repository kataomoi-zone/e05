import AppKit

/// App-wide theme preset. Resolves through
/// ``E05Preferences/theme`` and applies to `NSApp.appearance`.
///
/// - ``system`` defers to the macOS Appearance preference (light /
///   dark / auto) by setting `NSApp.appearance = nil`.
/// - ``light`` and ``dark`` force the named appearance regardless of
///   the OS setting.
///
/// Unknown identifiers resolve to ``system`` so a hand-edited
/// `preferences.json` carrying a stale name follows the OS default.
public enum ThemePreset: String, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  /// SF Symbol shown next to the label in the picker.
  public var symbol: String {
    switch self {
    case .system: "circle.lefthalf.filled"
    case .light: "sun.max.fill"
    case .dark: "moon.fill"
    }
  }

  /// The `NSAppearance` to assign to `NSApp.appearance`. `nil`
  /// means "inherit from the OS Appearance preference" — this is
  /// the explicit way to opt out of the app-level override.
  public var appearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }

  public static func resolve(_ identifier: String?) -> ThemePreset {
    guard let identifier else { return .system }
    return ThemePreset(rawValue: identifier) ?? .system
  }
}
