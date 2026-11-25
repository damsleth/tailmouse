/// Phone side of the reliable channel: numbers events and keeps them until acked.
///
/// Every outgoing packet carries the whole unacked window, so a lost packet is
/// repaired by the next one. Go-back-N without timers: the caller just sends
/// often enough (on touch, on keypress, and on a short resend tick while
/// `pending` is non-empty).
public struct Outbox: Sendable {
  public private(set) var pending: [Sequenced] = []
  private var nextSeq: UInt32 = 1
  /// Bounds packet size if the Mac stops answering. New events are refused
  /// rather than old ones dropped: dropping a numbered event leaves a gap the
  /// Mac would wait on forever. They would be too old to run anyway.
  public static let window = 64

  public init() {}

  public mutating func push(_ event: Event, time: Double) {
    guard pending.count < Self.window else { return }
    pending.append(Sequenced(seq: nextSeq, time: time, event: event))
    nextSeq &+= 1
  }

  public mutating func ack(_ seq: UInt32) {
    pending.removeAll { $0.seq <= seq }
  }

  /// A new session starts numbering from 1; unacked events go with it.
  public mutating func restart() {
    nextSeq = 1
    for i in pending.indices {
      pending[i].seq = nextSeq
      nextSeq &+= 1
    }
  }
}

/// Mac side: delivers each event once, in order, stopping at the first gap.
public struct Inbox: Sendable {
  public private(set) var delivered: UInt32 = 0

  public init() {}

  public mutating func accept(_ events: [Sequenced]) -> [Sequenced] {
    var out: [Sequenced] = []
    for item in events.sorted(by: { $0.seq < $1.seq }) {
      if item.seq <= delivered { continue }
      if item.seq != delivered &+ 1 { break }
      out.append(item)
      delivered = item.seq
    }
    return out
  }
}
