import AppKit
import GhosttyKit

MainActor.assumeIsolated {
    let success = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
    print("[e05] ghostty_init: \(success)")

    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
}
