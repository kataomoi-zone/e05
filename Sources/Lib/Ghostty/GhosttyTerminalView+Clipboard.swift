import AppKit

/// A clipboard confirmation on screen, and the answer it is waiting to
/// hand back to libghostty.
struct PendingClipboardConfirmation {
  let alert: NSAlert
  let decide: (_ allowed: Bool, _ remember: Bool) -> Void
}

extension GhosttyTerminalView {
  /// Ask the user about a clipboard request from this pane, as a sheet
  /// on the window. `decide` runs exactly once: with the answer, or with
  /// a denial if the pane leaves the window first.
  ///
  /// One prompt per window. A request that arrives while a sheet is up
  /// is denied rather than queued: focusing its pane would put the pane
  /// beside a sheet that asks about another one, and a program could
  /// otherwise stack prompts behind the one the user is reading.
  func askClipboardConfirmation(
    _ confirmation: ClipboardConfirmation,
    decide: @escaping (_ allowed: Bool, _ remember: Bool) -> Void
  ) {
    guard let window, window.attachedSheet == nil else {
      decide(false, false)
      return
    }
    // Bring the pane that asked into view, so the sheet is not a
    // question about a pane the user cannot see.
    onClipboardConfirmationNeeded?()

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = confirmation.messageText
    alert.informativeText = confirmation.informativeText
    alert.accessoryView = Self.clipboardPreview(confirmation.preview)
    if confirmation.canRemember {
      alert.showsSuppressionButton = true
      // Only an approval can be kept: libghostty's denial takes no
      // remember flag.
      alert.suppressionButton?.title = "Allow without asking again this session"
    }
    // NSAlert binds Return to the first button and Escape to one titled
    // "Cancel". A program's prompt leads with Deny and moves it to
    // Escape, which leaves Return answering nothing.
    let confirmFirst = confirmation.returnConfirms
    let titles =
      confirmFirst
      ? [confirmation.confirmTitle, confirmation.cancelTitle]
      : [confirmation.cancelTitle, confirmation.confirmTitle]
    for title in titles { alert.addButton(withTitle: title) }
    if !confirmFirst { alert.buttons[0].keyEquivalent = "\u{1b}" }

    pendingClipboardConfirmation = PendingClipboardConfirmation(alert: alert, decide: decide)
    alert.beginSheetModal(for: window) { [weak self] response in
      let allowed = (response == .alertFirstButtonReturn) == confirmFirst
      let remember = allowed && alert.suppressionButton?.state == .on
      self?.finishClipboardConfirmation(allowed: allowed, remember: remember)
    }
  }

  /// Deny the open prompt, if any, and take it off the window. For a
  /// pane leaving the window or its surface going away: the request
  /// must still be answered, or libghostty keeps it, and the program
  /// that asked keeps waiting.
  func cancelClipboardConfirmation() {
    guard let pending = pendingClipboardConfirmation else { return }
    finishClipboardConfirmation(allowed: false, remember: false)
    // Its parent rather than `window`, which is already nil when the
    // pane has just been taken out of it.
    pending.alert.window.sheetParent?.endSheet(pending.alert.window)
  }

  private func finishClipboardConfirmation(allowed: Bool, remember: Bool) {
    guard let pending = pendingClipboardConfirmation else { return }
    pendingClipboardConfirmation = nil
    pending.decide(allowed, remember)
  }

  /// The contents under review, read-only and scrollable: a paste or a
  /// clipboard can be far longer than an alert's own text fits.
  private static func clipboardPreview(_ text: String) -> NSView {
    let scroll = NSTextView.scrollableTextView()
    scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 160)
    scroll.hasHorizontalScroller = false
    scroll.borderType = .bezelBorder
    if let textView = scroll.documentView as? NSTextView {
      textView.isEditable = false
      // Not selectable either, so it cannot take first responder: a text
      // view that has it swallows Return, and Paste stops being the
      // button Return presses.
      textView.isSelectable = false
      textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
      textView.string = text
    }
    return scroll
  }
}
