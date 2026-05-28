import Foundation
import Testing

@testable import E05Lib

@Suite("InputHistoryStore")
@MainActor
struct InputHistoryStoreTests {
  @Test("records an association and boosts it for the same input")
  func recordAndBoost() {
    let store = InputHistoryStore(inMemory: true)
    store.record(input: "kaw", url: "https://kawarimidoll.com")
    #expect(store.boosts(forQueryPrefix: "kaw")["https://kawarimidoll.com"] != nil)
  }

  @Test("exact input match outranks a prefix-only match")
  func exactBeatsPrefix() {
    let store = InputHistoryStore(inMemory: true)
    store.record(input: "kaw", url: "https://a.com")  // exact for query "kaw"
    store.record(input: "kawarimidoll", url: "https://b.com")  // prefix-only
    let boosts = store.boosts(forQueryPrefix: "kaw")
    #expect((boosts["https://a.com"] ?? 0) > (boosts["https://b.com"] ?? 0))
  }

  @Test("a short query surfaces a page learned under a longer input")
  func prefixSurfacesLongerInput() {
    let store = InputHistoryStore(inMemory: true)
    store.record(input: "kawarimidoll", url: "https://k.com")
    #expect(store.boosts(forQueryPrefix: "kaw")["https://k.com"] != nil)
  }

  @Test("repeated reinforcement raises the boost")
  func reinforcementGrows() {
    let store = InputHistoryStore(inMemory: true)
    store.record(input: "x", url: "https://x.com")
    let once = store.boosts(forQueryPrefix: "x")["https://x.com"] ?? 0
    store.record(input: "x", url: "https://x.com")
    store.record(input: "x", url: "https://x.com")
    let thrice = store.boosts(forQueryPrefix: "x")["https://x.com"] ?? 0
    #expect(thrice > once)
  }

  @Test("input matching is case- and whitespace-insensitive")
  func normalization() {
    let store = InputHistoryStore(inMemory: true)
    store.record(input: "  KAW ", url: "https://k.com")
    #expect(store.boosts(forQueryPrefix: "kaw")["https://k.com"] != nil)
  }

  @Test("decay shrinks counts and eventually prunes a one-off pick")
  func decayPrunes() {
    let store = InputHistoryStore(inMemory: true)
    store.record(input: "x", url: "https://x.com")  // use_count starts at 1.0
    // 1.0 * 0.975^N drops below 0.1 around N≈91; run well past that.
    for _ in 0..<200 { store.decay() }
    #expect(store.boosts(forQueryPrefix: "x").isEmpty)
  }

  @Test("an unrelated query returns no boosts")
  func unrelatedQuery() {
    let store = InputHistoryStore(inMemory: true)
    store.record(input: "github", url: "https://github.com")
    #expect(store.boosts(forQueryPrefix: "kaw").isEmpty)
  }

  @Test("empty input or query is a no-op")
  func emptyNoop() {
    let store = InputHistoryStore(inMemory: true)
    store.record(input: "  ", url: "https://x.com")
    store.record(input: "x", url: "")
    #expect(store.boosts(forQueryPrefix: "").isEmpty)
    #expect(store.boosts(forQueryPrefix: "x").isEmpty)
  }
}
