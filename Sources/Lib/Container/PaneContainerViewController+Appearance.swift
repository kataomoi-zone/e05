import AppKit
import GhosttyKit

extension PaneContainerViewController {
  /// Push the host's light/dark scheme into every live ghostty
  /// surface so the `light:` / `dark:` branch of a conditional
  /// `theme` config takes effect on an OS appearance flip.
  /// `setColorScheme` on the app object alone only updates app-wide
  /// state — each surface keeps its own `config_conditional_state`
  /// seeded at creation, so without this per-surface fan-out
  /// existing panes keep rendering the theme branch they were born
  /// with.
  public func applyTerminalColorScheme(_ scheme: GhosttyColorScheme) {
    for workspace in workspaces {
      for column in workspace.columns {
        for pane in column.panes {
          guard let surface = pane.terminalView?.surface else { continue }
          ghosttyApp.setSurfaceColorScheme(surface: surface, scheme: scheme)
        }
      }
    }
  }

  /// Force every pane chrome view to re-resolve its dynamic NSColor
  /// caches against the supplied appearance, and stamp `webView
  /// .appearance` so WebKit follows the flip on its own surface.
  ///
  /// The caller passes the *target* appearance (the one just installed
  /// on `NSApp.appearance`), not the view's `effectiveAppearance`:
  /// AppKit does not synchronously propagate a `window.appearance`
  /// swap to every subview's `effectiveAppearance` reader, so a fan-
  /// out that read `effectiveAppearance` would resolve dynamic colors
  /// against the *previous* theme and leave layers painted with the
  /// stale palette. Symptoms include an `about:blank` pane that stays
  /// white after a dark switch and a URL bar that keeps its light fill.
  public func applyThemeChrome(under appearance: NSAppearance) {
    for workspace in workspaces {
      for column in workspace.columns {
        for pane in column.panes {
          pane.urlBar.refreshAppearance(under: appearance)
          pane.headerView.refreshAppearance(under: appearance)
          pane.browserView?.refreshAppearance(under: appearance)
        }
      }
    }
  }

  /// Re-apply the workspace accent palette: reload the worklane so
  /// the sidebar stripes / pane row colors paint with the new colors,
  /// and refresh the focused-pane border on every workspace because
  /// its colour is keyed to the workspace accent. The value itself
  /// comes from ``accentColor(forWorkspaceAt:)``, which re-reads
  /// ``PreferencesStore`` on every call, so this fan-out is the only
  /// seam where the chrome actually picks up the new palette.
  public func applyAccentPalette() {
    sidebarVC?.reloadWorklane()
    applyFocusBorderToAllWorkspaces()
  }

  /// Re-apply the focused-pane border width. The reader
  /// (``focusBorderWidth``) already returns the live preset value,
  /// but unchanged focus state means ``applyFocusBorder`` does not
  /// otherwise re-fire — this fan-out walks every workspace's
  /// focused pane and re-applies so the new thickness shows up
  /// without the user moving focus first. Unfocused panes have
  /// `borderWidth = 0` and need no touch.
  public func applyPaneBorderWidth() {
    applyFocusBorderToAllWorkspaces()
  }

  private func applyFocusBorderToAllWorkspaces() {
    for workspace in workspaces {
      if let pane = workspace.columns[safe: workspace.focusedColumnIndex]?
        .focusedPane
      {
        applyFocusBorder(pane, in: workspace)
      }
    }
  }

  /// Re-apply the current ``PaneGapPreset`` value across every live
  /// layout slot that depends on it: each workspace's outer edge
  /// inset, each column's height pin (which reserves the perimeter),
  /// and every resize-handle thickness. The values themselves come
  /// from ``PaneResizeHandle.handleSize`` / ``WorkspaceViewController.outerMargin``,
  /// which read the live preference on every access, so this fan-out
  /// is the single seam where the layout actually picks up the new
  /// gap.
  public func applyPaneGap() {
    let gap = PaneResizeHandle.handleSize
    let perimeter = WorkspaceViewController.outerMargin

    for vc in workspaceVCs {
      vc.stackView.edgeInsets = NSEdgeInsets(
        top: perimeter, left: perimeter, bottom: perimeter, right: perimeter
      )
      for case let handle as PaneResizeHandle in vc.stackView.arrangedSubviews {
        handle.sizeConstraint?.constant = gap
      }
    }
    for workspace in workspaces {
      for column in workspace.columns {
        column.heightPin?.constant = -(perimeter * 2)
        for case let handle as PaneResizeHandle in column.containerView.arrangedSubviews {
          handle.sizeConstraint?.constant = gap
        }
      }
    }
    view.layoutSubtreeIfNeeded()
  }
}
