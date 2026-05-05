import AppKit
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "FinderPane")

/// "Open With..." flow for the finder pane. Finder presents this as
/// a submenu of recommended apps plus an "Other..." entry; e05
/// collapses it to a single `NSOpenPanel` because the default Open
/// action (double-click / Open menu item / `↵`) already routes the
/// row through Launch Services for the recommended app, so the
/// only case left to cover is "open with something else." Skipping
/// the submenu also avoids re-enumerating the recommendation list
/// (and the icon resolution that goes with it) for every right-click.
extension FinderPaneView {
  public func openSelectionWithChosenApplication() {
    let urls = tableView.selectedRowIndexes.compactMap { idx -> URL? in
      idx < items.count ? items[idx].url : nil
    }
    guard !urls.isEmpty, let window = tableView.window else { return }

    let panel = NSOpenPanel()
    panel.title = "Choose Application"
    panel.message = "Select an application to open the selection."
    panel.prompt = "Open"
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.directoryURL = URL(fileURLWithPath: "/Applications")

    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let appURL = panel.url else { return }
      // One `open(_:withApplicationAt:…)` call per batch, not per
      // file — opening, say, five images in Pixelmator from a
      // single Finder selection is a single window with five tabs,
      // not five separate launches racing for the same app's
      // splash screen. Launch Services aggregates them when handed
      // to the same app URL in one shot.
      let configuration = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.open(
        urls,
        withApplicationAt: appURL,
        configuration: configuration
      ) { _, error in
        if let error {
          logger.error(
            "Open With \(appURL.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }
  }
}
