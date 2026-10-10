import Foundation

/// One OSC 9;4 report, ConEmu's older way for a program to show how far
/// along it is. A report that removes the bar is `nil` instead.
struct ProgressReport: Equatable {
  enum State {
    case set, error, indeterminate, pause
  }

  let state: State
  /// From 0 to 100; `nil` when the report carries none.
  let progress: Int?
}

/// What a terminal pane's loading bar shows.
struct TerminalProgress: Equatable {
  enum Tone {
    case normal, error, paused
  }

  /// From 0 to 1; `nil` shuttles, for work with no measure.
  let fraction: Double?
  let tone: Tone
}

extension TerminalProgress {
  /// `nil` hides the bar. A program reporting through OSC 7501 owns it
  /// while working or blocked. Blocked hides it, since the pane's row
  /// already says the program waits on the user, even if the same
  /// program left an OSC 9;4 report up.
  init?(status: ProgramStatusReport?, report: ProgressReport?) {
    switch status?.state {
    case .working:
      self.init(percent: status?.progress, tone: .normal)
    case .blocked:
      return nil
    default:
      guard let report else { return nil }
      switch report.state {
      case .set: self.init(percent: report.progress, tone: .normal)
      case .indeterminate: self.init(percent: nil, tone: .normal)
      case .error: self.init(percent: report.progress, tone: .error)
      // Ghostty draws a pause with no percentage as a full bar.
      case .pause: self.init(percent: report.progress ?? 100, tone: .paused)
      }
    }
  }

  private init(percent: Int?, tone: Tone) {
    fraction = percent.map { Double($0) / 100 }
    self.tone = tone
  }
}
