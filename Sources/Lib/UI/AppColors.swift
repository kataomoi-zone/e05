import AppKit

/// Color tokens for surfaces, borders, and overlays.
///
/// Each constant returns a dynamic `NSColor` that resolves to the
/// dark value under `darkAqua` (and variants that `bestMatch`
/// `.darkAqua`) and to the light value otherwise. The light values
/// are first-cut drafts — implementations may need fine-tuning once
/// the Theme picker exposes the light appearance.
///
/// Text colors stay at their call sites through `NSColor.labelColor`
/// and friends: they form a hierarchy (primary / secondary /
/// accessory) that wants its own pass, not a value-by-value rename.
enum AppColors {
  // MARK: - Surfaces

  /// Pane body fill — BrowserPaneView background and webView under-page.
  static let paneSurface = dynamic(
    light: NSColor(white: 0.97, alpha: 1.0),
    dark: NSColor(white: 0.15, alpha: 1.0))

  /// Translucent variant of `paneSurface` for floating suggestion lists.
  static let paneSurfaceTranslucent = dynamic(
    light: NSColor(white: 0.97, alpha: 0.95),
    dark: NSColor(white: 0.15, alpha: 0.95))

  /// Floating-panel surface — URL bar (folded), folded-label background.
  /// Slightly darker than `paneSurface` so popovers read as elevated.
  static let popoverSurface = dynamic(
    light: NSColor(white: 0.98, alpha: 1.0),
    dark: NSColor(white: 0.12, alpha: 1.0))

  /// Translucent variant of `popoverSurface` for command palette.
  static let popoverSurfaceTranslucent = dynamic(
    light: NSColor(white: 0.98, alpha: 0.95),
    dark: NSColor(white: 0.12, alpha: 0.95))

  /// Find-bar overlay surface — sits on pane content, more translucent
  /// than other popovers so the underlying page stays partially visible.
  static let findBarSurface = dynamic(
    light: NSColor(white: 0.97, alpha: 0.92),
    dark: NSColor(white: 0.13, alpha: 0.92))

  /// Pane header chrome — sits over pane background, partly translucent
  /// so the pane content shows through faintly.
  static let paneHeaderSurface = dynamic(
    light: NSColor(white: 0.95, alpha: 0.7),
    dark: NSColor(white: 0.1, alpha: 0.7))

  /// Very-dark surface for the Finder status bar (sits below content).
  static let statusBarSurface = dynamic(
    light: NSColor(white: 0.93, alpha: 1.0),
    dark: NSColor(white: 0.08, alpha: 1.0))

  /// Translucent variant for the hover-link overlay.
  static let hoverLinkSurface = dynamic(
    light: NSColor(white: 0.95, alpha: 0.92),
    dark: NSColor(white: 0.08, alpha: 0.92))

  /// Workspace background — neutral gray, intentionally lighter than
  /// pane surfaces so pane edges read against it.
  static let workspaceBackground = dynamic(
    light: NSColor(white: 0.85, alpha: 1.0),
    dark: NSColor(white: 0.5, alpha: 1.0))

  /// Sidebar glass tint applied to the dark-mode NSVisualEffectView.
  static let sidebarGlassTint = dynamic(
    light: NSColor(white: 0.9, alpha: 0.3),
    dark: NSColor(white: 0.05, alpha: 0.3))

  // MARK: - Borders

  /// Popover / palette / suggestion-list border — slightly lit so the
  /// rounded edge reads against the dark fill.
  static let popoverBorder = dynamic(
    light: NSColor(white: 0.7, alpha: 1.0),
    dark: NSColor(white: 0.3, alpha: 1.0))

  /// Find-bar border — same value as `hoverOverlay` by coincidence, but
  /// the role differs (border vs. overlay), so they're separate tokens.
  static let findBarBorder = dynamic(
    light: NSColor(white: 0.0, alpha: 0.08),
    dark: NSColor(white: 1.0, alpha: 0.08))

  /// Toast container border.
  static let toastBorder = dynamic(
    light: NSColor(white: 0.0, alpha: 0.18),
    dark: NSColor(white: 1.0, alpha: 0.18))

  // MARK: - Hover / active overlays

  /// Standard row-hover highlight — used by PaneRow, WorkspaceHeaderRow,
  /// and the Places list. CALayer-friendly (apply via `.cgColor`).
  static let hoverOverlay = dynamic(
    light: NSColor(white: 0.0, alpha: 0.08),
    dark: NSColor(white: 1.0, alpha: 0.08))

  /// Stronger hover for icon buttons — slightly brighter so a
  /// hovered icon button reads as more interactive than a hovered row.
  static let buttonHoverOverlay = dynamic(
    light: NSColor(white: 0.0, alpha: 0.1),
    dark: NSColor(white: 1.0, alpha: 0.1))

  /// Filled state for an active / pinned button.
  static let activeOverlay = dynamic(
    light: NSColor(white: 0.0, alpha: 0.15),
    dark: NSColor(white: 1.0, alpha: 0.15))

  // MARK: - Helpers

  /// Build a dynamic `NSColor` that resolves to `dark` under
  /// `darkAqua` and to `light` otherwise. Uses `bestMatch` so other
  /// accessibility variants (high-contrast, vibrant) still pick the
  /// closer base appearance instead of falling through.
  private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      let match = appearance.bestMatch(from: [.aqua, .darkAqua])
      return match == .darkAqua ? dark : light
    }
  }
}
