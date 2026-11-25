/// Phone side: picks which path (LAN, AWDL, tailnet) carries the hot traffic.
///
/// Every path is probed about once a second; the hot path is the live one with
/// the lowest smoothed RTT. A path stays chosen until another is clearly
/// faster, so jitter does not flap between two similar paths.
public struct PathPicker: Sendable {
  struct Stat { var srtt: Double; var lastReply: Double; var samples = 1 }

  /// A path with no reply for this long is dead.
  public static let deadAfter = 2.5
  /// Switch only when the other path is this much faster (ratio and absolute).
  public static let switchRatio = 0.7
  public static let switchMargin = 0.003

  private var stats: [String: Stat] = [:]
  public private(set) var active: String?

  public init() {}

  public mutating func replied(path: String, rtt: Double, now: Double) {
    if var s = stats[path] {
      // The first reply includes flow setup (Bonjour resolve, AWDL wake-up);
      // let the second sample replace it instead of averaging it in.
      s.srtt = s.samples == 1 ? rtt : 0.8 * s.srtt + 0.2 * rtt
      s.samples += 1
      s.lastReply = now
      stats[path] = s
    } else {
      stats[path] = Stat(srtt: rtt, lastReply: now)
    }
    choose(now: now)
  }

  public mutating func remove(path: String) {
    stats[path] = nil
    if active == path { active = nil }
  }

  public func rtt(of path: String) -> Double? { stats[path]?.srtt }

  @discardableResult
  public mutating func choose(now: Double) -> String? {
    let alive = stats.filter { now - $0.value.lastReply <= Self.deadAfter }
    guard let best = alive.min(by: { $0.value.srtt < $1.value.srtt }) else {
      active = nil
      return nil
    }
    if let current = active, let c = alive[current] {
      let clearlyBetter = best.value.srtt < c.srtt * Self.switchRatio
        && c.srtt - best.value.srtt > Self.switchMargin
      if !clearlyBetter { return active }
    }
    active = best.key
    return active
  }
}
