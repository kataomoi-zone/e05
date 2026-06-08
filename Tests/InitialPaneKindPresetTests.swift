import Foundation
import Testing

@testable import E05Lib

@Suite("InitialPaneKindPreset")
@MainActor
struct InitialPaneKindPresetTests {
  @Test("resolve nil falls back to terminal")
  func resolveNil() {
    #expect(InitialPaneKindPreset.resolve(nil) == .terminal)
  }

  @Test("resolve unknown identifier falls back to terminal")
  func resolveUnknown() {
    #expect(InitialPaneKindPreset.resolve("unknown") == .terminal)
    #expect(InitialPaneKindPreset.resolve("") == .terminal)
  }

  @Test("resolve known identifier returns the matching case")
  func resolveKnown() {
    #expect(InitialPaneKindPreset.resolve("terminal") == .terminal)
    #expect(InitialPaneKindPreset.resolve("browser") == .browser)
    #expect(InitialPaneKindPreset.resolve("finder") == .finder)
  }

  @Test("rawValue round-trips through resolve for every case")
  func rawValueRoundTrip() {
    for preset in InitialPaneKindPreset.allCases {
      #expect(InitialPaneKindPreset.resolve(preset.rawValue) == preset)
    }
  }

  @Test("each preset seeds the matching pane kind")
  func addressKind() {
    #expect(InitialPaneKindPreset.terminal.address.kind == .terminal)
    #expect(InitialPaneKindPreset.finder.address.kind == .finder)
    // Browser delegates to the new-pane home address: the configured
    // home URL (browser-kind) when set, otherwise the e05://start
    // launcher. Assert the delegation rather than a fixed kind so the
    // test doesn't depend on the ambient home-URL preference.
    #expect(InitialPaneKindPreset.browser.address == PaneAddress.newPaneHome)
  }

  @Test("every preset has a non-empty label and symbol")
  func metadata() {
    for preset in InitialPaneKindPreset.allCases {
      #expect(!preset.displayName.isEmpty)
      #expect(!preset.symbol.isEmpty)
    }
  }
}
