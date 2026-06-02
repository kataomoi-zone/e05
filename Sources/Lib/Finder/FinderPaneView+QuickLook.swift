import AppKit
import QuickLookUI

/// Quick Look integration: Space toggles the shared `QLPreviewPanel`
/// against the current selection, and the responder-chain hooks
/// (`accepts…` / `begin…` / `end…`) plus the data-source conformance
/// let the panel read file URLs back out of `items`.
extension FinderPaneView {
  func toggleQuickLook() {
    guard let panel = QLPreviewPanel.shared() else { return }
    if panel.isVisible {
      panel.orderOut(nil)
    } else {
      panel.makeKeyAndOrderFront(nil)
    }
  }

  public override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
    true
  }

  // The QuickLook responder methods come from `NSResponder` which is
  // not MainActor-isolated, but `QLPreviewPanel` only ever invokes them
  // on the main thread. `MainActor.assumeIsolated` records that
  // contract and lets us touch the panel's MainActor-isolated
  // properties without a thread hop.
  public override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    MainActor.assumeIsolated {
      panel.dataSource = self
      panel.delegate = self
    }
  }

  public override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    MainActor.assumeIsolated {
      panel.dataSource = nil
      panel.delegate = nil
    }
  }
}

// `QLPreviewPanelDataSource` is a pre-concurrency Objective-C protocol;
// `@preconcurrency` lets the MainActor-isolated `FinderPaneView` satisfy
// its nonisolated requirements. At runtime QLPreviewPanel only ever invokes
// these on the main thread, so the isolation crossing the compiler warns
// about doesn't actually occur. `QLPreviewPanelDelegate` has no required
// methods we currently implement, so its conformance has no isolation gap
// to bridge.
extension FinderPaneView: @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    selectedURLs.count
  }

  public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (
    any QLPreviewItem
  )! {
    let urls = selectedURLs
    guard index >= 0, index < urls.count else { return nil }
    return urls[index] as NSURL
  }
}
