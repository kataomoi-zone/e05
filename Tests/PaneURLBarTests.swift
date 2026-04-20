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
        #expect(bar.urlTrailingToFold?.isActive == true)
        #expect(bar.urlTrailingToZoom?.isActive == false)
    }

    @Test("setZoomPercent reveals the indicator and renders a rounded percent")
    @MainActor func shownAtZoom() {
        let bar = PaneURLBar(frame: .zero)
        bar.setZoomPercent(1.25)
        #expect(!bar.zoomContainer.isHidden)
        #expect(bar.urlTrailingToFold?.isActive == false)
        #expect(bar.urlTrailingToZoom?.isActive == true)
        #expect(bar.zoomPercentLabel.stringValue == "125%")
    }

    @Test("setZoomPercent swaps constraints on toggle between default and scaled")
    @MainActor func constraintSwap() {
        let bar = PaneURLBar(frame: .zero)
        bar.setZoomPercent(1.5)
        #expect(bar.urlTrailingToZoom?.isActive == true)
        bar.setZoomPercent(1.0)
        #expect(bar.urlTrailingToFold?.isActive == true)
        #expect(bar.urlTrailingToZoom?.isActive == false)
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
}
