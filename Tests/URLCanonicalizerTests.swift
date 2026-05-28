import Testing

@testable import E05Lib

@Suite("URLCanonicalizer")
struct URLCanonicalizerTests {
  @Test("folds www, fragment, and trailing slash")
  func basicFolding() {
    let a = URLCanonicalizer.canonicalKey("https://www.example.com/path/#section")
    let b = URLCanonicalizer.canonicalKey("https://example.com/path")
    #expect(a != nil)
    #expect(a == b)
  }

  @Test("folds bare host with and without trailing slash")
  func rootSlash() {
    #expect(
      URLCanonicalizer.canonicalKey("https://example.com")
        == URLCanonicalizer.canonicalKey("https://example.com/"))
  }

  @Test("folds http and https")
  func schemeFold() {
    #expect(
      URLCanonicalizer.canonicalKey("http://example.com")
        == URLCanonicalizer.canonicalKey("https://example.com"))
  }

  @Test("strips tracking params, keeps meaningful query")
  func trackingStrip() {
    let a = URLCanonicalizer.canonicalKey("https://example.com/p?utm_source=x&id=5&fbclid=abc")
    let b = URLCanonicalizer.canonicalKey("https://example.com/p?id=5")
    #expect(a == b)
  }

  @Test("query order does not split the key")
  func querySort() {
    let a = URLCanonicalizer.canonicalKey("https://example.com/?b=2&a=1")
    let b = URLCanonicalizer.canonicalKey("https://example.com/?a=1&b=2")
    #expect(a == b)
  }

  @Test("distinct pages keep distinct keys")
  func distinctPages() {
    #expect(
      URLCanonicalizer.canonicalKey("https://example.com/foo")
        != URLCanonicalizer.canonicalKey("https://example.com/bar"))
  }

  @Test("port is part of identity")
  func portMatters() {
    #expect(
      URLCanonicalizer.canonicalKey("http://localhost:3000")
        != URLCanonicalizer.canonicalKey("http://localhost:8080"))
  }

  @Test("non-http(s) and unparseable inputs return nil")
  func nonHTTPNil() {
    #expect(URLCanonicalizer.canonicalKey("ftp://example.com") == nil)
    #expect(URLCanonicalizer.canonicalKey("about:blank") == nil)
    #expect(URLCanonicalizer.canonicalKey("") == nil)
  }
}
