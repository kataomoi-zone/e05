import Foundation
import Testing

@testable import E05Lib

@Suite("Frecency")
struct FrecencyTests {
  @Test("typed visits outweigh the same number of link visits")
  func typedDominates() {
    let now = Date()
    let typed = Frecency.score(visits: 3, typedVisits: 3, lastVisit: now, now: now)
    let linked = Frecency.score(visits: 3, typedVisits: 0, lastVisit: now, now: now)
    #expect(typed > linked)
  }

  @Test("a single typed visit beats many link visits")
  func typedBeatsManyLinks() {
    let now = Date()
    let oneTyped = Frecency.score(visits: 1, typedVisits: 1, lastVisit: now, now: now)
    let manyLinks = Frecency.score(visits: 10, typedVisits: 0, lastVisit: now, now: now)
    #expect(oneTyped > manyLinks)
  }

  @Test("recent visits score higher than stale ones")
  func recencyDecay() {
    let now = Date()
    let recent = Frecency.score(visits: 5, typedVisits: 2, lastVisit: now, now: now)
    let stale = Frecency.score(
      visits: 5, typedVisits: 2, lastVisit: now.addingTimeInterval(-100 * 86_400), now: now)
    #expect(recent > stale)
  }

  @Test("no visits scores zero")
  func zeroVisits() {
    #expect(Frecency.score(visits: 0, typedVisits: 0, lastVisit: Date(), now: Date()) == 0)
  }

  @Test("typedVisits is clamped to total visits")
  func clampTyped() {
    let now = Date()
    let inflated = Frecency.score(visits: 2, typedVisits: 5, lastVisit: now, now: now)
    let allTyped = Frecency.score(visits: 2, typedVisits: 2, lastVisit: now, now: now)
    #expect(inflated == allTyped)
  }
}
