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
