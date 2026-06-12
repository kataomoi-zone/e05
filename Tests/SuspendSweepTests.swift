import Testing

@testable import E05Lib

@Suite("Suspend sweep")
struct SuspendSweepTests {
  @Test(
    "loopback hosts are spared",
    arguments: [
      "localhost", "LOCALHOST", "app.localhost", "Dev.Localhost",
      "127.0.0.1", "127.1.2.3", "127.255.255.255", "::1", "[::1]",
    ])
  func loopbackMatches(host: String) {
    #expect(PaneContainerViewController.isLoopbackHost(host))
  }

  @Test(
    "public and LAN hosts are not spared",
    arguments: [
      "example.com", "youtube.com", "localhost.example.com",
      "notlocalhost", "192.168.1.1", "10.0.0.1", "1.2.3.4",
      // `127.`-prefixed names that aren't dotted-decimal IPv4 literals.
      "127.example.com", "127.0.0.1.evil.com", "127.foo", "127.0.0.256",
    ])
  func nonLoopback(host: String) {
    #expect(!PaneContainerViewController.isLoopbackHost(host))
  }
}
