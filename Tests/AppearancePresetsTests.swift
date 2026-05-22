import AppKit
import Foundation
import Testing

@testable import E05Lib

@Suite("AccentPalettePreset")
@MainActor
struct AccentPalettePresetTests {
  @Test("resolve nil falls back to subway")
  func resolveNil() {
    #expect(AccentPalettePreset.resolve(nil) == .subway)
  }

  @Test("resolve unknown identifier falls back to subway")
  func resolveUnknown() {
    #expect(AccentPalettePreset.resolve("unknown") == .subway)
    #expect(AccentPalettePreset.resolve("") == .subway)
  }

  @Test("resolve known identifier returns the matching case")
  func resolveKnown() {
    #expect(AccentPalettePreset.resolve("subway") == .subway)
    #expect(AccentPalettePreset.resolve("metro") == .metro)
    #expect(AccentPalettePreset.resolve("unicorn") == .unicorn)
  }

  @Test("every preset ships at least four colors")
  func presetSize() {
    for preset in AccentPalettePreset.allCases {
      #expect(preset.colors.count >= 4, "\(preset.rawValue) has \(preset.colors.count) colors")
    }
  }

  @Test("subway preset preserves the historical four-colour palette")
  func subwayMatchesLegacy() {
    let colors = AccentPalettePreset.subway.colors
    // Pre-preset palette: pink, yellow-green, coral, blue. Subway is
    // the preserved-default carry-over.
    #expect(colors.count == 4)
    #expect(approximatelyEqual(colors[0], srgbR: 0xce, g: 0x05, b: 0x5b))
    #expect(approximatelyEqual(colors[1], srgbR: 0xb0, g: 0xbf, b: 0x1f))
    #expect(approximatelyEqual(colors[2], srgbR: 0xec, g: 0x6e, b: 0x65))
    #expect(approximatelyEqual(colors[3], srgbR: 0x02, g: 0x79, b: 0xc2))
  }

  private func approximatelyEqual(
    _ color: NSColor, srgbR: Int, g: Int, b: Int
  ) -> Bool {
    guard let srgb = color.usingColorSpace(.sRGB) else { return false }
    let tolerance: CGFloat = 1 / 255 + 0.001
    return abs(srgb.redComponent - CGFloat(srgbR) / 255) < tolerance
      && abs(srgb.greenComponent - CGFloat(g) / 255) < tolerance
      && abs(srgb.blueComponent - CGFloat(b) / 255) < tolerance
  }
}

@Suite("CornerRadiusPreset")
@MainActor
struct CornerRadiusPresetTests {
  @Test("resolve nil falls back to standard (historical default)")
  func resolveNil() {
    #expect(CornerRadiusPreset.resolve(nil) == .standard)
  }

  @Test("resolve unknown identifier falls back to standard")
  func resolveUnknown() {
    #expect(CornerRadiusPreset.resolve("unknown") == .standard)
    #expect(CornerRadiusPreset.resolve("") == .standard)
  }

  @Test("resolve known identifier returns the matching case")
  func resolveKnown() {
    #expect(CornerRadiusPreset.resolve("sharp") == .sharp)
    #expect(CornerRadiusPreset.resolve("rounded") == .rounded)
    #expect(CornerRadiusPreset.resolve("standard") == .standard)
    #expect(CornerRadiusPreset.resolve("soft") == .soft)
  }

  @Test("preset values are non-negative and monotonically increasing")
  func valuesMonotonic() {
    #expect(CornerRadiusPreset.sharp.value == 0)
    #expect(CornerRadiusPreset.rounded.value == 6)
    #expect(CornerRadiusPreset.standard.value == 12)
    #expect(CornerRadiusPreset.soft.value == 18)

    let values = CornerRadiusPreset.allCases.map { $0.value }
    for i in 1..<values.count {
      #expect(values[i - 1] < values[i], "preset values not monotonic at index \(i)")
    }
  }

  @Test("standard preserves the historical 12pt default")
  func standardIsHistoricalDefault() {
    #expect(CornerRadiusPreset.standard.value == 12)
  }
}

@Suite("PaneBorderWidthPreset")
@MainActor
struct PaneBorderWidthPresetTests {
  @Test("resolve nil falls back to regular (historical default)")
  func resolveNil() {
    #expect(PaneBorderWidthPreset.resolve(nil) == .regular)
  }

  @Test("resolve unknown identifier falls back to regular")
  func resolveUnknown() {
    #expect(PaneBorderWidthPreset.resolve("unknown") == .regular)
    #expect(PaneBorderWidthPreset.resolve("") == .regular)
  }

  @Test("resolve known identifier returns the matching case")
  func resolveKnown() {
    #expect(PaneBorderWidthPreset.resolve("thin") == .thin)
    #expect(PaneBorderWidthPreset.resolve("regular") == .regular)
    #expect(PaneBorderWidthPreset.resolve("bold") == .bold)
  }

  @Test("regular preserves the historical 2pt border")
  func regularIsHistoricalDefault() {
    #expect(PaneBorderWidthPreset.regular.value == 2)
  }

  @Test("values are positive and monotonically increasing")
  func valuesMonotonic() {
    let values = PaneBorderWidthPreset.allCases.map { $0.value }
    #expect(values.allSatisfy { $0 > 0 })
    for i in 1..<values.count {
      #expect(values[i - 1] < values[i], "border widths not monotonic at index \(i)")
    }
  }
}

@Suite("PaneGapPreset")
@MainActor
struct PaneGapPresetTests {
  @Test("resolve nil falls back to standard (historical default)")
  func resolveNil() {
    #expect(PaneGapPreset.resolve(nil) == .standard)
  }

  @Test("resolve unknown identifier falls back to standard")
  func resolveUnknown() {
    #expect(PaneGapPreset.resolve("unknown") == .standard)
    #expect(PaneGapPreset.resolve("") == .standard)
  }

  @Test("resolve known identifier returns the matching case")
  func resolveKnown() {
    #expect(PaneGapPreset.resolve("tight") == .tight)
    #expect(PaneGapPreset.resolve("standard") == .standard)
    #expect(PaneGapPreset.resolve("loose") == .loose)
  }

  @Test("standard preserves the historical 6pt gap")
  func standardIsHistoricalDefault() {
    #expect(PaneGapPreset.standard.value == 6)
  }

  @Test("values are positive and monotonically increasing")
  func valuesMonotonic() {
    let values = PaneGapPreset.allCases.map { $0.value }
    #expect(values.allSatisfy { $0 > 0 })
    for i in 1..<values.count {
      #expect(values[i - 1] < values[i], "gap values not monotonic at index \(i)")
    }
  }
}

@Suite("ThemePreset")
@MainActor
struct ThemePresetTests {
  @Test("resolve nil falls back to system")
  func resolveNil() {
    #expect(ThemePreset.resolve(nil) == .system)
  }

  @Test("resolve unknown identifier falls back to system")
  func resolveUnknown() {
    #expect(ThemePreset.resolve("unknown") == .system)
    #expect(ThemePreset.resolve("") == .system)
  }

  @Test("resolve known identifier returns the matching case")
  func resolveKnown() {
    #expect(ThemePreset.resolve("system") == .system)
    #expect(ThemePreset.resolve("light") == .light)
    #expect(ThemePreset.resolve("dark") == .dark)
  }

  @Test("system maps to nil appearance (defer to OS)")
  func systemAppearanceIsNil() {
    #expect(ThemePreset.system.appearance == nil)
  }

  @Test("light and dark map to the corresponding named appearances")
  func namedAppearances() {
    #expect(ThemePreset.light.appearance?.name == .aqua)
    #expect(ThemePreset.dark.appearance?.name == .darkAqua)
  }
}

@Suite("Appearance preferences fan-out")
@MainActor
struct AppearancePreferencesTests {
  private func withTempStoreURL(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppearancePresetsTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir.appendingPathComponent("preferences.json"))
  }

  @Test("PreferencesStore round-trip preserves every appearance identifier")
  func roundTripPresetIdentifiers() throws {
    try withTempStoreURL { storeURL in
      let writer = PreferencesStore(storeURL: storeURL)
      writer.update {
        $0.accentPalette = "metro"
        $0.surfaceCornerRadius = "soft"
        $0.paneBorderWidth = "bold"
        $0.paneGap = "loose"
        $0.theme = "light"
      }

      let reader = PreferencesStore(storeURL: storeURL)
      #expect(reader.preferences.accentPalette == "metro")
      #expect(reader.preferences.surfaceCornerRadius == "soft")
      #expect(reader.preferences.paneBorderWidth == "bold")
      #expect(reader.preferences.paneGap == "loose")
      #expect(reader.preferences.theme == "light")
    }
  }

  @Test("older preferences files without appearance fields still decode")
  func legacyDecodeCompatibility() throws {
    try withTempStoreURL { storeURL in
      // Hand-written JSON omitting every appearance field, matching
      // a preferences.json written before the Appearance settings
      // landed.
      let legacy = """
        {
          "version": 1,
          "preferences": {
            "searchTemplate": "https://duckduckgo.com/?q={query}",
            "alwaysPromptDownload": true
          }
        }
        """
      try legacy.data(using: .utf8)!.write(to: storeURL)

      let store = PreferencesStore(storeURL: storeURL)
      #expect(store.preferences.accentPalette == nil)
      #expect(store.preferences.surfaceCornerRadius == nil)
      #expect(store.preferences.paneBorderWidth == nil)
      #expect(store.preferences.paneGap == nil)
      #expect(store.preferences.theme == nil)
    }
  }
}
