import Foundation

/// Chrome Web Store distributes extensions in CRX format — the inner
/// ZIP archive that `WKWebExtension(resourceBaseURL:)` understands,
/// prefixed with a signature header. This helper strips that header
/// so the rest of the pipeline can treat the result like any other
/// `.zip` extension source.
///
/// CRX layout (current spec):
///
///     bytes 0..4   magic = "Cr24"
///     bytes 4..8   version (uint32 LE)
///     for version 2 (legacy, pre-Chrome 64):
///       bytes 8..12   public_key_length (uint32 LE)
///       bytes 12..16  signature_length (uint32 LE)
///       16..(16+pkLen+sigLen)   public key + signature
///       remainder    ZIP archive
///     for version 3 (current):
///       bytes 8..12   header_size (uint32 LE)
///       12..(12+headerSize)   CrxFileHeader protobuf (we don't parse it)
///       remainder    ZIP archive
enum CRXArchive {
  enum CRXError: LocalizedError {
    case truncated
    case invalidMagic
    case unsupportedVersion(UInt32)

    var errorDescription: String? {
      switch self {
      case .truncated:
        return "The downloaded archive is too small to be a valid CRX file."
      case .invalidMagic:
        return "The downloaded archive is not a valid CRX file (magic bytes mismatch)."
      case .unsupportedVersion(let v):
        return "Unsupported CRX format version \(v) — only CRX2 and CRX3 are recognised."
      }
    }
  }

  /// Strip the CRX header from `data` and return the inner ZIP archive
  /// suitable for `WKWebExtension(resourceBaseURL:)`.
  static func extractZIP(from data: Data) throws -> Data {
    guard data.count >= 16 else { throw CRXError.truncated }

    let expectedMagic: [UInt8] = [0x43, 0x72, 0x32, 0x34]  // "Cr24"
    guard Array(data[data.startIndex..<data.startIndex + 4]) == expectedMagic else {
      throw CRXError.invalidMagic
    }

    let version = readLEUInt32(data, offset: 4)
    switch version {
    case 2:
      let pubKeyLen = Int(readLEUInt32(data, offset: 8))
      let sigLen = Int(readLEUInt32(data, offset: 12))
      let zipStart = 16 + pubKeyLen + sigLen
      guard data.count > zipStart else { throw CRXError.truncated }
      return data.subdata(in: zipStart..<data.count)
    case 3:
      let headerSize = Int(readLEUInt32(data, offset: 8))
      let zipStart = 12 + headerSize
      guard data.count > zipStart else { throw CRXError.truncated }
      return data.subdata(in: zipStart..<data.count)
    default:
      throw CRXError.unsupportedVersion(version)
    }
  }

  private static func readLEUInt32(_ data: Data, offset: Int) -> UInt32 {
    let start = data.startIndex + offset
    let slice = data[start..<(start + 4)]
    var value: UInt32 = 0
    withUnsafeMutableBytes(of: &value) { buf in
      slice.copyBytes(to: buf, count: 4)
    }
    return UInt32(littleEndian: value)
  }
}
