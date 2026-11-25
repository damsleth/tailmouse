import Foundation

/// The glide after a two-finger scroll, as on a Mac trackpad. Pure, so the
/// physics is testable; the Mac's `Input` drives it from a 120 Hz timer.
public struct Momentum: Sendable {
  /// Time constant in seconds: the speed falls as e^(-t/tau). 0 is off.
  public var tau: Double
  private var samples: [(t: Double, dx: Double, dy: Double)] = []
  public private(set) var velocity = (x: 0.0, y: 0.0)

  /// A flick slower than this doesn't glide; the glide ends below `stopSpeed`.
  static let startSpeed = 150.0, stopSpeed = 20.0, maxSpeed = 12_000.0

  public init(tau: Double) { self.tau = tau }

  public mutating func record(t: Double, dx: Double, dy: Double) {
    samples.append((t, dx, dy))
    samples.removeAll { t - $0.t > 0.1 }
  }

  /// Fingers lifted at `t`. Takes the speed of the last 100 ms; fingers that
  /// stopped before lifting (nothing in the last 50 ms) don't glide.
  /// Returns whether a glide starts.
  public mutating func release(t: Double) -> Bool {
    defer { samples = [] }
    let recent = samples.filter { t - $0.t <= 0.1 }
    guard tau > 0, let first = recent.first, let last = recent.last, t - last.t <= 0.05 else { return false }
    // The first sample's delta covers time before it, so it is left out.
    let span = max(last.t - first.t, 1.0 / 120)
    let moved = recent.dropFirst().reduce((x: 0.0, y: 0.0)) { ($0.x + $1.dx, $0.y + $1.dy) }
    func clamp(_ v: Double) -> Double { max(-Self.maxSpeed, min(Self.maxSpeed, v)) }
    velocity = (clamp(moved.x / span), clamp(moved.y / span))
    return hypot(velocity.x, velocity.y) > Self.startSpeed
  }

  /// The distance to scroll over the next `dt` seconds, or nil when the glide is over.
  public mutating func step(dt: Double) -> (dx: Double, dy: Double)? {
    let decay = exp(-dt / tau)
    velocity = (velocity.x * decay, velocity.y * decay)
    guard hypot(velocity.x, velocity.y) >= Self.stopSpeed else { return nil }
    return (velocity.x * dt, velocity.y * dt)
  }
}
