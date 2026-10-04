import Foundation
import Testing

@testable import E05Lib

@Suite("WorklanePaneCellView.toolTipText")
struct WorklanePaneToolTipTests {
  private func tip(_ title: String, _ address: PaneAddress) -> String {
    WorklanePaneCellView.toolTipText(title: title, address: address)
  }

  @Test("a page: the title, then its URL")
  func page() {
    let address = PaneAddress(URL(string: "https://github.com/kawarimidoll/e05")!)
    #expect(tip("e05", address) == "e05\nhttps://github.com/kawarimidoll/e05")
  }

  @Test("a local file reads as a path, not a percent-encoded URL")
  func localFile() {
    let address = PaneAddress(URL(string: "file:///Users/me/%E3%83%A1%E3%83%A2.md")!)
    #expect(tip("メモ", address) == "メモ\n/Users/me/メモ.md")
  }

  @Test("a title that already is the location is not repeated")
  func titleIsTheLocation() {
    #expect(tip("about:blank", PaneAddress(URL(string: "about:blank")!)) == "about:blank")
  }

  @Test("a folder: the title, then its path")
  func folder() {
    #expect(tip("dotfiles", .finder(path: "/Users/me/dotfiles")) == "dotfiles\n/Users/me/dotfiles")
  }

  @Test("a bare finder address and a terminal show the title alone")
  func titleAlone() {
    #expect(tip("~", .finder(path: "")) == "~")
    #expect(tip("zsh", .terminal) == "zsh")
  }

  @Test("a path that does not decode is left out")
  func undecodablePath() {
    let address = PaneAddress(URL(string: "file:///tmp/%FF%FE.txt")!)
    #expect(tip("notes", address) == "notes")
  }

  @Test("an address of no known kind shows as it is")
  func unknownKind() {
    let address = PaneAddress(URL(string: "e05://history")!)
    #expect(tip("(unknown)", address) == "(unknown)\ne05://history")
  }
}
