import AppKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "FinderPane")

/// Pasteboard interop for the finder pane. Each selected entry is
/// written as `NSURL`, which the AppKit pasteboard machinery
/// promises in both the file-URL and string-URL flavours — that's
/// what makes a paste interoperate with Finder (⌘V / ⌘⌥V), with
/// drop targets that bind to `kPasteboardTypeFileURL`, and with
/// terminal panes that consume the path as text. The Paste side
/// reverses the flow: it reads file URLs from the same pasteboard
/// and copies them into the current cwd, escalating to
/// `<name> copy[.ext]` on collision so a same-cwd paste mirrors
/// Duplicate's outcome rather than refusing.
extension FinderPaneView {
  // MARK: - Copy

  public func copySelectionToPasteboard() {
    let urls = selectedURLs
    guard !urls.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects(urls as [NSURL])
  }

  /// Write the POSIX path of each selected entry onto the general
  /// pasteboard as a plain `.string`, one path per line for
  /// multi-select (matching macOS Finder's ⌥⌘C behaviour). Distinct
  /// from `copySelectionToPasteboard` which writes file URLs in the
  /// pasteboard's URL flavour: a path-only payload pastes cleanly into
  /// terminals, editors, and shell scripts that don't decode the
  /// `kPasteboardTypeFileURL` representation. The two helpers
  /// overwrite each other on the pasteboard — that's a deliberate
  /// match for the menu items being separate one-shot choices.
  public func copyPathnamesToPasteboard() {
    let urls = selectedURLs
    guard !urls.isEmpty else { return }
    let joined = urls.map { $0.path(percentEncoded: false) }.joined(separator: "\n")
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(joined, forType: .string)
  }

  // MARK: - Paste

  /// Number of file URLs currently on the general pasteboard. The
  /// context menu uses this for the `Paste Item` / `Paste N Items`
  /// label and to grey the entry out when nothing pasteable is
  /// available.
  func pasteableFileURLCount() -> Int {
    let pb = NSPasteboard.general
    let urls = pb.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]) as? [URL]
    return urls?.count ?? 0
  }

  /// Copy each file URL on the general pasteboard into the current
  /// cwd. The preferred target keeps the source name; collisions
  /// escalate to `<stem> copy[.ext]` via the shared
  /// `availableCopyURL` helper — that mirrors Finder's "Keep Both"
  /// outcome rather than its modal Replace dialog. Failures log and
  /// continue per-item, matching `trashSelection` /
  /// `duplicateSelection` conventions.
  ///
  /// Newly pasted entries are selected after the reload so the user
  /// can immediately Rename / Trash / duplicate-again. The actual
  /// copies run off-main via `runCopyBatch` so a multi-GB or
  /// cross-volume paste doesn't freeze the pane.
  public func pasteFromPasteboard() {
    let pb = NSPasteboard.general
    guard
      let sources = pb.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]) as? [URL],
      !sources.isEmpty
    else { return }
    let plans: [(source: URL, target: URL)] = sources.map { source in
      (source, pasteTargetURL(for: source))
    }
    runCopyBatch(plans: plans, label: FinderUndoActionName.paste)
  }

  /// Try `currentURL/<source-name>` first; on collision escalate
  /// to the `<stem> copy[.ext]` slot. Pasting into the source's
  /// own directory therefore behaves like Duplicate, which is what
  /// Finder does when the user pastes a same-cwd clipboard entry.
  private func pasteTargetURL(for source: URL) -> URL {
    let primary = currentURL.appendingPathComponent(source.lastPathComponent)
    if !FileManager.default.fileExists(atPath: primary.path(percentEncoded: false)) {
      return primary
    }
    return availableCopyURL(
      in: currentURL,
      stem: source.deletingPathExtension().lastPathComponent,
      ext: source.pathExtension)
  }

  // MARK: - NSResponder actions

  /// `copy:` / `paste:` arrive at the finder pane through the standard
  /// responder chain whenever the menu-bar Edit > Copy / Paste items
  /// (`AppDelegate.setupMainMenu`) fire — AppKit walks first responder
  /// → super → window → app delegate looking for a matching selector,
  /// and a finder pane sits on that walk. Implementing them here is
  /// what makes ⌘C / ⌘V work without a per-pane keyDown hook, and it
  /// also keeps the menu-bar items enabled (AppKit greys them out
  /// when no responder advertises the selector).
  @objc public func copy(_ sender: Any?) {
    copySelectionToPasteboard()
  }

  @objc public func paste(_ sender: Any?) {
    pasteFromPasteboard()
  }
}

extension FinderPaneView: NSMenuItemValidation {
  /// AppKit asks every responder on the chain whether their menu
  /// items are eligible. Without this, menu-bar Edit > Copy / Paste
  /// stay enabled whenever a finder pane has focus — pressing them
  /// then no-ops silently. Returning false greys them out so the
  /// menu-bar state matches the right-click context menu, which
  /// already greys out "Paste Item" via `action: nil` when the
  /// pasteboard is empty.
  public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(copy(_:)):
      return hasSelection
    case #selector(paste(_:)):
      return pasteableFileURLCount() > 0
    case #selector(undo(_:)):
      // Push the action name into the menu item's title so Edit >
      // Undo shows "Undo Rename" / "Redo Rename" mid-edit. AppKit's
      // built-in NSTextField undo wires this for free; our
      // self-dispatched path doesn't, so the validation pass — the
      // last hook before the menu draws — is where we sync it.
      menuItem.title = FinderUndoCenter.manager.undoMenuItemTitle
      return FinderUndoCenter.manager.canUndo
    case #selector(redo(_:)):
      menuItem.title = FinderUndoCenter.manager.redoMenuItemTitle
      return FinderUndoCenter.manager.canRedo
    default:
      return true
    }
  }

  /// Routes the menu-bar `undo:` / `redo:` selectors (wired in
  /// `AppDelegate.setupMainMenu`) into `FinderUndoCenter`. AppKit's
  /// responder-chain dispatch needs an actual method on a responder
  /// — overriding `var undoManager` alone is not enough; AppKit
  /// runs `respondsToSelector(undo:)` against the responder, and a
  /// pure `undoManager` provider would fail that test.
  ///
  /// Captures the action name *before* invoking the manager: the
  /// action that's about to run lives on `undoActionName` while
  /// it's still on the undo stack, but as soon as the closure
  /// finishes the entry has moved to the redo stack and
  /// `undoActionName` would point at whatever is now next on the
  /// undo stack instead. Same logic in mirror for `redo:`.
  ///
  /// The action name is a verb baseform ("Rename", "Move to Trash")
  /// so the menu-bar Edit > Undo X / Redo X reads naturally. The
  /// toast appends a suffix ("Rename undone" / "Move to Trash
  /// redone") instead of prefixing a past tense — past-tense
  /// prefixes ("Undid Move to Trash") read awkwardly when the
  /// action name itself is already a noun phrase.
  @objc public func undo(_ sender: Any?) {
    let action = FinderUndoCenter.manager.undoActionName
    FinderUndoCenter.lastBatchPartial = nil
    FinderUndoCenter.manager.undo()
    postUndoToast(
      action: action, suffix: "undone",
      partial: FinderUndoCenter.lastBatchPartial)
    // Defensive nil after the read so callers that ever inspect
    // `lastBatchPartial` outside an undo/redo turn never see a stale
    // value. The next undo/redo's leading nil already covers the
    // happy path; this trailing one closes any external read window.
    FinderUndoCenter.lastBatchPartial = nil
  }

  @objc public func redo(_ sender: Any?) {
    let action = FinderUndoCenter.manager.redoActionName
    FinderUndoCenter.lastBatchPartial = nil
    FinderUndoCenter.manager.redo()
    postUndoToast(
      action: action, suffix: "redone",
      partial: FinderUndoCenter.lastBatchPartial)
    FinderUndoCenter.lastBatchPartial = nil
  }

  /// Surface a brief confirmation toast for a finder-pane undo/redo.
  /// Drops silently when the action name is empty (manager couldn't
  /// resolve one) or when no `PaneContainerViewController` is
  /// reachable up the responder chain — the latter happens during
  /// teardown but never in the normal click path.
  ///
  /// `partial` carries any partial-failure stats the closure wrote to
  /// `FinderUndoCenter.lastBatchPartial`. Three outcomes:
  /// - `nil` (full success or non-batch op): plain `"<action> <suffix>"`
  /// - `succeeded == 0` (full failure): suppress this toast entirely
  ///   so the user only sees the `.error` toast already posted from
  ///   `reportPartialBatchFailure`. Showing "Move to Trash undone"
  ///   alongside "5 of 5 items couldn't be restored" reads as
  ///   contradiction.
  /// - `0 < succeeded < total` (partial): `"<action> — <succeeded> of
  ///   <total> <suffix>"`. Embedding the counts directly mirrors the
  ///   error toast's `"<failed> of <total> items couldn't be …"`, so
  ///   the two lines add up to the full count without the user
  ///   parsing English. Avoids the "Move to Trash partially undone"
  ///   shape that grafts an adverb onto a verb-phrase action name.
  private func postUndoToast(
    action: String, suffix: String, partial: (succeeded: Int, total: Int)?
  ) {
    guard !action.isEmpty,
      let container = window?.contentViewController as? PaneContainerViewController
    else { return }
    if let partial, partial.succeeded == 0 { return }
    let message: String
    if let partial {
      message = "\(action) — \(partial.succeeded) of \(partial.total) \(suffix)"
    } else {
      message = "\(action) \(suffix)"
    }
    container.showToast(message)
  }
}
