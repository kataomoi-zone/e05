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
///
/// The accessory bar above the panel's footer mirrors Finder:
///
/// - An "Enable" popup toggles between "Recommended Applications"
///   (the Launch Services list for the first selected file) and
///   "All Applications" (no filter). The recommended set is
///   computed once at sheet open and held by
///   `OpenWithFilterCoordinator` for `panel(_:shouldEnable:)` to
///   consult. Multi-select uses the first selection as the
///   recommendation basis — same as Finder.
/// - An "Always Open With" checkbox persists the chosen app as the
///   per-URL default via
///   `NSWorkspace.setDefaultApplication(at:toOpenFileAt:)`
///   (macOS 12+). The binding lives in the file's metadata, not
///   the global UTI handler list, so it only affects the selected
///   file and leaves other entries of the same kind untouched.
///   Disabled in multi-select to mirror Finder's UI.
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

    let coordinator = OpenWithFilterCoordinator(
      panel: panel,
      recommendedFor: urls[0],
      allowsAlwaysBinding: urls.count == 1)
    panel.delegate = coordinator
    panel.accessoryView = coordinator.accessoryView
    // Older AppKit hides the accessory view by default behind a
    // "Show Options" disclosure. Forcing it visible keeps the
    // popup reachable without an extra click on every invocation.
    panel.isAccessoryViewDisclosed = true

    panel.beginSheetModal(for: window) { [coordinator] response in
      // Hold the coordinator alive across the modal session.
      // `delegate` is unowned-on-AppKit, the local closure capture
      // is what keeps it from deallocating mid-validation.
      _ = coordinator
      guard response == .OK, let appURL = panel.url else { return }
      // Persist the per-URL binding before the launch fires so
      // even if the open call fails (signature blocked / quarantined
      // app), the user's "always" intent is recorded for next time.
      // Single-select only — the checkbox is disabled in multi-select.
      //
      // The binding attaches to the URL the user actually clicked,
      // not its resolved target: a Finder alias / symlink keeps its
      // own routing, the underlying file's binding is left alone.
      // That matches Finder's "Always Open With" semantics — and is
      // what the user would expect, since the right-click menu was
      // raised from the alias row, not the source. Failures are
      // logged at error level only; e05 has no inline notification
      // surface yet, and a modal alert would interrupt the launch
      // flow that's about to follow.
      if coordinator.alwaysBindingChecked, let target = urls.first {
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenFileAt: target) { error in
          if let error {
            logger.error(
              "Set default \(appURL.lastPathComponent, privacy: .public) for \(target.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
          }
        }
      }
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

/// Owns the accessory popup and answers `panel(_:shouldEnable:)`
/// based on the user's filter choice.
///
/// `NSOpenPanel.delegate` is held with the documented "no retain"
/// contract — the caller is responsible for keeping the delegate
/// alive while the sheet is up. `openSelectionWithChosenApplication`
/// captures this object in the completion closure to satisfy that.
@MainActor
private final class OpenWithFilterCoordinator: NSObject, NSOpenSavePanelDelegate {
  let accessoryView: NSView
  private weak var panel: NSOpenPanel?
  private let recommendedAppPaths: Set<String>
  private let alwaysCheckbox: NSButton
  private var filterMode: FilterMode = .recommended

  enum FilterMode {
    case recommended
    case all
  }

  /// `true` when the "Always Open With" checkbox is on. Read by the
  /// open-panel completion handler to decide whether to persist the
  /// per-URL binding via `setDefaultApplication`.
  var alwaysBindingChecked: Bool {
    alwaysCheckbox.isEnabled && alwaysCheckbox.state == .on
  }

  init(panel: NSOpenPanel, recommendedFor sourceURL: URL, allowsAlwaysBinding: Bool) {
    self.panel = panel
    // `urlsForApplications(toOpen:)` returns the same Launch Services
    // candidates Finder lists in its Open With submenu. Path-set
    // membership is what `panel(_:shouldEnable:)` checks, so we cache
    // the resolved paths once instead of re-querying per row. We
    // assume Launch Services hands back canonical `/Applications`-
    // rooted paths (no `~/Applications` symlink resolution drift) —
    // verified empirically; if a future macOS version starts mixing
    // user-scope paths in, the lookup would silently miss and the
    // filter would over-grey the panel. `panel(_:shouldEnable:)`'s
    // own URL is whatever the panel hands us during navigation, so
    // both sides come from the same Launch Services-managed tree.
    let recommendedURLs = NSWorkspace.shared.urlsForApplications(toOpen: sourceURL)
    self.recommendedAppPaths = Set(recommendedURLs.map { $0.path(percentEncoded: false) })

    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    popup.translatesAutoresizingMaskIntoConstraints = false
    popup.addItem(withTitle: "Recommended Applications")
    popup.addItem(withTitle: "All Applications")
    popup.selectItem(at: 0)

    let label = NSTextField(labelWithString: "Enable:")
    label.translatesAutoresizingMaskIntoConstraints = false

    let popupRow = NSStackView(views: [label, popup])
    popupRow.translatesAutoresizingMaskIntoConstraints = false
    popupRow.orientation = .horizontal
    popupRow.spacing = 8
    popupRow.alignment = .firstBaseline

    let checkbox = NSButton(
      checkboxWithTitle: "Always Open With", target: nil, action: nil)
    checkbox.translatesAutoresizingMaskIntoConstraints = false
    // `isEnabled = false` greys out the checkbox the same way Finder
    // does in multi-select: the per-URL binding API works one URL
    // at a time, so applying "always" to a heterogeneous batch
    // would either need looping (unintuitive — the user expects a
    // single binding choice) or skipping (silently misleading).
    // Locking the multi-select case out of the UI is the cleanest
    // signal.
    checkbox.isEnabled = allowsAlwaysBinding

    let stack = NSStackView(views: [popupRow, checkbox])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.spacing = 6
    stack.alignment = .leading
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)

    self.accessoryView = stack
    self.alwaysCheckbox = checkbox

    super.init()

    popup.target = self
    popup.action = #selector(filterModeChanged(_:))
  }

  @objc private func filterModeChanged(_ sender: NSPopUpButton) {
    filterMode = sender.indexOfSelectedItem == 0 ? .recommended : .all
    // Force the visible column to re-query `panel(_:shouldEnable:)`
    // for each entry — without this poke, rows that became enabled
    // by switching to "All" stay greyed until the user clicks them.
    panel?.validateVisibleColumns()
  }

  func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
    // Directory rows ("/Applications/Utilities/" etc.) must always
    // remain enabled so the user can drill into them, regardless of
    // the filter mode — the filter only constrains which `.app`
    // bundles are selectable. Other package bundles (`.framework`,
    // `.bundle`, `.plugin`, `.kext`, `.appex`, …) are directories on
    // disk but Launch Services doesn't treat them as launchable, so
    // we fold them in with `.app` and let the filter decide. The
    // `isPackageKey` check is what distinguishes the `Utilities/`
    // case (drillable) from the `Calculator.app` case (selectable
    // when filter allows, opaque always).
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
    let isDirectory = values?.isDirectory == true
    let isPackage = values?.isPackage == true
    let isApplication = url.pathExtension == "app"
    if isDirectory && !isPackage {
      return true
    }
    if isPackage && !isApplication {
      return false
    }
    switch filterMode {
    case .all:
      return true
    case .recommended:
      return recommendedAppPaths.contains(url.path(percentEncoded: false))
    }
  }
}
