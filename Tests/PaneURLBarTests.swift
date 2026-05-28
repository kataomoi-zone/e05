import AppKit
import Foundation
import Testing

@testable import E05Lib

@Suite("PaneURLBar")
struct PaneURLBarTests {
  @Test("setZoomPercent hides the indicator at the default zoom")
  @MainActor func hiddenAtDefault() {
    let bar = PaneURLBar(frame: .zero)
    bar.setZoomPercent(1.0)
    #expect(bar.zoomContainer.isHidden)
    #expect(bar.extensionsTrailingToFold?.isActive == true)
    #expect(bar.extensionsTrailingToZoom?.isActive == false)
  }

  @Test("setZoomPercent reveals the indicator and renders a rounded percent")
  @MainActor func shownAtZoom() {
    let bar = PaneURLBar(frame: .zero)
    bar.setZoomPercent(1.25)
    #expect(!bar.zoomContainer.isHidden)
    #expect(bar.extensionsTrailingToFold?.isActive == false)
    #expect(bar.extensionsTrailingToZoom?.isActive == true)
    #expect(bar.zoomPercentLabel.stringValue == "125%")
  }

  @Test("setZoomPercent swaps constraints on toggle between default and scaled")
  @MainActor func constraintSwap() {
    let bar = PaneURLBar(frame: .zero)
    bar.setZoomPercent(1.5)
    #expect(bar.extensionsTrailingToZoom?.isActive == true)
    bar.setZoomPercent(1.0)
    #expect(bar.extensionsTrailingToFold?.isActive == true)
    #expect(bar.extensionsTrailingToZoom?.isActive == false)
  }

  @Test("setZoomPercent treats near-unity values as the default")
  @MainActor func nearUnityCollapsesToDefault() {
    let bar = PaneURLBar(frame: .zero)
    // Repeated 1.1× round-trips can leave pageZoom at ~1 + 4e-16.
    // The epsilon inside setZoomPercent should snap those back to
    // the hidden default without flashing the indicator.
    bar.setZoomPercent(1.0000001)
    #expect(bar.zoomContainer.isHidden)
  }

  @Test("setZoomPercent rounds to the nearest integer percent")
  @MainActor func roundsToNearestPercent() {
    let bar = PaneURLBar(frame: .zero)
    bar.setZoomPercent(0.826)
    #expect(bar.zoomPercentLabel.stringValue == "83%")
    bar.setZoomPercent(1.331)
    #expect(bar.zoomPercentLabel.stringValue == "133%")
  }

  @Test("setReloadButtonLoading(true) advertises the stop affordance")
  @MainActor func reloadButtonEntersLoading() {
    let bar = PaneURLBar(frame: .zero)
    bar.setReloadButtonLoading(true)
    #expect(bar.isReloadLoading)
    #expect(bar.reloadButton.toolTip == "Stop")
    #expect(bar.reloadButton.image?.accessibilityDescription == "Stop")
  }

  @Test("setReloadButtonLoading(false) restores the reload affordance")
  @MainActor func reloadButtonLeavesLoading() {
    let bar = PaneURLBar(frame: .zero)
    bar.setReloadButtonLoading(true)
    bar.setReloadButtonLoading(false)
    #expect(!bar.isReloadLoading)
    #expect(bar.reloadButton.toolTip == "Reload")
    #expect(bar.reloadButton.image?.accessibilityDescription == "Reload")
  }

  @Test("setReloadButtonLoading follows repeated toggles")
  @MainActor func reloadButtonToggleSequence() {
    let bar = PaneURLBar(frame: .zero)
    for expected in [true, false, true, false] {
      bar.setReloadButtonLoading(expected)
      #expect(bar.isReloadLoading == expected)
    }
  }

  @Test("reload button starts in the idle state")
  @MainActor func reloadButtonStartsIdle() {
    let bar = PaneURLBar(frame: .zero)
    // `setReloadButtonLoading(_:)` hasn't been invoked yet, so the
    // flag should reflect the factory-initialised idle state.
    #expect(!bar.isReloadLoading)
    #expect(bar.reloadButton.toolTip == "Reload")
  }

  @Test("setReloadEnabled toggles the reload button availability")
  @MainActor func reloadEnableToggle() {
    let bar = PaneURLBar(frame: .zero)
    // Factory default is enabled; the terminal pane setup path
    // disables it so non-browser panes don't advertise a click
    // that routes to a nil web view.
    #expect(bar.reloadButton.isEnabled)
    bar.setReloadEnabled(false)
    #expect(!bar.reloadButton.isEnabled)
    bar.setReloadEnabled(true)
    #expect(bar.reloadButton.isEnabled)
  }

  @Test("accepting a suggestion with no open pane navigates")
  @MainActor func acceptNavigates() {
    let bar = PaneURLBar(frame: .zero)
    var navigated: String?
    var switched: ULID?
    bar.onNavigate = { navigated = $0 }
    bar.onSwitchToPane = { switched = $0 }
    bar.acceptSuggestion(Suggestion(url: "https://x.com", title: "X", isBookmark: false))
    #expect(navigated == "https://x.com")
    #expect(switched == nil)
  }

  @Test("accepting a suggestion open elsewhere switches instead of navigating")
  @MainActor func acceptSwitches() {
    let bar = PaneURLBar(frame: .zero)
    var navigated: String?
    var switched: ULID?
    let paneID = ULID()
    bar.onNavigate = { navigated = $0 }
    bar.onSwitchToPane = { switched = $0 }
    bar.acceptSuggestion(
      Suggestion(url: "https://x.com", title: "X", isBookmark: false, openPaneID: paneID))
    #expect(switched == paneID)
    #expect(navigated == nil)
  }

  @Test("accepting a suggestion reports the chosen url for learning")
  @MainActor func acceptReportsLearning() {
    let bar = PaneURLBar(frame: .zero)
    var recordedURL: String?
    bar.onSuggestionAccepted = { _, url in recordedURL = url }
    bar.acceptSuggestion(Suggestion(url: "https://k.com", title: "K", isBookmark: false))
    #expect(recordedURL == "https://k.com")
  }
}
