import AppKit

/// Visual layer for keyboard link hints: a dim wash plus a lettered badge
/// at each linkable token. Input is handled by `GhosttyTerminalView` (it
/// keeps first responder), so the overlay is hit-transparent.
final class TerminalHintsOverlayView: NSView {
  let hints: [TerminalHint]
  private let cellHeight: CGFloat

  init(frame: NSRect, hints: [TerminalHint], cellHeight: CGFloat) {
    self.hints = hints
    self.cellHeight = cellHeight
    super.init(frame: frame)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  override func hitTest(_: NSPoint) -> NSView? { nil }

  override func draw(_: NSRect) {
    AppColors.hintDim.setFill()
    bounds.fill()

    let font = NSFont.monospacedSystemFont(ofSize: max(10, cellHeight * 0.62), weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: AppColors.hintBadgeText,
    ]
    let pad: CGFloat = 3
    for hint in hints {
      let label = NSAttributedString(string: hint.label, attributes: attributes)
      let textSize = label.size()
      // Anchor the badge at the matched text's top-left corner.
      let badge = NSRect(
        x: hint.rect.minX,
        y: hint.rect.maxY - (textSize.height + pad),
        width: textSize.width + pad * 2,
        height: textSize.height + pad)
      AppColors.hintBadge.setFill()
      NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
      label.draw(at: NSPoint(x: badge.minX + pad, y: badge.minY + pad / 2))
    }
  }
}

extension GhosttyTerminalView {
  /// Label every URL / path / hash in the viewport with a letter. No-op if
  /// hints are already up, there's no grid, or nothing is linkable.
  func showLinkHints() {
    guard hintsOverlay == nil, let metrics = gridMetrics(),
      let joined = readViewportText(
        rows: Int(metrics.size.rows), columns: Int(metrics.size.columns))
    else { return }
    let hints = TerminalHintPlanner.plan(
      joined: joined, columns: Int(metrics.size.columns),
      cellWidth: metrics.cellWidth, cellHeight: metrics.cellHeight, viewHeight: bounds.height)
    guard !hints.isEmpty else { return }

    let overlay = TerminalHintsOverlayView(
      frame: bounds, hints: hints, cellHeight: metrics.cellHeight)
    overlay.autoresizingMask = [.width, .height]
    addSubview(overlay)
    hintsOverlay = overlay
  }

  func dismissLinkHints() {
    hintsOverlay?.removeFromSuperview()
    hintsOverlay = nil
  }

  /// A keystroke while hints are up: Esc cancels, a labeled letter acts on
  /// its hint (Shift opens, plain copies), anything else cancels. The
  /// overlay is always torn down afterward.
  func handleHintKey(_ event: NSEvent) {
    defer { dismissLinkHints() }
    guard event.keyCode != 0x35,  // Esc
      let overlay = hintsOverlay,
      let typed = event.charactersIgnoringModifiers?.lowercased(), typed.count == 1,
      let hint = overlay.hints.first(where: { $0.label == typed })
    else { return }
    act(on: hint, open: event.modifierFlags.contains(.shift))
  }

  private func act(on hint: TerminalHint, open: Bool) {
    guard open else {
      copyToPasteboard(hint.text)
      return
    }
    switch hint.kind {
    case .url:
      if let url = URL(string: hint.text) { onOpenURL?(url) }
    case .path:
      // Only an absolute or home path resolves unambiguously; a relative
      // one would resolve against e05's process cwd, not the shell's, and
      // open the wrong place — copy it instead.
      if hint.text.hasPrefix("/") || hint.text.hasPrefix("~") {
        onOpenURL?(URL(fileURLWithPath: (hint.text as NSString).expandingTildeInPath))
      } else {
        copyToPasteboard(hint.text)
      }
    case .hash:
      copyToPasteboard(hint.text)  // a hash has nothing to open
    }
  }

  private func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }
}
