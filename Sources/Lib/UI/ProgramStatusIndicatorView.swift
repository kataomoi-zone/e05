import AppKit

/// What a pane's program last reported needing (OSC 7501): blocked on
/// the user, failed, or finished and not yet seen. Working shows as the
/// pane's loading ring instead, and idle as nothing. Shown on the pane's
/// worklane row and, for the most urgent of their panes, on its column's
/// and workspace's rows, so a collapsed one still says something waits.
///
/// Informational, so an image rather than a button: clicking the row
/// already brings the pane up. Its words go in the row's own tooltip,
/// which covers the whole row and would shadow one here.
@MainActor
final class ProgramStatusIndicatorView: NSImageView {
  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    isHidden = true
    // The same fixed footprint as the sidebar's icon buttons beside it.
    // An image view's intrinsic size gives way before a title's, so a
    // long title would squeeze it to a speck.
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 18),
      heightAnchor.constraint(equalToConstant: 18),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  func apply(_ report: ProgramStatusReport?) {
    guard let report, let look = Self.look(report) else {
      isHidden = true
      return
    }
    // Monochrome and tinted: a palette colour would fill the glyph cut
    // out of a `.circle.fill` symbol along with the circle.
    image = NSImage(systemSymbolName: look.symbol, accessibilityDescription: look.label)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
    contentTintColor = look.color
    isHidden = false
  }

  /// One line for a row's tooltip: who reported, and why in its own
  /// words where it gave any.
  static func line(_ report: ProgramStatusReport) -> String? {
    guard let label = report.state == .working ? "Working" : look(report)?.label
    else { return nil }
    let detail = report.message ?? report.title
    return [report.app, label, detail].compactMap { $0 }.joined(separator: " — ")
  }

  private static func look(
    _ report: ProgramStatusReport
  ) -> (symbol: String, color: NSColor, label: String)? {
    switch report.state {
    case .blocked:
      switch report.kind {
      case .permission: ("hand.raised.fill", .systemOrange, "Waiting for permission")
      case .question: ("questionmark.circle.fill", .systemOrange, "Waiting for an answer")
      case .auth: ("key.fill", .systemOrange, "Waiting to sign in")
      case nil: ("exclamationmark.circle.fill", .systemOrange, "Waiting for you")
      }
    case .error: ("xmark.octagon.fill", .systemRed, "Failed")
    case .done: ("checkmark.circle.fill", .systemGreen, "Done")
    case .idle, .working, .clear: nil
    }
  }
}
