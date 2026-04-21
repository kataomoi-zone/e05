import Foundation
import Testing

@testable import E05Lib

@Suite("ULID")
struct ULIDTests {
  @Test("generates 26-character string")
  func length() {
    let id = ULID()
    #expect(id.string.count == 26)
  }

  @Test("uses only Crockford Base32 characters")
  func charset() {
    let valid = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    let id = ULID()
    for ch in id.string {
      #expect(valid.contains(ch), "Unexpected character: \(ch)")
    }
  }

  @Test("generates unique values")
  func uniqueness() {
    let ids = (0..<100).map { _ in ULID() }
    let unique = Set(ids.map(\.string))
    #expect(unique.count == 100)
  }

  @Test("is lexicographically sortable by time")
  func sortable() throws {
    let id1 = ULID()
    // Small delay to ensure different timestamp
    Thread.sleep(forTimeInterval: 0.01)
    let id2 = ULID()
    #expect(id1 < id2)
  }

  @Test("comparable via string")
  func comparable() {
    let a = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAV")
    let b = ULID("01ARZ3NDEKTSV4RRFFQ69G5FAW")
    #expect(a < b)
  }

  @Test("equality")
  func equality() {
    let s = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    #expect(ULID(s) == ULID(s))
  }

  @Test("description matches string")
  func description() {
    let id = ULID()
    #expect(id.description == id.string)
  }
}
