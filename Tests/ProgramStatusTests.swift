import Foundation
import Testing

@testable import E05Lib

@Suite("ProgramStatus")
struct ProgramStatusTests {
  private func report(_ body: String) -> ProgramStatusReport {
    ProgramStatusReport(body: body)!
  }

  private func records(_ bodies: String...) -> ProgramStatusRecords {
    var r = ProgramStatusRecords()
    for body in bodies { r.apply(report(body)) }
    return r
  }

  @Test("a report reads its keys, decoding title and msg from base64")
  func readsKeys() {
    let msg = Data("Apply 3 changes?".utf8).base64EncodedString()
    let r = report("state=blocked:kind=permission:app=terraform:id=a/b:msg=\(msg)")
    #expect(r.state == .blocked)
    #expect(r.kind == .permission)
    #expect(r.app == "terraform")
    #expect(r.id == "a/b")
    #expect(r.message == "Apply 3 changes?")
  }

  @Test("kind only counts for a blocked program")
  func kindNeedsBlocked() {
    #expect(report("state=done:kind=permission").kind == nil)
  }

  @Test("the last of a repeated key wins")
  func lastValueWins() {
    #expect(report("state=idle:state=working").state == .working)
  }

  @Test("title and msg decode with or without base64 padding")
  func optionalPadding() {
    #expect(report("state=done:msg=QXBwbHk").message == "Apply")
    #expect(report("state=done:msg=QXBwbHk=").message == "Apply")
  }

  @Test("an idle report drops its record rather than keeping it")
  func idleIsNotKept() {
    let r = records("state=working:id=x", "state=idle:id=x", "state=idle:id=y")
    #expect(r.records.isEmpty)
  }

  @Test("a report with no known state is not one")
  func unknownState() {
    #expect(ProgramStatusReport(body: "state=sleeping") == nil)
    #expect(ProgramStatusReport(body: "app=x") == nil)
  }

  @Test("a report replaces its id's record whole")
  func replaces() {
    let r = records("state=working:id=x:app=a", "state=done:id=x")
    #expect(r.records["x"]?.state == .done)
    #expect(r.records["x"]?.app == nil)
  }

  @Test("clear removes the id and everything beneath it, but not a sibling prefix")
  func clearSubtree() {
    var r = records(
      "state=working:id=deploy", "state=working:id=deploy/us", "state=blocked:id=deployer")
    r.apply(report("state=clear:id=deploy"))
    #expect(Set(r.records.keys) == ["deployer"])
  }

  @Test("clear without an id removes every record")
  func clearAll() {
    var r = records("state=working", "state=blocked:id=x")
    r.apply(report("state=clear"))
    #expect(r.records.isEmpty)
  }

  @Test("a finished command drops working and blocked, keeps done and error")
  func commandFinished() {
    var r = records(
      "state=working:id=a", "state=blocked:id=b", "state=done:id=c", "state=error:id=d")
    r.commandFinished()
    #expect(Set(r.records.keys) == ["c", "d"])
  }

  @Test("seeing the pane drops done and error")
  func seen() {
    var r = records("state=working:id=a", "state=done:id=c", "state=error:id=d")
    r.seen()
    #expect(Set(r.records.keys) == ["a"])
  }

  @Test("across panes, working gives way to a finished or failed pane beside it")
  func mostShownSkipsWorking() {
    let working = report("state=working")
    let done = report("state=done")
    #expect(ProgramStatusRecords.mostShown([working, done, nil]) == done)
    #expect(ProgramStatusRecords.mostShown([working, nil]) == nil)
  }

  @Test("the summary is the record most in need of the user")
  func summary() {
    #expect(
      records("state=done:id=a", "state=blocked:id=b", "state=working:id=c").summary?.id == "b")
    #expect(records("state=done:id=a", "state=error:id=b").summary?.state == .error)
    #expect(records("state=working:id=x", "state=working").summary?.id == "")
  }
}
