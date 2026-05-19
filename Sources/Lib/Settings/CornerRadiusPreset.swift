import CoreGraphics

/// Surface corner-radius preset. Resolves through
/// ``E05Preferences/surfaceCornerRadius`` to a concrete `CGFloat`
/// applied by every chrome surface that reads
/// ``AppMetrics/surfaceCornerRadius``. The default preset preserves
/// the original 12pt radius so an install that has never touched the
/// preference renders the same surfaces as before.
///
/// Unknown identifiers resolve to ``standard`` so a hand-edited
/// `preferences.json` carrying a stale preset name doesn't leave
/// surfaces with an undefined radius.
public enum CornerRadiusPreset: String, CaseIterable, Identifiable, Sendable {
  case sharp
  case rounded
  case standard
  case soft

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .sharp: "Sharp"
    case .rounded: "Rounded"
    case .standard: "Standard"
    case .soft: "Soft"
    }
  }

  /// Concrete radius in points applied by ``AppMetrics``.
  public var value: CGFloat {
    switch self {
    case .sharp: 0
    case .rounded: 6
    case .standard: 12
    case .soft: 18
    }
  }

  /// Resolve a stored identifier to its preset. `nil` and any value
  /// that no longer matches a case both fall back to ``standard``,
  /// matching the historical 12pt radius.
  public static func resolve(_ identifier: String?) -> CornerRadiusPreset {
    guard let identifier else { return .standard }
    return CornerRadiusPreset(rawValue: identifier) ?? .standard
  }
}
