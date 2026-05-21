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
}
