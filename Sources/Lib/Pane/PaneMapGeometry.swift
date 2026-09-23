import Foundation

/// The maths behind the pane map: where a shrunk pane lands on screen,
/// and which pane an arrow key moves to. No AppKit, so the rules can be
/// checked without a window.
enum PaneMapGeometry {
  /// One pane's place in the map. `rect` is in the coordinate space the
  /// map shrinks — the container's, where every workspace row starts at
  /// the same leading edge.
  struct Slot: Equatable {
    let workspace: Int
    let column: Int
    let pane: Int
    let rect: CGRect
  }

  enum Direction {
    case left
    case right
    case up
    case down
  }

  /// Everything shrinks by `scale` around `center`, and `center` lands on
  /// `target` — the zoom the map opens and closes with, and the clamp
  /// that keeps a panned map against the window.
  static func project(
    _ point: CGPoint, scale: CGFloat, center: CGPoint, target: CGPoint
  ) -> CGPoint {
    CGPoint(
      x: scale * (point.x - center.x) + target.x,
      y: scale * (point.y - center.y) + target.y)
  }

  static func project(
    _ rect: CGRect, scale: CGFloat, center: CGPoint, target: CGPoint
  ) -> CGRect {
    CGRect(
      origin: project(rect.origin, scale: scale, center: center, target: target),
      size: CGSize(width: rect.width * scale, height: rect.height * scale))
  }

  /// Keep a panned map against the window: one larger than the viewport
  /// can be pushed until the edge being pulled away from meets the
  /// viewport's, and a smaller one stays inside it altogether. Without
  /// this, scrolling would let the panes leave the window entirely.
  ///
  /// `box` is the whole map in the same space as `center` — the union of
  /// the workspace rows — and the answer is the target that puts it back
  /// in bounds, which is the one to camera with.
  static func clampedTarget(
    _ target: CGPoint,
    box: CGRect,
    scale: CGFloat,
    center: CGPoint,
    viewport: CGRect
  ) -> CGPoint {
    let projected = project(box, scale: scale, center: center, target: target)
    // The translation is the target, so a correction to the box is the
    // same correction to the target.
    func correction(
      min boxMin: CGFloat, max boxMax: CGFloat, viewMin: CGFloat, viewMax: CGFloat
    ) -> CGFloat {
      if boxMax - boxMin >= viewMax - viewMin {
        if boxMin > viewMin { return viewMin - boxMin }
        if boxMax < viewMax { return viewMax - boxMax }
      } else {
        if boxMin < viewMin { return viewMin - boxMin }
        if boxMax > viewMax { return viewMax - boxMax }
      }
      return 0
    }
    return CGPoint(
      x: target.x
        + correction(
          min: projected.minX, max: projected.maxX, viewMin: viewport.minX,
          viewMax: viewport.maxX),
      y: target.y
        + correction(
          min: projected.minY, max: projected.maxY, viewMin: viewport.minY,
          viewMax: viewport.maxY))
  }

  /// The pane an arrow key moves to, or `nil` at the edge of the map.
  ///
  /// Left and right stay in their workspace and step one column over, so
  /// the end of a row is the end. **The step is to the next column on
  /// screen, not the next by index**: a pinned column sits at the row's
  /// leading edge whatever its place in the workspace, and on a map — where
  /// every column is in view at once — moving right past it and landing
  /// back at the far left is the kind of jump nobody can follow. Callers
  /// pass each workspace's columns in the order they are drawn.
  ///
  /// Up and down walk the column first and then carry on into the
  /// workspace above or below, which is how the rows are stacked. Where
  /// they land sideways is decided by overlap rather than by index — the
  /// column hands over the pane it shares the most height with, the next
  /// workspace the column it shares the most width with — so a move and
  /// its opposite come back to where they started. `preferring` breaks the
  /// tie a full-height pane facing an evenly split column produces: the
  /// pane that column was last on, keyed by the column's own index.
  ///
  /// `current` says which pane the move starts from; where it *is* comes
  /// from `slots`. The caller holds the selection across camera moves, so
  /// its own copy of the rect can be a whole pan out of date, and an
  /// overlap measured between that and a freshly read row would hand back
  /// the column a camera-shift away from the one in line.
  static func neighbor(
    of current: Slot,
    direction: Direction,
    in slots: [[[Slot]]],
    preferring: [[Int]]
  ) -> Slot? {
    guard let workspace = slots[safe: current.workspace],
      let position = workspace.firstIndex(where: { $0.contains { $0.column == current.column } })
    else { return nil }
    let rect = workspace[position].first { $0.pane == current.pane }?.rect ?? current.rect
    switch direction {
    case .left, .right:
      let index = position + (direction == .right ? 1 : -1)
      guard let sideways = workspace[safe: index], let landing = sideways.first else { return nil }
      let preferred = preferring[safe: current.workspace].flatMap { $0[safe: landing.column] } ?? 0
      return pane(in: sideways, facing: rect, preferring: preferred)
    case .up, .down:
      let step = direction == .down ? 1 : -1
      if let sibling = workspace[position].first(where: { $0.pane == current.pane + step }) {
        return sibling
      }
      guard let next = slots[safe: current.workspace + step],
        let landing = column(in: next, facing: rect)
      else { return nil }
      return direction == .down ? landing.first : landing.last
    }
  }

  /// The pane of `column` sharing the most height with `rect`.
  private static func pane(in column: [Slot], facing rect: CGRect, preferring: Int) -> Slot? {
    var best: Slot?
    var bestOverlap = -CGFloat.greatestFiniteMagnitude
    for slot in column {
      let overlap = min(rect.maxY, slot.rect.maxY) - max(rect.minY, slot.rect.minY)
      if overlap > bestOverlap + 0.5 {
        best = slot
        bestOverlap = overlap
      } else if abs(overlap - bestOverlap) <= 0.5, slot.pane == preferring {
        best = slot
      }
    }
    return best
  }

  /// The column of `workspace` sharing the most width with `rect`; the
  /// nearest one when nothing overlaps, so a short row still catches a
  /// move coming from beyond its end.
  private static func column(in workspace: [[Slot]], facing rect: CGRect) -> [Slot]? {
    var best: [Slot]?
    var bestKey = (-CGFloat.greatestFiniteMagnitude, -CGFloat.greatestFiniteMagnitude)
    for column in workspace {
      guard let first = column.first else { continue }
      let key = (
        min(rect.maxX, first.rect.maxX) - max(rect.minX, first.rect.minX),
        -abs(first.rect.midX - rect.midX)
      )
      if key > bestKey {
        best = column
        bestKey = key
      }
    }
    return best
  }
}
