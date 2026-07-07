import Testing

@testable import E05Lib

@Suite("ChromeWebStoreOverlay origin gate")
@MainActor
struct ChromeWebStoreOverlayTests {
  @Test("trusted CWS main frames over https pass")
  func trustedHostsPass() {
    #expect(
      ChromeWebStoreOverlay.isTrustedOrigin(
        isMainFrame: true, scheme: "https", host: "chromewebstore.google.com"))
    #expect(
      ChromeWebStoreOverlay.isTrustedOrigin(
        isMainFrame: true, scheme: "https", host: "chrome.google.com"))
  }

  @Test("sub-frames are rejected even on a trusted host")
  func subFramesRejected() {
    #expect(
      !ChromeWebStoreOverlay.isTrustedOrigin(
        isMainFrame: false, scheme: "https", host: "chromewebstore.google.com"))
  }

  @Test("non-https schemes are rejected")
  func plaintextRejected() {
    #expect(
      !ChromeWebStoreOverlay.isTrustedOrigin(
        isMainFrame: true, scheme: "http", host: "chromewebstore.google.com"))
  }

  @Test("arbitrary and look-alike hosts are rejected")
  func untrustedHostsRejected() {
    #expect(
      !ChromeWebStoreOverlay.isTrustedOrigin(
        isMainFrame: true, scheme: "https", host: "evil.example"))
    #expect(
      !ChromeWebStoreOverlay.isTrustedOrigin(
        isMainFrame: true, scheme: "https", host: "chromewebstore.google.com.evil.example"))
    #expect(
      !ChromeWebStoreOverlay.isTrustedOrigin(
        isMainFrame: true, scheme: "https", host: ""))
    // Trailing-dot fully-qualified form is not the allowlisted host —
    // stays fail-closed.
    #expect(
      !ChromeWebStoreOverlay.isTrustedOrigin(
        isMainFrame: true, scheme: "https", host: "chromewebstore.google.com."))
  }
}
