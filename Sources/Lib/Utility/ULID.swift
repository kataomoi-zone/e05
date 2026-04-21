import Foundation

/// ULID (Universally Unique Lexicographically Sortable Identifier).
/// 128-bit: 48-bit timestamp (ms) + 80-bit random. Crockford Base32 encoded (26 chars).
public struct ULID: Equatable, Hashable, Comparable, CustomStringConvertible, Sendable {
  public let string: String

  public var description: String { string }

  public init() {
    let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
    self.string = Self.encode(timestamp: timestamp)
  }

  /// Create a ULID from a pre-encoded string. No validation — for internal/test use.
  public init(_ string: String) {
    self.string = string
  }

  public static func < (lhs: ULID, rhs: ULID) -> Bool {
    lhs.string < rhs.string
  }

  // MARK: - Encoding

  private static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

  private static func encode(timestamp: UInt64) -> String {
    var chars = [Character](repeating: "0", count: 26)

    // Timestamp: 10 chars (48-bit, big-endian Crockford Base32)
    var t = timestamp & 0xFFFF_FFFF_FFFF
    for i in stride(from: 9, through: 0, by: -1) {
      chars[i] = alphabet[Int(t & 0x1F)]
      t >>= 5
    }

    // Randomness: 16 chars (80-bit = two UInt64 halves)
    var random = [UInt8](repeating: 0, count: 10)
    let status = SecRandomCopyBytes(kSecRandomDefault, 10, &random)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
    // Split 80 bits into high 16 bits (2 bytes) and low 64 bits (8 bytes)
    let rHigh = UInt64(random[0]) << 8 | UInt64(random[1])
    var rLow = UInt64(0)
    for i in 2..<10 { rLow = (rLow << 8) | UInt64(random[i]) }

    // Encode low 64 bits → chars[13...25] (13 chars × 5 bits = 65 bits, top bit from high)
    var lo = rLow
    for i in stride(from: 25, through: 13, by: -1) {
      chars[i] = alphabet[Int(lo & 0x1F)]
      lo >>= 5
    }
    // Encode high 16 bits + overflow → chars[10...12] (3 chars)
    var hi = rHigh | (lo << 16)
    for i in stride(from: 12, through: 10, by: -1) {
      chars[i] = alphabet[Int(hi & 0x1F)]
      hi >>= 5
    }

    return String(chars)
  }
}
