import AppKit
import SwiftUI

/// Native `NSSearchField` wrapper for the Settings sidebar search box.
///
/// SwiftUI's `.searchable` modifier needs a `NavigationStack` /
/// `NavigationSplitView` host to render, and the Settings window
/// deliberately uses a hand-built `HStack + Divider` layout (see
/// ``SettingsRootView``). Wrapping `NSSearchField` keeps the native
/// magnifier glyph, clear button, placeholder, and focus ring without
/// reintroducing a navigation container.
struct SettingsSearchField: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = placeholder
    field.delegate = context.coordinator
    // Report every keystroke (and the clear button) so the result
    // list updates live rather than only on Return.
    field.sendsWholeSearchString = false
    field.sendsSearchStringImmediately = true
    field.focusRingType = .default
    return field
  }

  func updateNSView(_ nsView: NSSearchField, context: Context) {
    // Repoint the coordinator at the current binding so the field
    // keeps writing through even if SwiftUI hands us a fresh one.
    context.coordinator.text = $text
    // Reflect external resets (selecting a result clears the query)
    // without clobbering the field mid-edit.
    if nsView.stringValue != text {
      nsView.stringValue = text
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var text: Binding<String>

    init(text: Binding<String>) {
      self.text = text
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      text.wrappedValue = field.stringValue
    }
  }
}
