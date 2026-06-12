import Foundation
import Testing

@testable import E05Lib

@Suite("Suspend sweep")
struct SuspendSweepTests {
  @Test(
    "loopback hosts are spared",
    arguments: [
      "localhost", "LOCALHOST", "app.localhost", "Dev.Localhost",
      "127.0.0.1", "127.1.2.3", "127.255.255.255", "::1", "[::1]",
    ])
  func loopbackMatches(host: String) {
    #expect(PaneContainerViewController.isLoopbackHost(host))
  }

  @Test(
    "public and LAN hosts are not spared",
    arguments: [
      "example.com", "youtube.com", "localhost.example.com",
      "notlocalhost", "192.168.1.1", "10.0.0.1", "1.2.3.4",
      // `127.`-prefixed names that aren't dotted-decimal IPv4 literals.
      "127.example.com", "127.0.0.1.evil.com", "127.foo", "127.0.0.256",
    ])
  func nonLoopback(host: String) {
    #expect(!PaneContainerViewController.isLoopbackHost(host))
  }
}

@Suite("Suspend sweep cutoff")
struct SuspendSweepCutoffTests {
  // Fixed reference instant so the maths is deterministic.
  let now = Date(timeIntervalSince1970: 1_000_000)

  @Test("idle honours the configured threshold")
  func idleThreshold() {
    let c = PaneContainerViewController.sweepCutoff(trigger: .idle, idleMinutes: 60, now: now)
    #expect(c == .idleSince(now.addingTimeInterval(-3600)))
  }

  @Test(
    "a disabled idle threshold skips the idle sweep",
    arguments: [0, -5])
  func idleDisabled(minutes: Int) {
    let c = PaneContainerViewController.sweepCutoff(trigger: .idle, idleMinutes: minutes, now: now)
    #expect(c == .disabled)
  }

  @Test("warning honours a tighter idle threshold than the grace floor")
  func warningHonoursTightIdle() {
    // idle 1 min < 5 min grace → warning must not be *less* aggressive.
    let c = PaneContainerViewController.sweepCutoff(
      trigger: .memoryWarning, idleMinutes: 1, now: now)
    #expect(c == .idleSince(now.addingTimeInterval(-60)))
  }

  @Test("warning uses the grace floor under a loose idle threshold")
  func warningUsesGrace() {
    // idle 60 min > 5 min grace → warning clamps to the 5 min floor.
    let c = PaneContainerViewController.sweepCutoff(
      trigger: .memoryWarning, idleMinutes: 60, now: now)
    #expect(c == .idleSince(now.addingTimeInterval(-300)))
  }

  @Test("warning still runs on the grace floor when idle is disabled")
  func warningGraceWhenIdleDisabled() {
    let c = PaneContainerViewController.sweepCutoff(
      trigger: .memoryWarning, idleMinutes: 0, now: now)
    #expect(c == .idleSince(now.addingTimeInterval(-300)))
  }

  @Test("critical bypasses the age gate entirely")
  func criticalAll() {
    let c = PaneContainerViewController.sweepCutoff(
      trigger: .memoryCritical, idleMinutes: 60, now: now)
    #expect(c == .all)
  }
}

@Suite("Suspend sweep decision")
struct SuspendSweepDecisionTests {
  let now = Date(timeIntervalSince1970: 1_000_000)
  /// Idle gate one hour back; `stale`/`fresh` straddle it.
  var hourGate: PaneContainerViewController.SweepCutoff {
    .idleSince(now.addingTimeInterval(-3600))
  }
  var stale: Date { now.addingTimeInterval(-7200) }  // 2h ago, past the gate
  var fresh: Date { now.addingTimeInterval(-60) }  // 1m ago, within the gate

  func decide(
    canSuspend: Bool = true,
    isFocused: Bool = false,
    isSuspendExempt: Bool = false,
    isPlayingMedia: Bool = false,
    host: String? = nil,
    isHostExempt: Bool = false,
    lastActiveAt: Date,
    cutoff: PaneContainerViewController.SweepCutoff
  ) -> PaneContainerViewController.SweepDecision {
    PaneContainerViewController.sweepDecision(
      canSuspend: canSuspend, isFocused: isFocused, isSuspendExempt: isSuspendExempt,
      isPlayingMedia: isPlayingMedia, host: host, isHostExempt: isHostExempt,
      lastActiveAt: lastActiveAt, cutoff: cutoff)
  }

  @Test("a stale, unprotected pane suspends")
  func staleSuspends() {
    #expect(decide(lastActiveAt: stale, cutoff: hourGate) == .suspend)
  }

  @Test("a pane active within the gate is kept")
  func freshKept() {
    // The focus-loss regression: a pane just defocused (clock heartbeated
    // to ~now) is within the gate and must survive the next sweep.
    #expect(decide(lastActiveAt: fresh, cutoff: hourGate) == .keep)
  }

  @Test("a focused pane refreshes its clock instead of suspending")
  func focusedRefreshes() {
    // Even with a long-stale clock, focus refreshes rather than reclaims.
    #expect(decide(isFocused: true, lastActiveAt: stale, cutoff: hourGate) == .refreshFocusClock)
  }

  @Test("media / per-pane exempt / host-exempt / loopback keep a stale pane")
  func protectedKept() {
    #expect(decide(isPlayingMedia: true, lastActiveAt: stale, cutoff: hourGate) == .keep)
    #expect(decide(isSuspendExempt: true, lastActiveAt: stale, cutoff: hourGate) == .keep)
    #expect(
      decide(host: "ex.com", isHostExempt: true, lastActiveAt: stale, cutoff: hourGate) == .keep)
    #expect(decide(host: "localhost", lastActiveAt: stale, cutoff: hourGate) == .keep)
  }

  @Test("an unsuspendable pane is kept")
  func unsuspendableKept() {
    #expect(decide(canSuspend: false, lastActiveAt: stale, cutoff: hourGate) == .keep)
  }

  @Test("critical reclaims a fresh, unprotected pane but still spares focus")
  func criticalIgnoresAge() {
    #expect(decide(lastActiveAt: fresh, cutoff: .all) == .suspend)
    #expect(decide(isFocused: true, lastActiveAt: fresh, cutoff: .all) == .refreshFocusClock)
    #expect(decide(isPlayingMedia: true, lastActiveAt: fresh, cutoff: .all) == .keep)
  }
}
