/// Mac side: turns cumulative `Motion` totals into deltas to apply.
///
/// Idea from Entangle's PointerAccumulator (MIT, (c) 2026 Gabriel Donadel):
/// the phone sends the gesture's running total, the Mac applies
/// `total - lastApplied`. A lost packet is covered by the next one, a duplicate
/// or an older packet yields nothing.
public struct MotionTracker: Sendable {
  private var gesture: UInt32?
  private var applied = (x: 0.0, y: 0.0)

  public init() {}

  /// Returns the delta to apply, or nil when there is nothing new.
  /// `isNewGesture` is true on the first frame of a gesture.
  public mutating func resolve(_ m: Motion) -> (dx: Double, dy: Double, isNewGesture: Bool)? {
    var isNew = false
    if let g = gesture {
      // Signed distance handles wraparound; a negative one is an old gesture.
      let ahead = Int32(bitPattern: m.gesture &- g)
      if ahead < 0 { return nil }
      if ahead > 0 { isNew = true }
    } else {
      isNew = true
    }
    if isNew {
      gesture = m.gesture
      applied = (0, 0)
    }
    let dx = m.x - applied.x
    let dy = m.y - applied.y
    if dx == 0 && dy == 0 && !isNew { return nil }
    applied = (m.x, m.y)
    return (dx, dy, isNew)
  }
}
