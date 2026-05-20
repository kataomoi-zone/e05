import CoreGraphics

/// Pane border width preset. Drives the line width of the focused-
/// pane border, the folded-column label outline, and the dotted
/// private-pane border — every paint that emphasises a single pane
/// against its neighbours. The worklane sidebar accent indicator is
/// not driven by this preset; that strip stays at its built-in
/// width because changing it would push the cell label around at
/// each preset switch.
///
/// Unknown identifiers resolve to ``regular``, which preserves the
/// historical 2pt border the codebase shipped with.
public enum PaneBorderWidthPreset: String, CaseIterable, Identifiable, Sendable {
  case thin
  case regular
  case bold

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .thin: "Thin"
    case .regular: "Regular"
    case .bold: "Bold"
    }
  }

  /// Concrete border width in points.
  public var value: CGFloat {
    switch self {
    case .thin: 1
    case .regular: 2
    case .bold: 3
    }
  }

  public static func resolve(_ identifier: String?) -> PaneBorderWidthPreset {
    guard let identifier else { return .regular }
    return PaneBorderWidthPreset(rawValue: identifier) ?? .regular
  }
}
