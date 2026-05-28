import Testing

@testable import E05Lib

@Suite("URLBarInlineCompletion")
struct URLBarInlineCompletionTests {
  @Test("completes a host the query is a prefix of")
  func basicHostCompletion() {
    #expect(
      URLBarInlineCompletion.hostSuffix(
        forQuery: "kaw", candidateURL: "https://kawarimidoll.com/") == "arimidoll.com")
  }

  @Test("strips a leading www for matching")
  func wwwStrip() {
    #expect(
      URLBarInlineCompletion.hostSuffix(
        forQuery: "exa", candidateURL: "https://www.example.com/") == "mple.com")
  }

  @Test("preserves host case in the suffix")
  func preservesCase() {
    #expect(
      URLBarInlineCompletion.hostSuffix(
        forQuery: "git", candidateURL: "https://GitHub.com/x") == "Hub.com")
  }

  @Test("no completion once a slash, scheme, or space is typed")
  func bailsOnExplicitNavigation() {
    #expect(
      URLBarInlineCompletion.hostSuffix(
        forQuery: "github.com/k", candidateURL: "https://github.com/kawarimidoll") == nil)
    #expect(
      URLBarInlineCompletion.hostSuffix(
        forQuery: "https://ka", candidateURL: "https://kawarimidoll.com/") == nil)
    #expect(
      URLBarInlineCompletion.hostSuffix(
        forQuery: "hello world", candidateURL: "https://example.com/") == nil)
  }

  @Test("no completion when the host doesn't strictly extend the query")
  func noStrictExtension() {
    // Exact host: nothing left to complete.
    #expect(
      URLBarInlineCompletion.hostSuffix(
        forQuery: "kawarimidoll.com", candidateURL: "https://kawarimidoll.com/") == nil)
    // Query not a prefix of the host.
    #expect(
      URLBarInlineCompletion.hostSuffix(
        forQuery: "xyz", candidateURL: "https://kawarimidoll.com/") == nil)
  }

  @Test("empty or whitespace query yields no completion")
  func emptyQuery() {
    #expect(
      URLBarInlineCompletion.hostSuffix(
        forQuery: "", candidateURL: "https://kawarimidoll.com/") == nil)
    #expect(
      URLBarInlineCompletion.hostSuffix(
        forQuery: "   ", candidateURL: "https://kawarimidoll.com/") == nil)
  }

  @Test("non-host candidate yields no completion")
  func nonHostCandidate() {
    #expect(URLBarInlineCompletion.hostSuffix(forQuery: "ab", candidateURL: "about:blank") == nil)
  }
}
