import Testing
import WebKit

@testable import E05Lib

@Suite("WebKit geolocation API")
struct WebKitGeolocationAPITests {
  @Test("every C function the location provider calls resolves in the linked WebKit")
  func resolves() {
    #expect(WebKitGeolocationAPI.load() != nil)
  }

  @Test("the provider struct has the WKGeolocationProviderV0 layout")
  func providerLayout() {
    #expect(MemoryLayout<ProviderV0>.offset(of: \.clientInfo) == 8)
    #expect(MemoryLayout<ProviderV0>.offset(of: \.startUpdating) == 16)
    #expect(MemoryLayout<ProviderV0>.offset(of: \.stopUpdating) == 24)
    #expect(MemoryLayout<ProviderV0>.size == 32)
  }
}
