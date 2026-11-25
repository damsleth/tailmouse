import Foundation

/// Mac side of the protocol, minus sockets and CGEvents: decides what an
/// opened packet means. Pure, so `swift test` can throw lossy links at it.
public struct Sessions: Sendable {
  public enum Action: Equatable, Sendable {
    case move(dx: Double, dy: Double)
    case scroll(dx: Double, dy: Double, isNewGesture: Bool)
    case event(Event)
  }

  struct Session {
    var id: UInt64
    var inbox = Inbox()
    var pointer = MotionTracker()
    var scroll = MotionTracker()
    var lastSeen: TimeInterval
    /// Newest `Packet.time` seen. Motion from an older packet is dropped: a
    /// slow path (tailnet via DERP) would otherwise drag the cursor back.
    var newest = -Double.infinity
  }

  private var table: [UInt64: Session] = [:]
  public let name: String

  /// The PIN a phone must send to start a session; nil means none. Changing it
  /// ends every session, so each phone has to present the new one.
  public var pin: String? {
    didSet { if pin != oldValue { table = [:]; wrongPins = [] } }
  }
  /// Distinct wrong PINs since the last right one. Counting distinct values
  /// bounds guessing; a phone repeating one stale PIN on every path counts once.
  private var wrongPins: Set<String> = []
  public static let maxWrongPins = 5
  /// Too many guesses: refuse every PIN until the caller makes a new key.
  public var pinLocked: Bool { wrongPins.count >= Self.maxWrongPins }

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
      if let pin, pinLocked || p.pin != pin {
        if let tried = p.pin, !pinLocked { wrongPins.insert(tried) }
        return (Reply(session: 0, ack: 0, echo: p.time, name: name, pin: p.pin == nil ? .required : .wrong), [])
      }
      wrongPins = []
      let s = Session(id: newID(), lastSeen: now)
      table[p.client] = s
      return (reply(s, p), [])
    }
    s.lastSeen = now
    guard p.session == s.id else {
      table[p.client] = s
      return (reply(s, p), [])
    }
    var actions: [Action] = []
    let fresh = p.time >= s.newest
    s.newest = max(s.newest, p.time)
    // Motion first, so a click lands where the latest total put the cursor.
    if let m = p.motion, fresh {
      switch m.kind {
      case .pointer:
        if let d = s.pointer.resolve(m) { actions.append(.move(dx: d.dx, dy: d.dy)) }
      case .scroll:
        if let d = s.scroll.resolve(m) { actions.append(.scroll(dx: d.dx, dy: d.dy, isNewGesture: d.isNewGesture)) }
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
    Reply(session: s.id, ack: s.inbox.delivered, echo: p.time, name: name)
  }
}
