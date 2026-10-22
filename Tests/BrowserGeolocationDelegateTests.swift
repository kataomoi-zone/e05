import Foundation
import ObjectiveC
import Testing

@testable import E05Lib

/// WebKit finds these by selector at runtime, so a Swift signature that
/// drifts from the Objective-C name compiles and is never called.
@Suite("Browser geolocation delegate")
struct BrowserGeolocationDelegateTests {
  @Test("the pane answers both the public and the private geolocation selector")
  func respondsToBothSelectors() {
    for name in [
      "webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:",
      "_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:",
    ] {
      #expect(class_getInstanceMethod(BrowserPaneView.self, NSSelectorFromString(name)) != nil)
    }
  }
}
