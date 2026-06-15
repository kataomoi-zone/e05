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

  /// Live pane container — the Shortcuts tab reads `actions()` from
  /// here to enumerate the registered key chords. The pane container
  /// VC lives in the same target as Settings (`E05Lib`), so wiring
  /// it through this controller keeps the AppKit target free from a
  /// reverse dependency. Seeded by the host app on launch; left
  /// `nil` in unit tests where Settings is constructed in isolation.
  public weak var paneContainer: PaneContainerViewController?

  /// Token for the local mouse-down monitor that blurs a focused text
  /// field when the user clicks a non-text control (installed in `init`).
  /// `nonisolated(unsafe)` so the nonisolated `deinit` can remove it
  /// (`removeMonitor` is thread-safe) without a MainActor hop.
  nonisolated(unsafe) private var clickMonitor: Any?

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

    // Drop text-field focus when a click lands on a non-text control, so
    // the caret doesn't stay parked in the search box after the user
    // moves on to a picker or button — AppKit leaves first responder on
    // the text field otherwise. Local monitor scoped to this panel.
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
      [weak self] event in
      self?.resignTextFocusIfClickedOutside(event)
      return event
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  deinit {
    if let clickMonitor {
      NSEvent.removeMonitor(clickMonitor)
    }
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

  /// Resign the panel's text first responder when `event` clicks a
  /// non-text control, so a focused search / text field "deselects"
  /// instead of holding the caret. No-op unless a text field is being
  /// edited and the click misses every text control (the search field,
  /// its field editor, or another text field that should take focus).
  private func resignTextFocusIfClickedOutside(_ event: NSEvent) {
    guard let window, event.window === window,
      let contentView = window.contentView,
      window.firstResponder is NSText
    else { return }
    let point = contentView.convert(event.locationInWindow, from: nil)
    let hit = contentView.hitTest(point)
    if hit is NSText || hit is NSTextField { return }
    window.makeFirstResponder(nil)
  }
}
