import Foundation
import Testing

@testable import E05Lib

@Suite("ABPCosmeticParser")
struct ABPCosmeticParserTests {
  @Test("blank and comment lines return nil")
  func blankAndComment() {
    #expect(ABPCosmeticParser.parseLine("") == nil)
    #expect(ABPCosmeticParser.parseLine("   ") == nil)
    #expect(ABPCosmeticParser.parseLine("! this is a comment") == nil)
    #expect(ABPCosmeticParser.parseLine("[Adblock Plus 2.0]") == nil)
  }

  @Test("network rules are not cosmetic")
  func networkLinesReturnNil() {
    #expect(ABPCosmeticParser.parseLine("||ads.example.com^") == nil)
    #expect(ABPCosmeticParser.parseLine("@@||good.example.com^") == nil)
  }

  @Test("generic ## hide yields hide rule with empty domains")
  func genericHide() {
    let rule = ABPCosmeticParser.parseLine("##.banner-ad")
    #expect(rule != nil)
    #expect(rule?.kind == .hide)
    #expect(rule?.domains.isEmpty == true)
    #expect(rule?.excludedDomains.isEmpty == true)
    #expect(rule?.selector == ".banner-ad")
    #expect(rule?.isProcedural == false)
  }

  @Test("domain-scoped hide captures positive domains lowercased")
  func domainScopedHide() {
    let rule = ABPCosmeticParser.parseLine("EXAMPLE.com,other.com##.ad")
    #expect(rule?.domains == ["example.com", "other.com"])
    #expect(rule?.excludedDomains.isEmpty == true)
    #expect(rule?.selector == ".ad")
  }

  @Test("tilde prefix routes into excludedDomains")
  func excludedDomains() {
    let rule = ABPCosmeticParser.parseLine("example.com,~sub.example.com##.ad")
    #expect(rule?.domains == ["example.com"])
    #expect(rule?.excludedDomains == ["sub.example.com"])
  }

  @Test("#@# marker produces unhide rule")
  func unhideRule() {
    let rule = ABPCosmeticParser.parseLine("example.com#@#.ad")
    #expect(rule?.kind == .unhide)
    #expect(rule?.domains == ["example.com"])
    #expect(rule?.isProcedural == false)
  }

  @Test("#?# marker is flagged procedural")
  func proceduralRule() {
    let rule = ABPCosmeticParser.parseLine("example.com#?#div:has-text(Sponsored)")
    #expect(rule?.kind == .hide)
    #expect(rule?.isProcedural == true)
    #expect(rule?.selector == "div:has-text(Sponsored)")
  }

  @Test("AdGuard/uBO scriptlet and extended-style markers are rejected")
  func unsupportedMarkersRejected() {
    #expect(ABPCosmeticParser.parseLine("example.com#$#.ad { display: none }") == nil)
    #expect(ABPCosmeticParser.parseLine("example.com#%#//scriptlet(foo)") == nil)
    #expect(ABPCosmeticParser.parseLine("example.com#$?#.ad") == nil)
    #expect(ABPCosmeticParser.parseLine("example.com##+js(nobab)") == nil)
  }

  @Test("HTML-filter ^script selectors are rejected")
  func htmlFilterRejected() {
    #expect(ABPCosmeticParser.parseLine("example.com##^script[src*=\"ads\"]") == nil)
  }

  @Test("inline :style(...) rules are rejected")
  func inlineStyleRejected() {
    #expect(ABPCosmeticParser.parseLine("example.com##.ad:style(opacity: 0)") == nil)
  }

  @Test("parseAll walks every line")
  func parseAll() {
    let text = """
      ! comment
      ##.generic-ad
      example.com##.domain-ad
      example.com#@#.whitelisted
      example.com#?#div:has-text(PR)
      ||network.example.com^
      """
    let rules = ABPCosmeticParser.parseAll(text)
    #expect(rules.count == 4)
    let kinds = rules.map(\.kind)
    #expect(kinds == [.hide, .hide, .unhide, .hide])
  }
}

@Suite("CosmeticIndex")
struct CosmeticIndexTests {
  @Test("extractHead treats bare `.foo` as simple class")
  func extractHeadSimpleClass() {
    let r = CosmeticIndex.extractHead(".banner", prefix: ".")
    #expect(r?.0 == "banner")
    #expect(r?.1 == false)
  }

  @Test("extractHead treats `.foo .bar` as complex class on foo")
  func extractHeadComplexClass() {
    let r = CosmeticIndex.extractHead(".foo .bar", prefix: ".")
    #expect(r?.0 == "foo")
    #expect(r?.1 == true)
  }

  @Test("extractHead handles id prefix")
  func extractHeadId() {
    #expect(CosmeticIndex.extractHead("#main-banner", prefix: "#")?.0 == "main-banner")
    #expect(CosmeticIndex.extractHead("#main > span", prefix: "#")?.1 == true)
  }

  @Test("extractHead rejects selectors missing the requested prefix")
  func extractHeadMismatch() {
    #expect(CosmeticIndex.extractHead("div.banner", prefix: ".") == nil)
    #expect(CosmeticIndex.extractHead("[data-ad]", prefix: "#") == nil)
  }

  @Test("generic simple class selector lands in simpleClassRules")
  func genericSimpleClass() {
    var idx = CosmeticIndex()
    idx.add(parse("##.banner-ad"))
    #expect(idx.simpleClassRules.contains("banner-ad"))
    #expect(idx.complexClassRules.isEmpty)
    #expect(idx.miscGenericSelectors.isEmpty)
  }

  @Test("generic complex class selector lands in complexClassRules")
  func genericComplexClass() {
    var idx = CosmeticIndex()
    idx.add(parse("##.container .ad > span"))
    #expect(idx.complexClassRules["container"] == [".container .ad > span"])
    #expect(!idx.simpleClassRules.contains("container"))
  }

  @Test("generic attribute selector falls to miscGenericSelectors")
  func genericAttributeSelector() {
    var idx = CosmeticIndex()
    idx.add(parse("##[data-ad-slot]"))
    #expect(idx.miscGenericSelectors.contains("[data-ad-slot]"))
  }

  @Test("domain-scoped hide populates hostnameHide for each positive token")
  func domainScopedHide() {
    var idx = CosmeticIndex()
    idx.add(parse("example.com,other.com##.promo"))
    #expect(idx.hostnameHide["example.com"] == [".promo"])
    #expect(idx.hostnameHide["other.com"] == [".promo"])
  }

  @Test("domain-scoped unhide goes into hostnameUnhide")
  func domainScopedUnhide() {
    var idx = CosmeticIndex()
    idx.add(parse("example.com#@#.keepme"))
    #expect(idx.hostnameUnhide["example.com"] == [".keepme"])
  }

  @Test("procedural hide populates hostnameProcedural only")
  func domainScopedProcedural() {
    var idx = CosmeticIndex()
    idx.add(parse("example.com#?#div:has-text(Sponsored)"))
    #expect(idx.hostnameProcedural["example.com"] == ["div:has-text(Sponsored)"])
    #expect(idx.hostnameHide["example.com"] == nil)
  }

  @Test("queryHostname walks the parent chain and returns misc bucket")
  func queryHostnameParentChain() {
    var idx = CosmeticIndex()
    idx.add(parse("example.com##.parent-ad"))
    idx.add(parse("sub.example.com##.child-ad"))
    idx.add(parse("##[data-root-ad]"))

    let result = idx.queryHostname("sub.example.com")
    #expect(result.hostnameHide.contains(".parent-ad"))
    #expect(result.hostnameHide.contains(".child-ad"))
    #expect(result.misc.contains("[data-root-ad]"))
  }

  @Test("queryHostname subtracts matching #@# exceptions")
  func queryHostnameUnhideSubtraction() {
    var idx = CosmeticIndex()
    idx.add(parse("example.com##.promo"))
    idx.add(parse("example.com#@#.promo"))
    let result = idx.queryHostname("example.com")
    #expect(result.hostnameHide.isEmpty)
  }

  @Test("queryHostname drops bare TLD parents")
  func queryHostnameNoBareTLD() {
    // A rule keyed on `com` would be pathological; the parent walk
    // must stop before it.
    let parents = CosmeticIndex.parentHostnames("foo.example.com")
    #expect(parents == ["foo.example.com", "example.com"])
  }

  @Test("queryHostname surfaces procedural selector bodies")
  func queryHostnameProceduralPassthrough() {
    var idx = CosmeticIndex()
    idx.add(parse("example.com#?#div:has-text(PR)"))
    let result = idx.queryHostname("example.com")
    #expect(result.procedural == ["div:has-text(PR)"])
  }

  @Test("queryClassesAndIds resolves simple classes to .name form")
  func queryClassesSimple() {
    var idx = CosmeticIndex()
    idx.add(parse("##.banner-ad"))
    let hide = idx.queryClassesAndIds(
      hostname: "example.com",
      classes: ["banner-ad", "not-an-ad"],
      ids: []
    )
    #expect(hide == [".banner-ad"])
  }

  @Test("queryClassesAndIds expands complex class maps")
  func queryClassesComplex() {
    var idx = CosmeticIndex()
    idx.add(parse("##.wrap .ad"))
    let hide = idx.queryClassesAndIds(
      hostname: "example.com",
      classes: ["wrap"],
      ids: []
    )
    #expect(hide == [".wrap .ad"])
  }

  @Test("queryClassesAndIds filters out hostname-scoped #@# matches")
  func queryClassesUnhideFilter() {
    var idx = CosmeticIndex()
    idx.add(parse("##.promo"))
    idx.add(parse("example.com#@#.promo"))
    let hide = idx.queryClassesAndIds(
      hostname: "example.com",
      classes: ["promo"],
      ids: []
    )
    #expect(hide.isEmpty)
  }

  @Test("queryClassesAndIds resolves simple ids to #name form")
  func queryIdsSimple() {
    var idx = CosmeticIndex()
    idx.add(parse("###sidebar-ad"))
    let hide = idx.queryClassesAndIds(
      hostname: "example.com",
      classes: [],
      ids: ["sidebar-ad"]
    )
    #expect(hide == ["#sidebar-ad"])
  }

  // MARK: - Behavior lock-in

  @Test("generic #@# exception is a noop")
  func genericUnhideIsNoop() {
    // `#@#.selector` (no positive domain) means "unhide everywhere
    // except the listed domains". `CosmeticIndex.add` drops these
    // silently because materialising the difference at index-build
    // time, or running a second lookup at query time, isn't
    // justified by the observed filter traffic. The test pins the
    // drop so re-introducing the path lands as an intentional diff.
    var idx = CosmeticIndex()
    idx.add(parse("#@#.tricky"))
    #expect(idx.hostnameUnhide.isEmpty)
    #expect(idx.simpleClassRules.isEmpty)
    #expect(idx.miscGenericSelectors.isEmpty)
  }

  @Test("procedural #@?# exception is dropped before indexing")
  func proceduralUnhideDropped() {
    // Procedural unhides are rare; without a matching procedural
    // hide they have nothing to cancel, and with one the worst
    // case is leaving a rare exception un-applied. The current
    // index drops them so they don't leak through the non-
    // procedural buckets — the test pins that contract.
    var idx = CosmeticIndex()
    idx.add(parse("example.com#@?#div:has-text(x)"))
    #expect(idx.hostnameProcedural.isEmpty)
    #expect(idx.hostnameUnhide.isEmpty)
  }

  @Test("same class name across simple and complex rules both resolve")
  func sameClassSimpleAndComplex() {
    var idx = CosmeticIndex()
    idx.add(parse("##.foo"))
    idx.add(parse("##.foo .bar"))
    let hide = idx.queryClassesAndIds(
      hostname: "example.com",
      classes: ["foo"],
      ids: []
    )
    // Observing `.foo` in the live DOM should pull out both the
    // simple `.foo` rule and every complex rule keyed on `foo`.
    #expect(hide.count == 2)
    #expect(hide.contains(".foo"))
    #expect(hide.contains(".foo .bar"))
  }

  // MARK: - Defensive CSS escape gate

  @Test("selectors containing `{` are rejected by add")
  func rejectBraceOpenSelector() {
    // A CSS selector that carries `{` would close the outer rule
    // early and let attacker-supplied filterlist content inject
    // arbitrary CSS. The parser's filter-syntax pass does not see
    // a raw brace as a filter error, so the defensive gate in
    // `add` is the last line of defense.
    var idx = CosmeticIndex()
    idx.add(
      ABPCosmeticParser.ParsedRule(
        kind: .hide,
        domains: [],
        excludedDomains: [],
        selector: ".foo{background:red",
        isProcedural: false
      )
    )
    #expect(idx.simpleClassRules.isEmpty)
    #expect(idx.complexClassRules.isEmpty)
    #expect(idx.miscGenericSelectors.isEmpty)
  }

  @Test("selectors containing `}` are rejected by add")
  func rejectBraceCloseSelector() {
    var idx = CosmeticIndex()
    idx.add(
      ABPCosmeticParser.ParsedRule(
        kind: .hide,
        domains: ["example.com"],
        excludedDomains: [],
        selector: ".foo}x{display:block",
        isProcedural: false
      )
    )
    #expect(idx.hostnameHide.isEmpty)
    #expect(idx.simpleClassRules.isEmpty)
  }

  // MARK: - Helper

  private func parse(_ line: String) -> ABPCosmeticParser.ParsedRule {
    guard let rule = ABPCosmeticParser.parseLine(line) else {
      fatalError("parseLine returned nil for test fixture: \(line)")
    }
    return rule
  }
}
