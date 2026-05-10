import CoreGraphics

/// Layout-metric tokens shared across UI surfaces.
///
/// Mirrors `AppColors` in role: a single source of truth for values
/// that recur in multiple call sites and need to stay in lockstep.
/// Keeping them here makes a future-design pass (e.g. picking a new
/// chrome radius) a one-file change instead of a window-shop-around.
enum AppMetrics {
  /// Rounded-corner radius for chrome surfaces — Liquid Glass
  /// material (find bar, command palette, sidebar, suggestion list,
  /// URL dropdown) and the pane chrome's containerView. macOS 26
  /// Tahoe's window corners are visually compatible at this radius
  /// (lessons.md "NSGlassEffectView の cornerRadius") so a sidebar
  /// flush with the parent's leading edge picks up the parent
  /// window's rounded clip without a visible seam.
  static let surfaceCornerRadius: CGFloat = 12
}
