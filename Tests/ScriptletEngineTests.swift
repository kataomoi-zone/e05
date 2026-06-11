import Foundation
import Testing

@testable import E05Lib

@Suite("ScriptletEngine")
@MainActor
struct ScriptletEngineTests {
  @Test("source bakes index and whitelist as consts plus the library")
  func sourceComposition() throws {
    let source = ScriptletEngine.makeSource(
      index: ["youtube.com": [["set-constant", "a.b", "undefined"]]],
      whitelist: ["allow.example"]
    )
    let src = try #require(source)
    #expect(src.contains("__E05_SCRIPTLET_INDEX__"))
    #expect(src.contains("__E05_SCRIPTLET_WHITELIST__"))
    #expect(src.contains(#""youtube.com""#))
    #expect(src.contains(#""allow.example""#))
    // The library body follows the baked consts in the same script.
    #expect(src.contains("json-prune"))
  }

  @Test("source is deterministic regardless of input ordering")
  func deterministicSource() {
    let a = ScriptletEngine.makeSource(
      index: ["b.example": [], "a.example": []],
      whitelist: ["z.example", "a.example"]
    )
    let b = ScriptletEngine.makeSource(
      index: ["a.example": [], "b.example": []],
      whitelist: ["a.example", "z.example"]
    )
    #expect(a != nil)
    #expect(a == b)
  }

  @Test("special characters in baked data stay JSON-escaped")
  func jsonEscaping() throws {
    let source = ScriptletEngine.makeSource(
      index: ["example.com": [["set-constant", "a\"b", "1"]]],
      whitelist: []
    )
    let src = try #require(source)
    #expect(src.contains(#"a\"b"#))
  }

  @Test("buildIndex keeps supported host-scoped scriptlets, drops the rest")
  func buildIndexFiltering() {
    let text = """
      ! comment
      youtube.com##+js(set, ytInitialPlayerResponse.adPlacements, undefined)
      a.com,b.com##+js(json-prune, adPlacements adSlots)
      example.com##+js(no-such-scriptlet, x)
      ##+js(set, generic.global, 1)
      cosmetic.example##.ad-banner
      ||network.example/ads^
      """
    let index = ScriptletEngine.buildIndex(from: [text])
    // Supported + host-scoped rules are kept, fanned out per domain.
    #expect(
      index["youtube.com"] == [["set", "ytInitialPlayerResponse.adPlacements", "undefined"]])
    #expect(index["a.com"] == [["json-prune", "adPlacements adSlots"]])
    #expect(index["b.com"] == [["json-prune", "adPlacements adSlots"]])
    // Unsupported scriptlet, host-less scriptlet, cosmetic and network
    // lines all leave no entry.
    #expect(index["example.com"] == nil)
    #expect(index.count == 3)
  }
}

@Suite("ScriptletParser")
struct ScriptletParserTests {
  @Test("host-scoped +js rule parses domains and invocation")
  func basic() {
    let p = ScriptletParser.parseLine("youtube.com##+js(set, a.b, undefined)")
    #expect(p?.domains == ["youtube.com"])
    #expect(p?.excludedDomains == [])
    #expect(p?.invocation == ["set", "a.b", "undefined"])
  }

  @Test("multiple domains and negation split into positive and excluded")
  func domainsAndNegation() {
    let p = ScriptletParser.parseLine("a.com,~b.a.com,c.com##+js(json-prune, x y)")
    #expect(p?.domains == ["a.com", "c.com"])
    #expect(p?.excludedDomains == ["b.a.com"])
    #expect(p?.invocation == ["json-prune", "x y"])
  }

  @Test("escaped comma stays inside one argument")
  func escapedComma() {
    let p = ScriptletParser.parseLine(#"e.com##+js(set, a, b\,c)"#)
    #expect(p?.invocation == ["set", "a", "b,c"])
  }

  @Test("a trailing backslash in the final argument is preserved")
  func trailingBackslash() {
    let p = ScriptletParser.parseLine(#"e.com##+js(set, a, b\)"#)
    #expect(p?.invocation == ["set", "a", #"b\"#])
  }

  @Test("scriptlet exception is dropped")
  func exception() {
    #expect(ScriptletParser.parseLine("e.com#@#+js(set, a, b)") == nil)
  }

  @Test("cosmetic, network, and comment lines are not scriptlets")
  func nonScriptlet() {
    #expect(ScriptletParser.parseLine("e.com##.ad") == nil)
    #expect(ScriptletParser.parseLine("||e.com/ads^") == nil)
    #expect(ScriptletParser.parseLine("! comment") == nil)
  }
}
