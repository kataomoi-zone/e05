import AppKit
import E05Lib

MainActor.assumeIsolated {
  // Before anything can create a web view: WebKit reads these once.
  WebTextChecking.register()
  let delegate = AppDelegate()
  let app = NSApplication.shared
  app.setActivationPolicy(.regular)
  app.delegate = delegate
  app.run()
}
