import AppKit

/// Menu-item dispatch surface for the registered ``Action`` registry.
///
/// Lives on ``PaneContainerViewController`` rather than the AppDelegate
/// so menu commands carry main-window-scoped semantics. Two layers
/// cooperate to keep an auxiliary panel (Settings, Get Info, Quick
/// Look, ...) from triggering Pane-menu actions while it owns key
/// focus:
///
/// 1. Menu items are built with `target == nil` and their selector
///    set to ``performAction(_:)``. AppKit dispatches via the
///    responder chain, so the controller — installed as the main
///    window's `contentViewController` — is the natural receiver
///    while the main window is key.
/// 2. ``validateMenuItem(_:)`` then refuses the item unless the
///    controller's hosting window is the key window. AppKit's
///    `targetForAction(_:to:from:)` walks **both the key window's
///    responder chain and the main window's** (`NSApplication.h`
///    "Responding to NSResponder Messages"), so when an `NSPanel`
///    is key the controller still reads as a candidate via the
///    main window's chain. Without this gate every Pane-menu chord
///    (⌘F / ⌘T / ⌘N / ⌃Tab / ...) would slam the main pane while
///    the user is typing into Settings; with it, AppKit greys the
///    items so the boundary is visible in the menu itself.
///
/// Menu items are constructed in `AppDelegate.setupMenuKeyBindings`
/// and tagged by their index into the snapshot pushed here through
/// ``menuActionsSnapshot``. AppDelegate keeps its own cache for the
/// snapshot-diff listener gate that decides when to rebuild the menu
/// — the two arrays are written from the same source so the tag map
/// stays consistent across the menu and the dispatch path.
extension PaneContainerViewController: NSMenuItemValidation {
  @objc public func performAction(_ sender: NSMenuItem) {
    let snapshot = menuActionsSnapshot
    guard snapshot.indices.contains(sender.tag) else { return }
    snapshot[sender.tag].handler()
  }

  public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard menuItem.action == #selector(performAction(_:)) else {
      return true
    }
    let snapshot = menuActionsSnapshot
    guard snapshot.indices.contains(menuItem.tag) else { return true }
    let action = snapshot[menuItem.tag]
    // `close_pane` is the rescue chord that covers both the main
    // pane close and an auxiliary panel's own close path (the
    // handler dispatches on `NSApp.keyWindow`). Keep it enabled in
    // both focus states so AppKit's keyEquivalent search — which
    // stops at the first matching menu item — always lands here
    // rather than dead-ending on a disabled twin. Rename the item
    // to match the live action: the menu visibly tells the user
    // whether a click closes the pane or the foreground panel,
    // even when the user reached it through the menu bar rather
    // than the chord.
    if action.id == "close_pane" {
      if let key = NSApp.keyWindow, key !== view.window {
        menuItem.title = "Close Window"
      } else {
        menuItem.title = "Close Pane"
      }
      return true
    }
    // Grey the rest of the Pane menu when an auxiliary panel
    // (Settings, Get Info, Quick Look, ...) owns key focus. AppKit
    // reaches the controller through the main window's chain even
    // then (NSApplication walks both the key and main window's
    // responder chains, see class doc), so without this explicit
    // check the items stay enabled and ⌘F / ⌘T / ⌘N etc. fire
    // against the underlying pane while the user is typing into
    // the panel.
    guard view.window?.isKeyWindow == true else {
      return false
    }
    // Disable every e05 action while the controller's host window
    // has a sheet attached. The modern
    // `requestMediaCapturePermissionFor` hook ships with WebKit's
    // own modal hold so the parent window's key dispatch is
    // suspended for free, but the legacy
    // `_webView:requestGeolocationPermissionForOrigin:...` SPI does
    // not — without this guard a geolocation prompt sees ⌘W slip
    // through to `removeCurrentPane`, the pane vanishes mid-sheet,
    // and AppKit leaves the modal dim layer orphaned on the host
    // window.
    if view.window?.attachedSheet != nil {
      return false
    }
    guard let validate = action.validate else { return true }
    let result = validate()
    if let title = result.title {
      menuItem.title = title
    }
    return result.enabled
  }
}
