import AppKit

/// Workspace-header cell in the worklane outline view. Renders a 3pt
/// accent indicator (solid pill, or vertical dashed line for private
/// workspaces) plus the workspace title, with a hover-revealed × on
/// the trailing edge for close. Expand / collapse is driven by
/// AppKit's built-in disclosure triangle on the leading indent — the
/// cell itself doesn't paint a chevron.
///
/// Workspace switch is dispatched through the outline view's
/// selection model: when the user clicks the header, the row
/// becomes the table's selected row and the section view's
/// `selectionDidChange` calls `onWorkspaceClick(index:)`. Selection
/// is transient — the subsequent reload re-targets to the new
/// workspace's focused pane.
@MainActor
final class WorklaneWorkspaceCellView: NSTableCellView {
  static let height: CGFloat = 28

  private let indicator = WorkspaceAccentIndicator()
  private let label = NSTextField(labelWithString: "")
  private let closeButton: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.image = NSImage(
      systemSymbolName: "xmark", accessibilityDescription: "Close workspace")
    b.toolTip = "Close workspace"
    b.setRevealed(false)
    return b
  }()
  private let addButton: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.image = NSImage(
      systemSymbolName: "plus", accessibilityDescription: "New start pane in this workspace")
    b.toolTip = "New start pane in this workspace"
    b.setRevealed(false)
    return b
  }()
  /// Split-style chevron next to `+`. Click opens a menu of the other
  /// pane kinds (browser, terminal, finder) so the common start-page
  /// case stays a one-click affordance while the longer tail moves
  /// behind a hover-revealed dropdown rather than crowding the row.
  private let addMoreButton: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.image = NSImage(
      systemSymbolName: "chevron.down",
      accessibilityDescription: "New browser, terminal, or finder pane in this workspace")
    b.toolTip = "New browser, terminal, or finder pane in this workspace"
    b.setRevealed(false)
    return b
  }()

  private var trackingArea: NSTrackingArea?
  private var isHovered = false

  private weak var node: WorklaneWorkspaceNode?
  private var onCloseHandler: (() -> Void)?
  private var onAddStartHandler: (() -> Void)?
  private var onAddBrowserHandler: (() -> Void)?
  private var onAddTerminalHandler: (() -> Void)?
  private var onAddFinderHandler: (() -> Void)?
  /// Commit sink for an inline rename, captured in `configure` so it
  /// carries the workspace id without the cell having to re-resolve a
  /// (possibly recycled) `node` at end-of-edit.
  private var onRenameCommit: ((String) -> Void)?
  /// True while the label is acting as an editable name field. Guards
  /// `configure` from clobbering the in-progress text and makes
  /// `beginRename` idempotent.
  private var isRenaming = false

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  override func prepareForReuse() {
    super.prepareForReuse()
    // Drop any in-flight rename so a recycled cell never reappears in
    // edit mode against a different workspace.
    if isRenaming { endRenameMode() }
    // Hover state belongs to the previous row this cell represented.
    // Reset it before reconfigure so the close × button and hover
    // background don't bleed from one workspace header to another
    // when AppKit recycles the cell.
    setHovered(false)
  }

  private func setupLayout() {
    wantsLayer = true
    indicator.translatesAutoresizingMaskIntoConstraints = false

    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.drawsBackground = false

    closeButton.target = self
    closeButton.action = #selector(closeTapped(_:))
    addButton.target = self
    addButton.action = #selector(addTapped(_:))
    addMoreButton.target = self
    addMoreButton.action = #selector(addMoreTapped(_:))

    addSubview(indicator)
    addSubview(label)
    addSubview(addMoreButton)
    addSubview(addButton)
    addSubview(closeButton)

    NSLayoutConstraint.activate([
      indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      indicator.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      indicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      indicator.widthAnchor.constraint(equalToConstant: 3),

      label.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 8),
      label.trailingAnchor.constraint(
        lessThanOrEqualTo: addMoreButton.leadingAnchor, constant: -4),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),

      addMoreButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -2),
      addMoreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      addMoreButton.widthAnchor.constraint(equalToConstant: 14),
      addMoreButton.heightAnchor.constraint(equalToConstant: 18),

      addButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
      addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      addButton.widthAnchor.constraint(equalToConstant: 18),
      addButton.heightAnchor.constraint(equalToConstant: 18),

      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 18),
      closeButton.heightAnchor.constraint(equalToConstant: 18),
    ])
  }

  func configure(
    node: WorklaneWorkspaceNode,
    input: WorklaneSectionView.ReloadInput
  ) {
    self.node = node
    let title = node.model.displayName(at: node.index)
    let accent = input.accentColor(node.index)
    let isCurrent = node.index == input.focusedWorkspaceIndex
    // Leave the in-progress text alone if a worklane reload re-vends
    // this row while the user is mid-rename (e.g. an unrelated pane
    // title change fires `notifySidebarWorklaneDidChange`). The
    // commit/cancel path owns the label's string until editing ends.
    if !isRenaming { label.stringValue = title }
    label.font =
      isCurrent
      ? NSFont.boldSystemFont(ofSize: 13)
      : NSFont.systemFont(ofSize: 13)
    label.alphaValue = isCurrent ? 1.0 : 0.6
    indicator.color =
      isCurrent ? accent : accent.withAlphaComponent(0.6)
    indicator.isPrivate = node.model.isPrivate

    let workspaceIndex = node.index
    let workspaceId = node.id
    onRenameCommit = {
      [onRename = input.onRenameWorkspace] newName in onRename(workspaceId, newName)
    }
    onCloseHandler = {
      [onClose = input.onWorkspaceClose] in onClose(workspaceIndex)
    }
    onAddStartHandler = {
      [onAdd = input.onAddStartPaneToWorkspace] in onAdd(workspaceId)
    }
    onAddBrowserHandler = {
      [onAdd = input.onAddBrowserPaneToWorkspace] in onAdd(workspaceId)
    }
    onAddTerminalHandler = {
      [onAdd = input.onAddTerminalPaneToWorkspace] in onAdd(workspaceId)
    }
    onAddFinderHandler = {
      [onAdd = input.onAddFinderPaneToWorkspace] in onAdd(workspaceId)
    }
  }

  // MARK: - Inline rename

  /// Turn the title label into an editable name field seeded with the
  /// current custom name (empty for an unnamed workspace, with the
  /// "Workspace N" fallback shown as the placeholder). Idempotent —
  /// a second call while already editing is a no-op.
  func beginRename() {
    guard !isRenaming, let node else { return }
    isRenaming = true
    label.stringValue = node.model.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // Placeholder previews what an emptied field reverts to — the
    // unnamed fallback, which is "Private" for a private workspace and
    // the positional "Workspace N" otherwise (matches
    // `WorkspaceModel.displayName`), even when the workspace currently
    // has a name.
    label.placeholderString = node.model.isPrivate ? "Private" : "Workspace \(node.index + 1)"
    label.isEditable = true
    label.isSelectable = true
    label.isBezeled = true
    label.bezelStyle = .squareBezel
    label.drawsBackground = true
    label.alphaValue = 1.0
    label.delegate = self
    if let window, window.makeFirstResponder(label) {
      label.currentEditor()?.selectAll(nil)
    } else {
      // First-responder transition refused (cell not yet laid out or
      // another responder claimed the chain) — roll back so a stuck
      // `isRenaming` doesn't block the next attempt.
      endRenameMode()
    }
  }

  /// Restore the label to its non-editing presentation, re-seeding the
  /// text from the model's display name so a cancelled or emptied edit
  /// reverts to the fallback instead of a blank row.
  private func endRenameMode() {
    isRenaming = false
    label.isEditable = false
    label.isSelectable = false
    label.isBezeled = false
    label.drawsBackground = false
    label.delegate = nil
    if let node { label.stringValue = node.model.displayName(at: node.index) }
  }

  /// Walk up to the hosting outline view so first responder can be
  /// handed back to it after an edit ends.
  private var enclosingOutlineView: NSOutlineView? {
    var view: NSView? = superview
    while let current = view {
      if let outline = current as? NSOutlineView { return outline }
      view = current.superview
    }
    return nil
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let old = trackingArea { removeTrackingArea(old) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with _: NSEvent) {
    setHovered(true)
  }

  override func mouseExited(with _: NSEvent) {
    if cursorIsStillInsideBounds() { return }
    setHovered(false)
  }

  private func setHovered(_ hovered: Bool) {
    guard hovered != isHovered else { return }
    isHovered = hovered
    closeButton.setRevealed(hovered)
    addButton.setRevealed(hovered)
    addMoreButton.setRevealed(hovered)
    layer?.backgroundColor =
      hovered ? AppColors.hoverOverlay.cgColor : nil
    layer?.cornerRadius = hovered ? 4 : 0
  }

  @objc private func closeTapped(_: NSButton) {
    onCloseHandler?()
  }

  @objc private func addTapped(_: NSButton) {
    onAddStartHandler?()
  }

  @objc private func addMoreTapped(_ sender: NSButton) {
    let menu = NSMenu()
    let browser = NSMenuItem(
      title: "New Browser Pane",
      action: #selector(addBrowserSelected),
      keyEquivalent: "")
    browser.target = self
    menu.addItem(browser)
    let terminal = NSMenuItem(
      title: "New Terminal Pane",
      action: #selector(addTerminalSelected),
      keyEquivalent: "")
    terminal.target = self
    menu.addItem(terminal)
    let finder = NSMenuItem(
      title: "New Finder Pane",
      action: #selector(addFinderSelected),
      keyEquivalent: "")
    finder.target = self
    menu.addItem(finder)
    // Drop the menu directly below the chevron so its top edge
    // hugs the button's bottom — matches the sidebar header
    // dropdown idiom.
    let origin = NSPoint(x: 0, y: sender.bounds.height)
    menu.popUp(positioning: nil, at: origin, in: sender)
  }

  @objc private func addBrowserSelected() { onAddBrowserHandler?() }
  @objc private func addTerminalSelected() { onAddTerminalHandler?() }
  @objc private func addFinderSelected() { onAddFinderHandler?() }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}

extension WorklaneWorkspaceCellView: NSTextFieldDelegate {
  /// Intercept ESC: AppKit's default cancel can tear the field editor
  /// down without firing `controlTextDidEndEditing`, which would leave
  /// `isRenaming` stuck. Handle it explicitly — discard the edit and
  /// hand first responder back to the outline view.
  func control(
    _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
  ) -> Bool {
    guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
    endRenameMode()
    if let outline = enclosingOutlineView { window?.makeFirstResponder(outline) }
    return true
  }

  /// Commit path (Return / focus loss). The ESC cancel is routed
  /// through `control(_:textView:doCommandBy:)` and never reaches
  /// here, so this only handles commits. Reads the value, exits edit
  /// mode, then hands the trimmed name to the captured commit sink —
  /// the container normalises empty to "unnamed" and reloads the
  /// worklane, which re-vends this row with the resolved display name.
  func controlTextDidEndEditing(_ notification: Notification) {
    guard isRenaming else { return }
    let newName = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let commit = onRenameCommit
    endRenameMode()
    // Unlike the ESC path, no explicit first-responder hand-back: a
    // Return / focus-loss end-edit already moves it (focus loss to the
    // new responder, Return back to the outline view), and the commit
    // triggers a worklane reload that re-vends this row regardless.
    commit?(newName)
  }
}
