import Testing

@testable import E05Lib

@Suite("FinderUndoCenter.partialFailureMessage")
struct FinderUndoCenterPartialFailureMessageTests {
  @Test("full failure prefixes the action name")
  func fullFailurePrefixesAction() {
    let message = FinderUndoCenter.partialFailureMessage(
      actionName: "Move", succeeded: 0, total: 3, verbPhrase: "moved")
    #expect(message == "Move: 3 of 3 items couldn't be moved")
  }

  @Test("a single full failure uses the singular item phrase")
  func singleFullFailure() {
    let message = FinderUndoCenter.partialFailureMessage(
      actionName: "Rename", succeeded: 0, total: 1, verbPhrase: "renamed")
    #expect(message == "Rename: 1 item couldn't be renamed")
  }

  @Test("partial failure omits the action prefix")
  func partialFailureNoPrefix() {
    // The companion success toast still names the action on a partial,
    // so the error line stays bare to avoid redundancy.
    let message = FinderUndoCenter.partialFailureMessage(
      actionName: "Move", succeeded: 2, total: 5, verbPhrase: "moved")
    #expect(message == "3 of 5 items couldn't be moved")
  }

  @Test("a partial failure with one casualty still uses the plural item phrase")
  func partialSingleFailurePlural() {
    // failed == 1 but total > 1, so the item phrase stays "1 of 2
    // items" — the singular "1 item" form is reserved for total == 1.
    let message = FinderUndoCenter.partialFailureMessage(
      actionName: "Move", succeeded: 1, total: 2, verbPhrase: "moved")
    #expect(message == "1 of 2 items couldn't be moved")
  }

  @Test("a nil action name never prefixes (live drop)")
  func nilActionNoPrefix() {
    #expect(
      FinderUndoCenter.partialFailureMessage(
        actionName: nil, succeeded: 0, total: 1, verbPhrase: "moved")
        == "1 item couldn't be moved")
    #expect(
      FinderUndoCenter.partialFailureMessage(
        actionName: nil, succeeded: 0, total: 3, verbPhrase: "copied")
        == "3 of 3 items couldn't be copied")
  }

  @Test("an empty action name is treated as no prefix")
  func emptyActionNoPrefix() {
    let message = FinderUndoCenter.partialFailureMessage(
      actionName: "", succeeded: 0, total: 2, verbPhrase: "moved")
    #expect(message == "2 of 2 items couldn't be moved")
  }
}
