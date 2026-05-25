import Foundation
import Testing

@testable import E05Lib

@Suite("CRXArchive")
struct CRXArchiveTests {
  /// Build a synthetic CRX3 byte stream. The CrxFileHeader is opaque
  /// to `extractZIP`, so the `header` argument can be arbitrary bytes
  /// of any length; that's exactly what production CRX3 reuses for
  /// protobuf-encoded signatures.
  private func crx3(header: Data, payload: Data) -> Data {
    var blob = Data()
    blob.append(contentsOf: [0x43, 0x72, 0x32, 0x34])
    blob.append(uint32LE: 3)
    blob.append(uint32LE: UInt32(header.count))
    blob.append(header)
    blob.append(payload)
    return blob
  }

  private func crx2(pubKey: Data, signature: Data, payload: Data) -> Data {
    var blob = Data()
    blob.append(contentsOf: [0x43, 0x72, 0x32, 0x34])
    blob.append(uint32LE: 2)
    blob.append(uint32LE: UInt32(pubKey.count))
    blob.append(uint32LE: UInt32(signature.count))
    blob.append(pubKey)
    blob.append(signature)
    blob.append(payload)
    return blob
  }

  @Test("extracts CRX3 inner ZIP")
  func crx3InnerZip() throws {
    let payload = Data([0x50, 0x4b, 0x03, 0x04, 0xde, 0xad, 0xbe, 0xef])
    let header = Data(repeating: 0xa5, count: 64)
    let blob = crx3(header: header, payload: payload)
    let extracted = try CRXArchive.extractZIP(from: blob)
    #expect(extracted == payload)
  }

  @Test("extracts CRX2 inner ZIP")
  func crx2InnerZip() throws {
    let payload = Data([0x50, 0x4b, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04])
    let pubKey = Data(repeating: 0x11, count: 130)
    let signature = Data(repeating: 0x22, count: 256)
    let blob = crx2(pubKey: pubKey, signature: signature, payload: payload)
    let extracted = try CRXArchive.extractZIP(from: blob)
    #expect(extracted == payload)
  }

  @Test("rejects truncated input")
  func truncated() {
    let blob = Data([0x43, 0x72, 0x32, 0x34, 0x03, 0x00])  // 6 bytes
    #expect(throws: CRXArchive.CRXError.self) {
      try CRXArchive.extractZIP(from: blob)
    }
  }

  @Test("rejects bad magic")
  func badMagic() {
    var blob = Data([0xff, 0xff, 0xff, 0xff])
    blob.append(uint32LE: 3)
    blob.append(uint32LE: 0)
    blob.append(Data(repeating: 0x00, count: 100))
    #expect(throws: CRXArchive.CRXError.self) {
      try CRXArchive.extractZIP(from: blob)
    }
  }

  @Test("rejects unsupported version")
  func unsupportedVersion() {
    var blob = Data([0x43, 0x72, 0x32, 0x34])
    blob.append(uint32LE: 99)
    blob.append(Data(repeating: 0x00, count: 100))
    #expect(throws: CRXArchive.CRXError.self) {
      try CRXArchive.extractZIP(from: blob)
    }
  }

  @Test("rejects header size that overruns the buffer")
  func overrunHeader() {
    var blob = Data([0x43, 0x72, 0x32, 0x34])
    blob.append(uint32LE: 3)
    blob.append(uint32LE: 9999)  // huge header_size
    blob.append(Data(repeating: 0x00, count: 4))
    #expect(throws: CRXArchive.CRXError.self) {
      try CRXArchive.extractZIP(from: blob)
    }
  }
}

extension Data {
  fileprivate mutating func append(uint32LE value: UInt32) {
    var v = value.littleEndian
    Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
  }
}
