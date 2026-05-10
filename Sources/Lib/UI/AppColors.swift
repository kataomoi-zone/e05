import AppKit

/// Dark-theme color tokens for surfaces, borders, and overlays.
///
/// e05 is dark-only by invariant (status.md), so these `white:`-grayscale
/// fills bypass system dynamic-color resolution to keep dark surfaces
/// consistent regardless of host appearance. When a light-theme pass
/// lands, every call site routes through this enum so the migration is
/// confined to one file.
///
/// Text colors are intentionally left at their call sites: they form a
/// hierarchy (primary / secondary / accessory) that wants its own pass,
/// not a value-by-value rename.
enum AppColors {
  // MARK: - Surfaces

  /// Pane body fill — BrowserPaneView background and webView under-page.
  static let paneSurface = NSColor(white: 0.15, alpha: 1.0)

  /// Translucent variant of `paneSurface` for floating suggestion lists.
  static let paneSurfaceTranslucent = NSColor(white: 0.15, alpha: 0.95)

  /// Floating-panel surface — URL bar (folded), folded-label background.
  /// Slightly darker than `paneSurface` so popovers read as elevated.
  static let popoverSurface = NSColor(white: 0.12, alpha: 1.0)

  /// Translucent variant of `popoverSurface` for command palette.
  static let popoverSurfaceTranslucent = NSColor(white: 0.12, alpha: 0.95)

  /// Find-bar overlay surface — sits on pane content, more translucent
  /// than other popovers so the underlying page stays partially visible.
  static let findBarSurface = NSColor(white: 0.13, alpha: 0.92)

  /// Pane header chrome — sits over pane background, partly translucent
  /// so the pane content shows through faintly.
  static let paneHeaderSurface = NSColor(white: 0.1, alpha: 0.7)

  /// Very-dark surface for the Finder status bar (sits below content).
  static let statusBarSurface = NSColor(white: 0.08, alpha: 1.0)

  /// Translucent variant for the hover-link overlay.
  static let hoverLinkSurface = NSColor(white: 0.08, alpha: 0.92)

  /// Workspace background — neutral gray, intentionally lighter than
  /// pane surfaces so pane edges read against it.
  static let workspaceBackground = NSColor(white: 0.5, alpha: 1.0)

  /// Sidebar glass tint applied to the dark-mode NSVisualEffectView.
  static let sidebarGlassTint = NSColor(white: 0.05, alpha: 0.3)

  // MARK: - Borders

  /// Popover / palette / suggestion-list border — slightly lit so the
  /// rounded edge reads against the dark fill.
  static let popoverBorder = NSColor(white: 0.3, alpha: 1.0)

  /// Find-bar border — same value as `hoverOverlay` by coincidence, but
  /// the role differs (border vs. overlay), so they're separate tokens.
  static let findBarBorder = NSColor(white: 1.0, alpha: 0.08)

  /// Toast container border.
  static let toastBorder = NSColor(white: 1.0, alpha: 0.18)

  // MARK: - Hover / active overlays

  /// Standard row-hover highlight — used by PaneRow, WorkspaceHeaderRow,
  /// and the Places list. CALayer-friendly (apply via `.cgColor`).
  static let hoverOverlay = NSColor(white: 1.0, alpha: 0.08)

  /// Stronger hover for icon buttons — slightly brighter so a
  /// hovered icon button reads as more interactive than a hovered row.
  static let buttonHoverOverlay = NSColor(white: 1.0, alpha: 0.1)

  /// Filled state for an active / pinned button.
  static let activeOverlay = NSColor(white: 1.0, alpha: 0.15)
}
