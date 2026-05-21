import AppKit
import Testing

@testable import E05Lib

@Suite("GhosttyColorScheme")
struct GhosttyColorSchemeTests {
  @Test("aqua appearance resolves to light")
  func aquaIsLight() throws {
    let appearance = try #require(NSAppearance(named: .aqua))
    #expect(GhosttyColorScheme(appearance) == .light)
  }

  @Test("darkAqua appearance resolves to dark")
  func darkAquaIsDark() throws {
    let appearance = try #require(NSAppearance(named: .darkAqua))
    #expect(GhosttyColorScheme(appearance) == .dark)
  }

  @Test("high-contrast dark collapses to dark")
  func highContrastDarkIsDark() throws {
    let appearance = try #require(
      NSAppearance(named: .accessibilityHighContrastDarkAqua))
    #expect(GhosttyColorScheme(appearance) == .dark)
  }

  @Test("high-contrast light collapses to light")
  func highContrastLightIsLight() throws {
    let appearance = try #require(
      NSAppearance(named: .accessibilityHighContrastAqua))
    #expect(GhosttyColorScheme(appearance) == .light)
  }
}
