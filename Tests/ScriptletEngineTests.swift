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

  @Test("builtin rules only invoke implemented scriptlets with args")
  func builtinRulesShape() {
    // Names must match the registry keys in scriptlets.js; a typo in
    // a seed rule would otherwise be silently skipped at runtime.
    let implemented: Set<String> = ["set-constant", "set", "json-prune"]
    #expect(!ScriptletEngine.builtinRules.isEmpty)
    for (host, invocations) in ScriptletEngine.builtinRules {
      #expect(!host.isEmpty)
      #expect(!invocations.isEmpty)
      for invocation in invocations {
        #expect(implemented.contains(invocation.first ?? ""))
        #expect(invocation.count >= 2)
      }
    }
  }
}
