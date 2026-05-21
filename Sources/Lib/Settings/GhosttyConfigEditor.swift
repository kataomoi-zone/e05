import AppKit
import SwiftUI

/// Syntax-highlighting text editor for `config.ghostty`. SwiftUI's
/// `TextEditor` only accepts a `String` binding, so the highlighting
/// is delivered by wrapping `NSTextView` directly. Highlighting is a
/// presentation concern: parser / catalog diagnostics still flow
/// through the panel below the editor.
///
/// Tokens recognised:
/// - **Comment**: a line whose first non-whitespace character is `#`.
///   The whole line is dimmed.
/// - **Key**: the identifier before the first `=` on a non-comment
///   line. Coloured with the system accent.
/// - **`=`**: rendered in the secondary label colour so the equals
///   visually separates key and value without competing with either.
///
/// Inline `#...` is intentionally NOT treated as a comment because
/// hex color literals (`background = #1e1e1e`) are common in ghostty
/// configs and would otherwise be miscoloured.
@MainActor
struct GhosttyConfigEditor: NSViewRepresentable {
  @Binding var text: String

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = false
    scrollView.borderType = .noBorder

    guard let textView = scrollView.documentView as? NSTextView else {
      return scrollView
    }
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.smartInsertDeleteEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.allowsUndo = true
    textView.usesAdaptiveColorMappingForDarkAppearance = true
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.delegate = context.coordinator
    textView.string = text
    Coordinator.applyHighlighting(to: textView)
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let textView = nsView.documentView as? NSTextView else { return }
    // Bridge external state changes (Reload from Disk, Reset, Save
    // normalisation, etc.) back into the text view. Skipped when the
    // strings already match — that branch covers the steady-state
    // typing loop where the binding mirrors the text view value, and
    // reassigning would collapse the user's cursor to the start of
    // the document. When the strings differ, preserve `selectedRanges`
    // across the assign so a Save that appends a trailing newline (or
    // any future normalisation) leaves the cursor where the user left
    // it instead of snapping to position 0.
    if textView.string != text {
      let preservedRanges = textView.selectedRanges
      textView.string = text
      textView.selectedRanges = preservedRanges
      Coordinator.applyHighlighting(to: textView)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(binding: $text)
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    /// Captured once per `makeCoordinator()` call. Safe as long as
    /// the host `TerminalSettingsView` keeps its `@State` storage
    /// across the editor's lifetime — Settings tabs are recreated
    /// from scratch on switch, so each mount gets a fresh coordinator
    /// paired with the live state. If a future caller starts
    /// rebuilding the editor in place under a different state slot,
    /// the coordinator must be rebuilt as well or writes will land
    /// in a dead `Binding`.
    let binding: Binding<String>

    init(binding: Binding<String>) {
      self.binding = binding
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      binding.wrappedValue = textView.string
      Self.applyHighlighting(to: textView)
    }

    /// Re-apply foreground colours across the full text storage. The
    /// rule set is small enough that a full re-scan on every keystroke
    /// is cheap; a future profile pass can introduce a per-line dirty
    /// range if a long config (thousands of lines) starts to drag.
    static func applyHighlighting(to textView: NSTextView) {
      guard let storage = textView.textStorage else { return }
      let nsText = textView.string as NSString
      let full = NSRange(location: 0, length: storage.length)
      let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

      storage.beginEditing()
      storage.addAttribute(.font, value: monoFont, range: full)
      storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)

      var cursor = 0
      while cursor < nsText.length {
        let lineRange = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        applyLine(text: nsText, range: lineRange, storage: storage)
        cursor = NSMaxRange(lineRange)
      }

      storage.endEditing()
    }

    private static func applyLine(
      text: NSString,
      range: NSRange,
      storage: NSTextStorage
    ) {
      // Find the first non-whitespace character to classify the line.
      var i = range.location
      let end = NSMaxRange(range)
      while i < end {
        let c = text.character(at: i)
        if c != 0x20 && c != 0x09 { break }
        i += 1
      }
      guard i < end else { return }

      // Comment line: dim the entire line, including trailing newline.
      if text.character(at: i) == 0x23 {  // '#'
        storage.addAttribute(
          .foregroundColor,
          value: NSColor.secondaryLabelColor,
          range: range
        )
        return
      }

      // key = value: find the first '=' inside the line.
      var eqIndex: Int?
      var j = i
      while j < end {
        if text.character(at: j) == 0x3D {  // '='
          eqIndex = j
          break
        }
        j += 1
      }
      guard let eq = eqIndex else { return }

      // Trim trailing whitespace between key and '='.
      var keyEnd = eq
      while keyEnd > i {
        let prev = text.character(at: keyEnd - 1)
        if prev == 0x20 || prev == 0x09 {
          keyEnd -= 1
        } else {
          break
        }
      }
      let keyRange = NSRange(location: i, length: keyEnd - i)
      let eqRange = NSRange(location: eq, length: 1)

      // System accent (not `AccentPalettePreset`) on purpose: the
      // workspace accent identifies the focused workspace stripe,
      // which is unrelated to code-editor syntax colour. Following
      // the OS accent matches the convention every other macOS
      // text editor honours.
      storage.addAttribute(
        .foregroundColor,
        value: NSColor.controlAccentColor,
        range: keyRange
      )
      storage.addAttribute(
        .foregroundColor,
        value: NSColor.secondaryLabelColor,
        range: eqRange
      )
    }
  }
}
