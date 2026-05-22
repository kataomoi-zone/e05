import Foundation
import Testing

@testable import E05Lib

@Suite("ABPtoSafariConverter")
struct ABPtoSafariConverterTests {
  @Test("LF filterlist yields rules for each non-comment line")
  func lfFilterlist() {
    let text = """
      ! comment
      [Adblock Plus 2.0]
      ||ads.example.com^
      ||tracker.example.com^$third-party
      """
    let result = ABPtoSafariConverter.convert(text)
    // Each `||...^` line fans out into URL-end + separator variants.
    #expect(result.rules.count == 4)
    #expect(result.skipped == 0)
  }

  @Test("CRLF filterlist is parsed identically to LF")
  func crlfFilterlist() {
    let text = "! comment\r\n||ads.example.com^\r\n||tracker.example.com^$third-party\r\n"
    let result = ABPtoSafariConverter.convert(text)
    #expect(result.rules.count == 4)
    #expect(result.skipped == 0)
  }

  @Test("empty and blank lines are skipped without counting")
  func blanksAreSkipped() {
    let text = "\n\n  \n||ads.example.com^\n\n"
    let result = ABPtoSafariConverter.convert(text)
    #expect(result.rules.count == 2)
    #expect(result.skipped == 0)
  }

  @Test("trailing ^ fans out into URL-end and separator variants")
  func trailingSeparatorFansOut() {
    let rules = ABPtoSafariConverter.convert("||ads.example.com^").rules
    #expect(rules.count == 2)
    let patterns = rules.map(\.trigger.urlFilter)
    #expect(patterns.contains(where: { $0.hasSuffix("ads\\.example\\.com$") }))
    #expect(patterns.contains(where: { $0.hasSuffix("[/:?=&]") }))
  }

  @Test("interior ^ stays a separator char")
  func interiorSeparator() {
    let rules = ABPtoSafariConverter.convert("||example.com^path").rules
    #expect(rules.count == 1)
    let pat = rules[0].trigger.urlFilter
    #expect(pat.contains("example\\.com[/:?=&]path"))
  }

  @Test("network block produces url-filter regex with block action")
  func networkBlock() {
    let rules = ABPtoSafariConverter.convert("||ads.example.com^").rules
    #expect(!rules.isEmpty)
    #expect(rules.allSatisfy { $0.action.type == "block" })
    #expect(rules.allSatisfy { $0.trigger.urlFilter.contains("ads\\.example\\.com") })
  }

  @Test("url-filter uses non-capturing subdomain group")
  func nonCapturingSubdomain() {
    let rules = ABPtoSafariConverter.convert("||ads.example.com^").rules
    #expect(!rules.isEmpty)
    for rule in rules {
      #expect(rule.trigger.urlFilter.contains("(?:[^/]+"))
      #expect(!rule.trigger.urlFilter.contains("([^/]+\\."))
    }
  }

  @Test("url-filter separator uses character class, not alternation")
  func separatorCharClass() {
    let rules = ABPtoSafariConverter.convert("||ads.example.com^").rules
    #expect(!rules.isEmpty)
    for rule in rules {
      #expect(!rule.trigger.urlFilter.contains("|$"))
    }
  }

  @Test("exception becomes ignore-previous-rules action")
  func exception() {
    let rules = ABPtoSafariConverter.convert("@@||analytics.example.com^").rules
    #expect(!rules.isEmpty)
    #expect(rules.allSatisfy { $0.action.type == "ignore-previous-rules" })
  }

  @Test("generic cosmetic hide uses css-display-none action")
  func genericCosmetic() {
    let rules = ABPtoSafariConverter.convert("##.ad-banner").rules
    #expect(rules.count == 1)
    #expect(rules[0].action.type == "css-display-none")
    #expect(rules[0].action.selector == ".ad-banner")
    #expect(rules[0].trigger.ifDomain == nil)
  }

  @Test("domain-scoped cosmetic drops unless-domain when both are specified")
  func domainScopedCosmeticDropsUnless() {
    // WebKit's Content Blocker rejects triggers with both if-domain
    // and unless-domain, so the converter keeps the positive list
    // and drops the negative exclusions to preserve the block scope.
    let rules = ABPtoSafariConverter.convert("example.com,~sub.example.com##.side-ad").rules
    #expect(rules.count == 1)
    #expect(rules[0].trigger.ifDomain == ["*example.com"])
    #expect(rules[0].trigger.unlessDomain == nil)
  }

  @Test("pure unless-domain cosmetic passes through")
  func unlessOnlyCosmetic() {
    let rules = ABPtoSafariConverter.convert("~example.com##.global-ad").rules
    #expect(rules.count == 1)
    #expect(rules[0].trigger.ifDomain == nil)
    #expect(rules[0].trigger.unlessDomain == ["*example.com"])
  }

  @Test("cosmetic exception #@# is skipped")
  func cosmeticException() {
    let result = ABPtoSafariConverter.convert("example.com#@#.side-ad")
    #expect(result.rules.isEmpty)
  }

  @Test("procedural cosmetic is skipped")
  func procedural() {
    let result = ABPtoSafariConverter.convert("example.com##div:has-text(Sponsored)")
    #expect(result.rules.isEmpty)
  }

  @Test("scriptlet injection is skipped")
  func scriptlet() {
    let result = ABPtoSafariConverter.convert("example.com##+js(set-constant, adblock, false)")
    #expect(result.rules.isEmpty)
  }

  @Test("AdGuard #%# JS rule is skipped")
  func adguardJsRule() {
    let result = ABPtoSafariConverter.convert(
      "pokegonews.net#%#//scriptlet('prevent-eval-if', '広告')"
    )
    #expect(result.rules.isEmpty)
  }

  @Test("AdGuard $$ HTML filter is skipped")
  func adguardHtmlFilter() {
    let result = ABPtoSafariConverter.convert("example.com$$script[tag-content=\"ads\"]")
    #expect(result.rules.isEmpty)
  }

  @Test("AdGuard $replace option is skipped")
  func replaceOption() {
    let result = ABPtoSafariConverter.convert(
      "||example.com/ad.js$replace=/foo/bar/"
    )
    #expect(result.rules.isEmpty)
  }

  @Test("AdGuard $removeparam is skipped")
  func removeparamOption() {
    let result = ABPtoSafariConverter.convert(
      "||example.com^$removeparam=utm_source"
    )
    #expect(result.rules.isEmpty)
  }

  @Test("AdGuard $all option is skipped")
  func allOption() {
    let result = ABPtoSafariConverter.convert("||sankei.click^$all")
    #expect(result.rules.isEmpty)
  }

  @Test("AdGuard #@%# JS exception is skipped")
  func adguardJsException() {
    let result = ABPtoSafariConverter.convert(
      "example.com#@%#window.adblock = false;"
    )
    #expect(result.rules.isEmpty)
  }

  @Test("third-party option populates load-type")
  func thirdPartyOption() {
    let rules = ABPtoSafariConverter.convert("||tracker.example.com^$third-party").rules
    #expect(!rules.isEmpty)
    #expect(rules.allSatisfy { $0.trigger.loadType == ["third-party"] })
  }

  @Test("domain= option drops unless when combined with if")
  func domainOption() {
    let rules = ABPtoSafariConverter.convert("||ads.example.com^$domain=news.com|~sub.news.com").rules
    #expect(!rules.isEmpty)
    for rule in rules {
      #expect(rule.trigger.ifDomain == ["*news.com"])
      #expect(rule.trigger.unlessDomain == nil)
    }
  }

  @Test("pure negative domain option passes through as unless-domain")
  func pureNegativeDomainOption() {
    let rules = ABPtoSafariConverter.convert("||tracker.example.com^$domain=~sub.example.com").rules
    #expect(!rules.isEmpty)
    for rule in rules {
      #expect(rule.trigger.ifDomain == nil)
      #expect(rule.trigger.unlessDomain == ["*sub.example.com"])
    }
  }

  @Test("resource-type option maps to Safari type")
  func resourceTypeOption() {
    let rules = ABPtoSafariConverter.convert("||tracker.example.com^$script,image").rules
    #expect(!rules.isEmpty)
    let types = Set(rules[0].trigger.resourceType ?? [])
    #expect(types == Set(["script", "image"]))
  }

  @Test("load-type collapses conflicting options to the last winner")
  func loadTypeLastWins() {
    let rules = ABPtoSafariConverter.convert(
      "||tracker.example.com^$~third-party,first-party"
    ).rules
    #expect(!rules.isEmpty)
    for rule in rules {
      #expect(rule.trigger.loadType == ["first-party"])
    }
  }

  @Test("unknown option rejects the whole rule")
  func unknownOptionRejected() {
    let result = ABPtoSafariConverter.convert("||tracker.example.com^$csp=script-src 'self'")
    #expect(result.rules.isEmpty)
  }

  @Test("realistic header-heavy block is parsed past the comments")
  func realisticHeader() {
    let text = """
      ! Checksum: abc
      ! Title: Test filter
      !
      !------ Ads ------!
      !
      ||ads1.example.com^$third-party
      ||ads2.example.com^$script
      example.com##.sidebar-ad
      """
    let result = ABPtoSafariConverter.convert(text)
    // Both `^` patterns fan out into 2 rules each, plus the cosmetic.
    #expect(result.rules.count == 5)
  }

  @Test("regex literal rule is skipped")
  func regexLiteralRule() {
    let result = ABPtoSafariConverter.convert(#"/^https?://ads\.[a-z]+\.com/"#)
    #expect(result.rules.isEmpty)
  }

  @Test("regex literal with options is skipped")
  func regexLiteralWithOptions() {
    let result = ABPtoSafariConverter.convert(
      "/ads/.*/$script,domain=example.com"
    )
    #expect(result.rules.isEmpty)
  }

  @Test("regex literal exception is skipped")
  func regexLiteralException() {
    let result = ABPtoSafariConverter.convert("@@/ads/.*/$document")
    #expect(result.rules.isEmpty)
  }

  @Test("match-case option is accepted and ignored")
  func matchCaseAccepted() {
    let rules = ABPtoSafariConverter.convert(
      "||example.com^$script,match-case"
    ).rules
    #expect(!rules.isEmpty)
    #expect(rules.allSatisfy { $0.trigger.resourceType == ["script"] })
  }

  @Test("sitekey option is accepted and ignored")
  func sitekeyAccepted() {
    let rules = ABPtoSafariConverter.convert(
      "||example.com^$script,sitekey=ABC123"
    ).rules
    #expect(!rules.isEmpty)
  }

  @Test("option split uses rightmost valid boundary; dollars stay in body")
  func optionSplitRightmost() {
    let rules = ABPtoSafariConverter.convert(
      "||example.com/a$b/c$script"
    ).rules
    #expect(!rules.isEmpty)
    #expect(rules[0].action.type == "block")
    #expect(rules[0].trigger.resourceType == ["script"])
    // The earlier `$` stays in the URL filter body, escaped.
    #expect(rules[0].trigger.urlFilter.contains("\\$b"))
  }

  @Test("unknown-option suffix does not steal the split point")
  func unknownOptionSuffixKeepsSplit() {
    // The first `$script,image` suffix is a plausible option list
    // and must be taken as the split even though an earlier `$`
    // appears in the URL body.
    let rules = ABPtoSafariConverter.convert(
      "||example.com/a$b/c$script,image"
    ).rules
    #expect(!rules.isEmpty)
    let types = Set(rules[0].trigger.resourceType ?? [])
    #expect(types == Set(["script", "image"]))
    #expect(rules[0].trigger.urlFilter.contains("\\$b"))
  }

  // MARK: - uBO option boundary detection

  @Test("uBO $redirect= suffix is treated as option boundary, rule drops cleanly")
  func uboRedirectBoundary() {
    // Without the boundary recognising `redirect=`, the entire body
    // (including `domain=a|b`) would be emitted as a url-filter regex
    // and WebKit's compiler would reject the `|` disjunction. With
    // the boundary detected, `convertNetwork` drops the rule because
    // `redirect=` is not in `recognizedOptions`, and nothing reaches
    // WebKit at all.
    let result = ABPtoSafariConverter.convert(
      "||ads.example.com/ima3.js$script,domain=a.example|b.example,redirect=noop.js"
    )
    #expect(result.rules.isEmpty)
    #expect(result.skipped == 1)
  }

  @Test("uBO $denyallow= suffix is treated as option boundary")
  func uboDenyallowBoundary() {
    let result = ABPtoSafariConverter.convert(
      "||example.com^$script,denyallow=cdn.example|static.example,domain=foo.example"
    )
    #expect(result.rules.isEmpty)
    #expect(result.skipped == 1)
  }

  @Test("$important / $generichide bare options are recognised at the boundary")
  func bareUnsupportedOptionsBoundary() {
    let importantRule = ABPtoSafariConverter.convert(
      "||example.com^$important,domain=a.com|b.com"
    )
    #expect(importantRule.rules.isEmpty)
    #expect(importantRule.skipped == 1)

    let generichideRule = ABPtoSafariConverter.convert(
      ".*$generichide,domain=site.example|other.example"
    )
    #expect(generichideRule.rules.isEmpty)
    #expect(generichideRule.skipped == 1)
  }

  @Test("bare tolerable options ($removeparam, $cookie) hit the boundary")
  func bareTolerableOptionsBoundary() {
    // Both `removeparam` and `cookie` live in the bare option set so
    // the suffix qualifies as an option list. The rule itself drops
    // because neither is implemented in `recognizedOptions`. The
    // assertion ensures the suffix is taken as options rather than
    // being swallowed into a url-filter regex (which would carry the
    // `|` disjunction through to WebKit).
    let removeparam = ABPtoSafariConverter.convert(
      "||example.com^$removeparam,domain=a.com|b.com"
    )
    #expect(removeparam.rules.isEmpty)
    #expect(removeparam.skipped == 1)

    let cookie = ABPtoSafariConverter.convert(
      "||example.com^$cookie,domain=a.com|b.com"
    )
    #expect(cookie.rules.isEmpty)
    #expect(cookie.skipped == 1)
  }
}
