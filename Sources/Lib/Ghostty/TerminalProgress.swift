import Foundation

/// What a terminal pane's loading bar shows.
struct TerminalProgress: Equatable {
  /// From 0 to 1; `nil` shuttles, for work with no measure.
  let fraction: Double?

  /// `nil` hides the bar. Blocked hides it too: the pane's row already
  /// says the program waits on the user.
  init?(status: ProgramStatusReport?) {
    guard let status, status.state == .working else { return nil }
    fraction = status.progress.map { Double($0) / 100 }
  }
}
