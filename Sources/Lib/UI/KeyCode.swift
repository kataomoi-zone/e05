import AppKit

/// macOS virtual key codes used across e05 for keyboard event dispatch.
///
/// `NSEvent.keyCode` returns a layout-independent virtual key code
/// derived from the physical position of the key — switching to JIS or
/// Dvorak doesn't change it. The values are documented in
/// `<HIToolbox/Events.h>` (kVK_ANSI_*) but AppKit doesn't re-export
/// them, so the literals had drifted into call sites as bare hex
/// numbers with `// Return` comments. Naming them here keeps the
/// dispatch tables readable.
///
/// Third-party remappers (Karabiner-Elements and the like) can
/// override the physical-to-virtual mapping; those setups are
/// unverified.
public enum KeyCode {
  public static let returnKey: UInt16 = 0x24
  public static let tab: UInt16 = 0x30
  public static let space: UInt16 = 0x31
  /// Backspace / Delete (the key labelled "delete" on most layouts).
  public static let delete: UInt16 = 0x33
  public static let numpadEnter: UInt16 = 0x4C
  public static let leftArrow: UInt16 = 0x7B
  public static let rightArrow: UInt16 = 0x7C
}
