import AppKit
import Testing

@testable import E05Lib

@Suite("Permission prompt response")
@MainActor
struct PermissionPromptResponseTests {
  @Test("the two buttons are the only answers")
  func buttons() {
    #expect(BrowserPaneView.permissionChoice(for: .alertFirstButtonReturn) == .grant)
    #expect(BrowserPaneView.permissionChoice(for: .alertSecondButtonReturn) == .deny)
  }

  @Test("a sheet ended in code is not an answer")
  func endedInCode() {
    #expect(BrowserPaneView.permissionChoice(for: .cancel) == nil)
    #expect(BrowserPaneView.permissionChoice(for: .abort) == nil)
  }
}
