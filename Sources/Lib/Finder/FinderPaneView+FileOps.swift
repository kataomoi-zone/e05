import AppKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "FinderPane")

/// Filesystem operations triggered from the right-click context
/// menu and the command palette beyond rename / new-folder / trash:
/// Duplicate, Make Alias (this file) and forthcoming Compress /
/// New Folder with Selection. Each operation logs per-item failures
/// and continues so a permission error on one entry doesn't abort
/// the rest of the batch — same convention as `trashSelection`.
extension FinderPaneView {
  // MARK: - Duplicate

  /// Copy every selected entry alongside the original under a
  /// `<name> copy[.ext]` suffix, matching Finder's ⌘D. Subsequent
  /// duplicates of the same source escalate to `<name> copy 2.ext`,
  /// `<name> copy 3.ext`, … until a free slot opens. The new entries
  /// are selected after the reload so the user can immediately
  /// Rename / Trash / duplicate-again without hunting through the
  /// table. Directories duplicate recursively via `copyItem(at:to:)`.
  public func duplicateSelection() {
    let urls = selectedURLs
    guard !urls.isEmpty else { return }
    let plans: [(source: URL, target: URL)] = urls.map { source in
      (source, duplicateTargetURL(for: source))
    }
    runCopyBatch(plans: plans, label: FinderUndoActionName.duplicate)
  }

  /// Resolve the next available `<name> copy[.ext]` slot in `source`'s
  /// parent directory. Almost always collides — Duplicate's source
  /// nearly by definition already exists — so this routes straight
  /// to `availableCopyURL`.
  private func duplicateTargetURL(for source: URL) -> URL {
    availableCopyURL(
      in: source.deletingLastPathComponent(),
      stem: source.deletingPathExtension().lastPathComponent,
      ext: source.pathExtension)
  }

  // MARK: - Make Alias

  /// Create a Finder alias next to each selected entry, naming each
  /// `<source> alias` (escalating to `<source> alias 2`, … on
  /// collision). Aliases are bookmark files written via
  /// `URL.writeBookmarkData(_:to:options: [.suitableForBookmarkFile])`
  /// — they survive moves of the source within a volume where a
  /// plain symlink would break, and that's what makes a system
  /// double-click resolve them through Launch Services to the right
  /// app even after the source has been renamed.
  ///
  /// Bookmark generation runs synchronously on the main actor: it's
  /// a metadata-only read on the source URL plus a small file write
  /// (~1 KB), nothing like the multi-GB blob copies that `runCopyBatch`
  /// shields. Failures log and continue per-item.
  public func makeAliasForSelection() {
    let urls = selectedURLs
    guard !urls.isEmpty else { return }
    var created: [URL] = []
    for source in urls {
      let target = aliasTargetURL(for: source)
      do {
        let bookmark = try source.bookmarkData(
          options: .suitableForBookmarkFile,
          includingResourceValuesForKeys: nil,
          relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: target)
        created.append(target)
      } catch {
        logger.error(
          "Make Alias failed \(source.path, privacy: .public) → \(target.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    guard !created.isEmpty else { return }
    // Notify Finder / Spotlight / other Icon Services clients that
    // the parent directory changed: their alias-icon caches
    // otherwise linger on the generic document proxy until poked.
    // e05's own iconCache is independent — `reloadItems` evicts
    // alias entries on every refresh.
    NSWorkspace.shared.noteFileSystemChanged(currentURL.path(percentEncoded: false))
    finishCopyBatch(targets: created)
    // No `FinderUndoCenter` registration — system Finder also
    // leaves Make Alias out of its undo stack since the alias is
    // a fresh bookmark file (nothing was destroyed) and ⌘⌫ trashes
    // it the same as any other entry. Registering would only
    // crowd the stack with an entry the user doesn't expect to
    // walk back through.
  }

  /// Resolve the next free `<source> alias` slot in `source`'s parent
  /// directory. Finder appends `" alias"` to the *full* filename
  /// (extension included) — `report.pdf` becomes `report.pdf alias`,
  /// not `report alias.pdf` — because the alias file is a bookmark
  /// blob, not the same file type as the source, and renaming it to
  /// keep the source's extension would mislead Launch Services.
  func aliasTargetURL(for source: URL) -> URL {
    let dir = source.deletingLastPathComponent()
    let baseName = source.lastPathComponent
    let fm = FileManager.default
    var candidate = dir.appendingPathComponent("\(baseName) alias")
    if !fm.fileExists(atPath: candidate.path(percentEncoded: false)) {
      return candidate
    }
    var n = 2
    while true {
      candidate = dir.appendingPathComponent("\(baseName) alias \(n)")
      if !fm.fileExists(atPath: candidate.path(percentEncoded: false)) {
        return candidate
      }
      n += 1
    }
  }

  // MARK: - Shared helpers

  /// Run a batch of `(source → target)` filesystem copies off the
  /// main actor, then return to MainActor to refresh the table and
  /// select the new entries. Both Duplicate and Paste route through
  /// here so the threading model and post-copy UI flow stay in one
  /// place.
  ///
  /// `Task.detached` is what keeps the pane responsive during a
  /// multi-GB or cross-volume copy. Each plan runs through
  /// `cancellableCopy`, which clones via `copyfile(3)` on an APFS
  /// same-volume target (instant) and otherwise does a real data
  /// copy — and `FinderPaneView` is `@MainActor`, so doing that work
  /// synchronously would freeze every other pane on the same window.
  ///
  /// The op is registered with `FinderOperationTracker` so the
  /// progress panel surfaces "Pasting …" / "Duplicating …" while the
  /// copy runs, and so the panel's ✕ button can stop it. The button
  /// flips a `CopyCancellationToken` the loop checks between plans and
  /// the `copyfile` callback checks mid-file, so a cancel aborts even
  /// partway through a single large file; the partial target is
  /// removed and the remaining plans are skipped.
  func runCopyBatch(plans: [(source: URL, target: URL)], label: String) {
    let opID = FinderOperationTracker.OperationID()
    let targets = plans.map { $0.target }

    // The detached task is created before `register` so the cancel
    // closure can capture it. A pathologically-fast batch could in
    // principle complete before `register` runs and enqueue an
    // unregister via `defer` that lands ahead of any panel — but
    // `scheduleShowIfNeeded` waits `panelShowDelay` (500ms) before
    // touching the panel, and same-MainActor synchronous code below
    // (`register` then `scheduleShowIfNeeded`) finishes long before
    // any child `Task { @MainActor in ... }` enqueued from the
    // detached task can land, so the panel never flashes for an op
    // that completes faster than the delay.
    let token = CopyCancellationToken()
    let progress = FinderCopyProgress()
    let task = Task.detached(priority: .userInitiated) {
      defer {
        Task { @MainActor in
          FinderOperationTracker.shared.unregister(opID)
          OperationsProgressPanel.dismissIfEmpty()
        }
      }
      // Preparing phase: tally each source's size for the determinate bar
      // (the panel stays indeterminate until the total lands), then credit
      // each plan's walked size as it finishes so the bar reaches exactly
      // 100% even for clones, which stream no callback bytes.
      let sizes = plans.map { Self.allocatedSize(of: $0.source) }
      progress.setTotalBytes(sizes.reduce(0, +))
      var done: [URL] = []
      copyLoop: for (plan, size) in zip(plans, sizes) {
        if token.isCancelled { break }
        switch Self.cancellableCopy(
          from: plan.source, to: plan.target, token: token, progress: progress)
        {
        case .completed:
          done.append(plan.target)
          progress.completePlan(bytes: size)
        case .cancelled:
          progress.discardCurrentPlan()
          break copyLoop
        case .failed(let error):
          progress.discardCurrentPlan()
          logger.error(
            "\(label, privacy: .public) failed \(plan.source.path, privacy: .public) → \(plan.target.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      }
      guard !done.isEmpty else { return }
      await MainActor.run { [weak self] in
        guard let self else { return }
        self.finishCopyBatch(targets: done)
        FinderUndoCenter.registerCreated(at: done, actionName: label, in: self)
      }
    }

    FinderOperationTracker.shared.register(
      .init(
        id: opID,
        label: progressLabel(for: label, count: plans.count),
        targetURLs: targets,
        cancel: {
          token.cancel()
          task.cancel()
        },
        progress: progress))
    OperationsProgressPanel.scheduleShowIfNeeded(near: window)
  }

  /// Render a human-readable progress label from the undo-action
  /// name + plan count: a single-item `Paste` becomes "Pasting 1
  /// item", a five-item `Duplicate` becomes "Duplicating 5 items".
  /// The continuous tense matches Finder's progress-window phrasing
  /// ("Copying …") and contrasts visually with the past-tense undo
  /// labels ("Undo Paste") so the two surfaces don't look like the
  /// same string in two places.
  private func progressLabel(for actionName: String, count: Int) -> String {
    let verb: String
    switch actionName {
    case FinderUndoActionName.paste:
      verb = "Pasting"
    case FinderUndoActionName.duplicate:
      verb = "Duplicating"
    default:
      verb = actionName
    }
    let suffix = count == 1 ? "1 item" : "\(count) items"
    return "\(verb) \(suffix)"
  }

  /// Reload the table and select every newly produced entry.
  /// `selectAfterLoad` matches by `lastPathComponent` because the
  /// directory monitor re-enumerates entries via `FileManager.enumerator`,
  /// whose trailing-slash and percent-encoding choices may not
  /// round-trip with the URLs the copy plan composed via
  /// `appendingPathComponent` — `Rename.swift` ducks the same drift
  /// the same way after `createNewFolder`. A directory's immediate
  /// children have unique names, so last-component matching is
  /// unambiguous. Used by `runCopyBatch` (off-main), `compressSelection`
  /// (off-main), and `makeAliasForSelection` (on-main) alike.
  ///
  /// The directory monitor's debounced reload follows shortly after
  /// with `preservingSelection: true` and re-resolves the same
  /// last-components, so the selection stays put — no extra
  /// coordination needed.
  ///
  /// Skip when the user has navigated away from the cwd the batch
  /// op was targeting: a multi-GB Compress or cross-volume Paste can
  /// take seconds, and during that wait the user may have moved the
  /// pane to an unrelated dir. Reloading that dir here would clobber
  /// its selection and re-enumerate it for no reason — the targets
  /// landed in the original cwd and `selectAfterLoad` against the
  /// new cwd would either match nothing or, worse, light up
  /// coincidentally-named entries. Detect by comparing the targets'
  /// parent (which is the captured source cwd) against the live
  /// `currentURL`. The directory monitor on the original pane (if
  /// the user later navigates back) still picks the new entries up.
  func finishCopyBatch(targets: [URL]) {
    guard let parent = targets.first?.deletingLastPathComponent(),
      parent == currentURL
    else { return }
    reloadItems(preservingSelection: false, selectAfterLoad: targets)
  }

  /// Resolve the next free `<stem> copy[.ext]` slot inside `dir`,
  /// escalating to `<stem> copy 2.ext`, `<stem> copy 3.ext`, … on
  /// collision. Shared by Duplicate (which always collides) and
  /// Paste (which falls through here only when its preferred
  /// `<source-name>` target is taken). `URL.pathExtension` returns
  /// `""` for dotfiles like `.zshrc` (Foundation treats the leading
  /// dot as the stem), so the extensionless branch handles both
  /// extensionless and dotfile inputs without a separate guard.
  func availableCopyURL(in dir: URL, stem: String, ext: String) -> URL {
    let fm = FileManager.default

    func candidate(_ baseStem: String) -> URL {
      ext.isEmpty
        ? dir.appendingPathComponent(baseStem)
        : dir.appendingPathComponent("\(baseStem).\(ext)")
    }

    var url = candidate("\(stem) copy")
    if !fm.fileExists(atPath: url.path(percentEncoded: false)) { return url }
    var n = 2
    while true {
      url = candidate("\(stem) copy \(n)")
      if !fm.fileExists(atPath: url.path(percentEncoded: false)) { return url }
      n += 1
    }
  }

  /// Resolve the next free `<stem> N.ext` slot inside `dir`,
  /// starting at `N = 2` and escalating. Used by the drop-conflict
  /// "Keep Both" path so a same-name drop renames to `README 2.md`,
  /// matching Finder. The `copy` suffix from `availableCopyURL` is
  /// reserved for ⌘D Duplicate, where the verb makes the suffix
  /// natural; cross-directory drops have no such verb context and
  /// the numeric form is what Finder uses there.
  /// `reserved` holds slots already handed out earlier in the same batch
  /// but not yet written to disk — a drop resolves every Keep Both target
  /// up front (before any move lands), so without it two same-named
  /// sources would both probe a clean disk and claim the same `… 2` slot.
  func availableNumberedURL(
    in dir: URL, stem: String, ext: String, reserved: Set<URL> = []
  ) -> URL {
    let fm = FileManager.default

    func candidate(_ index: Int) -> URL {
      let suffixed = "\(stem) \(index)"
      return ext.isEmpty
        ? dir.appendingPathComponent(suffixed)
        : dir.appendingPathComponent("\(suffixed).\(ext)")
    }

    var n = 2
    while true {
      let url = candidate(n)
      if !reserved.contains(url),
        !fm.fileExists(atPath: url.path(percentEncoded: false))
      {
        return url
      }
      n += 1
    }
  }
}
