import AppKit
import SwiftUI

/// Host for the Settings panel. The shared `.shared` instance keeps
/// the singleton invariant: a second `show()` call brings the existing
/// panel forward instead of opening a second copy.
///
/// `NSPanel` (rather than `NSWindow`) matches the other auxiliary
/// surfaces in e05 (Get Info inspector, Operations progress panel,
/// popup overlays) — the 1-window invariant explicitly admits
/// auxiliary panels as exceptions, and Settings fits that mould.
/// `hidesOnDeactivate = false` keeps the window reachable while the
/// user references a browser pane in the main window.
@MainActor
public final class SettingsWindowController: NSWindowController {
  public static let shared = SettingsWindowController()

  /// Strong-typed init that builds the panel once. Subsequent
  /// ``show()`` calls reuse the same window instance so user-resized
  /// geometry persists for the rest of the process lifetime.
  init() {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 840, height: 600),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: true
    )
    panel.title = "Settings"
    panel.titlebarAppearsTransparent = false
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.fullScreenAuxiliary]
    panel.center()
    super.init(window: panel)
    panel.contentView = NSHostingView(rootView: SettingsRootView())
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// Bring the panel to the front, creating it lazily through the
  /// shared init if this is the first call. `makeKeyAndOrderFront`
  /// also activates the app so a palette-driven open from a
  /// background context surfaces the window without an extra click.
  public func show() {
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }
}
