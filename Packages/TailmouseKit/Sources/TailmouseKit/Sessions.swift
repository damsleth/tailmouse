import Foundation

/// Mac side of the protocol, minus sockets and CGEvents: decides what an
/// opened packet means. Pure, so `swift test` can throw lossy links at it.
public struct Sessions: Sendable {
  public enum Action: Equatable, Sendable {
    case move(dx: Double, dy: Double)
    case scroll(dx: Double, dy: Double, isNewGesture: Bool)
    /// Drawing mode: put the cursor at this point of the drawing area (0…1).
    case place(x: Double, y: Double)
    case event(Event)
  }

  struct Session {
    var id: UInt64
    var inbox = Inbox()
    var pointer = MotionTracker()
    var scroll = MotionTracker()
    /// The last drawing position applied. The phone repeats its latest motion
    /// in every packet, probes included; a total absorbs that, a position
    /// would pull the cursor back once a second.
    var placed: Motion?
    var lastSeen: TimeInterval
    /// Newest `Packet.time` seen. Motion from an older packet is dropped: a
    /// slow path (tailnet via DERP) would otherwise drag the cursor back.
    var newest = -Double.infinity
    /// Smallest `now - Packet.time` seen: transit time plus the clock offset.
    /// A packet whose delay exceeds it by more than `Wire.eventMaxAge` was held
    /// back (or replayed) and is ignored, judged by the Mac's own clock.
    var minDelay: Double
  }

  private var table: [UInt64: Session] = [:]
  public let name: String

  /// Width over height of the drawing area, told to the phone in every reply.
  public var aspect: Double?

  public init(name: String) { self.name = name }

  public var activeClients: Int { table.count }

  /// - Parameter newID: source of fresh session ids (random in production).
  public mutating func receive(
    _ p: Packet, now: TimeInterval, newID: () -> UInt64 = { UInt64.random(in: 1...UInt64.max) }
  ) -> (Reply, [Action]) {
    // `client` is random per app launch, so a relaunched phone is a new client
    // and its numbering starts fresh; the old session just times out.
    guard var s = table[p.client] else {
      // First contact, or the Mac restarted. Nothing in this packet runs:
      // it was not sealed under a session we issued, so it may be a replay.
      let s = Session(id: newID(), lastSeen: now, minDelay: now - p.time)
      table[p.client] = s
      return (reply(s, p), [])
    }
    guard p.session == s.id else { return (reply(s, p), []) }
    let delay = now - p.time
    s.minDelay = min(s.minDelay, delay)
    guard delay - s.minDelay <= Wire.eventMaxAge else {
      // Late by the Mac's clock: nothing runs and the session is not kept
      // alive, so held-back traffic can't fire later. Its events are resent
      // in fresh packets, where the age filter below drops all but releases.
      table[p.client] = s
      return (reply(s, p), [])
    }
    s.lastSeen = now
    var actions: [Action] = []
    let fresh = p.time >= s.newest
    s.newest = max(s.newest, p.time)
    // Motion first, so a click lands where the latest total put the cursor.
    // A real gesture total stays far below this; the bound keeps the Mac's
    // integer conversions safe from a malformed packet.
    if let m = p.motion, fresh, m.x.isFinite, m.y.isFinite, abs(m.x) < 1e7, abs(m.y) < 1e7 {
      switch m.kind {
      case .pointer:
        if let d = s.pointer.resolve(m) { actions.append(.move(dx: d.dx, dy: d.dy)) }
      case .scroll:
        if let d = s.scroll.resolve(m) { actions.append(.scroll(dx: d.dx, dy: d.dy, isNewGesture: d.isNewGesture)) }
      case .tablet:
        if m != s.placed, (0...1).contains(m.x), (0...1).contains(m.y) {
          // A new stroke whose predecessor's `dragEnd` is still on its way
          // (lost, or dropped by a latest-wins link): lift first, or the jump
          // to the new start draws a line.
          if let last = s.placed, last.gesture != m.gesture { actions.append(.event(.dragEnd)) }
          s.placed = m
          actions.append(.place(x: m.x, y: m.y))
        }
      }
    }
    actions += s.inbox.accept(p.events)
      // Releases always run, however late, or a stale drag-end leaves the button down.
      .filter { p.time - $0.time <= Wire.eventMaxAge || $0.event == .dragEnd || $0.event == .scrollEnd }
      .map { .event($0.event) }
    table[p.client] = s
    return (reply(s, p), actions)
  }

  /// Drops sessions silent for longer than `Wire.sessionTimeout`.
  /// Returns true when any were dropped, so the caller can release held input.
  public mutating func expire(now: TimeInterval) -> Bool {
    let before = table.count
    table = table.filter { now - $0.value.lastSeen <= Wire.sessionTimeout }
    return table.count != before
  }

  private func reply(_ s: Session, _ p: Packet) -> Reply {
    Reply(session: s.id, ack: s.inbox.delivered, echo: p.time, name: name, aspect: aspect)
  }
}
