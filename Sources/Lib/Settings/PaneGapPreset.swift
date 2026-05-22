import CoreGraphics

/// Pane gap preset. Drives the resize-handle thickness between panes
/// and between columns, and the outer margin painted around the
/// column strip inside a workspace. The two values stay locked
/// together (`outerMargin == handleSize`) so the gap between panes
/// and the gap around them feel like a single rhythm.
///
/// Unknown identifiers resolve to ``standard``, which preserves the
/// historical 6pt gap the codebase shipped with.
public enum PaneGapPreset: String, CaseIterable, Identifiable, Sendable {
  case tight
  case standard
  case loose

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .tight: "Tight"
    case .standard: "Standard"
    case .loose: "Loose"
    }
  }

  /// Concrete gap size in points. Applied as both the resize-handle
  /// thickness and the workspace outer margin.
  public var value: CGFloat {
    switch self {
    case .tight: 2
    case .standard: 6
    case .loose: 10
    }
  }

  public static func resolve(_ identifier: String?) -> PaneGapPreset {
    guard let identifier else { return .standard }
    return PaneGapPreset(rawValue: identifier) ?? .standard
  }
}
