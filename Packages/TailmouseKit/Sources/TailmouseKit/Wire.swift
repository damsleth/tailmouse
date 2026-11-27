import Foundation

/// Wire format shared by the phone and the Mac.
///
/// One UDP socket carries everything. Each datagram is `header + sealed bytes`
/// (see `Seal`); the bytes are the binary layouts at the end of this file. Every client packet carries the latest pointer state
/// (`motion`, lossy, cumulative) plus every event the Mac has not acknowledged
/// yet (`events`, reliable, ordered). The Mac answers each packet with a `Reply`.
public enum Wire {
  public static let version: UInt8 = 4
  public static let defaultPort: UInt16 = 47474
  public static let bonjourType = "_tailmouse._udp"
  /// The Mac drops a session (and releases held buttons) after this much silence.
  public static let sessionTimeout: TimeInterval = 3
  /// The phone sends at least this often, so the session stays alive.
  public static let keepalive: TimeInterval = 1
  /// An event that took longer than this to get through (no path, failover)
  /// is consumed without running: a click or keystroke must never fire late.
  public static let eventMaxAge: TimeInterval = 1
}

/// Phone → Mac.
public struct Packet: Equatable, Sendable {
  /// Random per app launch; keys the Mac's session table. Shared by every
  /// path, so switching between LAN, AWDL and tailnet keeps the session.
  public var client: UInt64
  /// Server-chosen. 0 until the first `Reply`. A packet with a stale session
  /// is answered with the current one and its events are ignored, so a
  /// replayed packet from an old session can never run again.
  public var session: UInt64
  /// Phone clock, echoed in the reply for RTT.
  public var time: Double
  public var motion: Motion?
  public var events: [Sequenced]
  // These ride on hellos and probes only; pointer packets leave them out.
  // Which phone it is, the key that opens the packet says.
  /// What the phone calls itself: "iPhone", since iOS 16. The Mac prefers the
  /// host name it finds for the phone's address.
  public var name: String?
  /// The path the phone sends hot traffic on ("USB", "LAN", "AWDL", "Tailnet", "BLE").
  public var via: String?

  public init(client: UInt64, session: UInt64, time: Double, motion: Motion? = nil, events: [Sequenced] = [],
              name: String? = nil, via: String? = nil) {
    self.client = client
    self.session = session
    self.time = time
    self.motion = motion
    self.events = events
    self.name = name
    self.via = via
  }
}

/// Mac → phone.
public struct Reply: Equatable, Sendable {
  public var session: UInt64
  /// Highest event seq delivered, in order.
  public var ack: UInt32
  /// The `time` of the packet this answers.
  public var echo: Double
  public var name: String
  /// Width over height of the Mac's drawing area, so the phone can shape its
  /// surface to match and a circle stays a circle.
  public var aspect: Double?

  public init(session: UInt64, ack: UInt32, echo: Double, name: String, aspect: Double? = nil) {
    self.session = session
    self.ack = ack
    self.echo = echo
    self.name = name
    self.aspect = aspect
  }
}

/// Running total of the current gesture. The Mac applies `total - lastApplied`,
/// so a lost, duplicated or late packet costs nothing.
///
/// `tablet` is the drawing mode: `x` and `y` are a position in the Mac's
/// drawing area, 0…1 from its top-left corner, and `gesture` counts strokes.
public struct Motion: Equatable, Sendable {
  public enum Kind: Sendable { case pointer, scroll, tablet }
  public var kind: Kind
  /// Gesture counter; a new value starts the total from zero.
  public var gesture: UInt32
  public var x: Double
  public var y: Double

  public init(kind: Kind, gesture: UInt32, x: Double, y: Double) {
    self.kind = kind
    self.gesture = gesture
    self.x = x
    self.y = y
  }
}

public struct Sequenced: Equatable, Sendable {
  public var seq: UInt32
  /// Phone clock when the finger made it; compared with `Packet.time`.
  public var time: Double
  public var event: Event

  public init(seq: UInt32, time: Double, event: Event) {
    self.seq = seq
    self.time = time
    self.event = event
  }
}

public enum Button: UInt8, Sendable { case left, right }

/// Modifier bitmask.
public struct Mods: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let command = Mods(rawValue: 1)
  public static let option = Mods(rawValue: 2)
  public static let shift = Mods(rawValue: 4)
  public static let control = Mods(rawValue: 8)
}

/// Named non-character keys. Characters travel as `text`, or as `char` when a
/// modifier is held (⌘C has to be a key event, not inserted text).
/// The raw value is the wire byte: new keys go at the end.
public enum Key: UInt8, CaseIterable, Sendable {
  case escape, tab, enter, backspace, forwardDelete
  case up, down, left, right, home, end, pageUp, pageDown
}

/// Reliable, ordered events. The wire tag is the case's position: new cases go
/// at the end; v2 reserves dock, spaces, media and clipboard here.
public enum Event: Equatable, Sendable {
  case click(Button)
  case dragBegin
  case dragEnd
  case scrollBegin
  case scrollEnd
  case text(String)
  case key(Key, Mods)
  /// A character typed with modifiers, mapped to its key on the Mac.
  case char(Character, Mods)
}

// MARK: - Binary layout
//
// Big-endian. Strings are a UInt16 byte count and UTF-8. A pointer packet is
// 46 bytes before sealing; as JSON it was about 170.
//
// Packet: flags | client u64 | session u64 | time f64
//         | [gesture u32, x f64, y f64] | [name] | [via]
//         | event count u8 | events: seq u32, time f64, tag u8, payload
// Reply:  session u64 | ack u32 | echo f64 | name | [aspect f64]
//
// A decoder ignores bytes after the last field it knows, so a new optional
// field goes at the end: behind a new flag bit in `Packet`, bare in `Reply`.

/// What `Seal` carries.
public protocol WireCoded {
  var wire: Data { get }
  init?(wire: Data)
}

extension Packet: WireCoded {
  private enum Flag { static let motion: UInt8 = 1, scroll: UInt8 = 2, name: UInt8 = 8, via: UInt8 = 16, tablet: UInt8 = 64 }
  /// More unacked events than this wait for the next packet (`Outbox` holds fewer).
  static let maxEvents = 255

  public var wire: Data {
    var w = Data(capacity: 64)
    var flags: UInt8 = 0
    if let motion { flags |= Flag.motion | (motion.kind == .scroll ? Flag.scroll : 0) | (motion.kind == .tablet ? Flag.tablet : 0) }
    if name != nil { flags |= Flag.name }
    if via != nil { flags |= Flag.via }
    w.put(flags); w.put(client); w.put(session); w.put(time)
    if let motion { w.put(motion.gesture); w.put(motion.x); w.put(motion.y) }
    if let name { w.put(name) }
    if let via { w.put(via) }
    let events = events.prefix(Self.maxEvents)
    w.put(UInt8(events.count))
    for e in events {
      w.put(e.seq); w.put(e.time)
      switch e.event {
      case .click(let b): w.put(UInt8(0)); w.put(b.rawValue)
      case .dragBegin: w.put(UInt8(1))
      case .dragEnd: w.put(UInt8(2))
      case .scrollBegin: w.put(UInt8(3))
      case .scrollEnd: w.put(UInt8(4))
      case .text(let s): w.put(UInt8(5)); w.put(s)
      case .key(let k, let m): w.put(UInt8(6)); w.put(k.rawValue); w.put(m.rawValue)
      case .char(let c, let m): w.put(UInt8(7)); w.put(String(c)); w.put(m.rawValue)
      }
    }
    return w
  }

  public init?(wire: Data) {
    var r = Reader(wire)
    guard let flags = r.u8(), let client = r.u64(), let session = r.u64(), let time = r.f64() else { return nil }
    self.init(client: client, session: session, time: time)
    if flags & Flag.motion != 0 {
      guard let g = r.u32(), let x = r.f64(), let y = r.f64() else { return nil }
      motion = Motion(kind: flags & Flag.tablet != 0 ? .tablet : flags & Flag.scroll != 0 ? .scroll : .pointer, gesture: g, x: x, y: y)
    }
    if flags & Flag.name != 0 { guard let s = r.string() else { return nil }; name = s }
    if flags & Flag.via != 0 { guard let s = r.string() else { return nil }; via = s }
    guard let count = r.u8() else { return nil }
    for _ in 0..<count {
      guard let seq = r.u32(), let t = r.f64(), let tag = r.u8() else { return nil }
      let event: Event
      switch tag {
      case 0: guard let b = r.u8().flatMap(Button.init) else { return nil }; event = .click(b)
      case 1: event = .dragBegin
      case 2: event = .dragEnd
      case 3: event = .scrollBegin
      case 4: event = .scrollEnd
      case 5: guard let s = r.string() else { return nil }; event = .text(s)
      case 6:
        guard let k = r.u8().flatMap(Key.init), let m = r.u8() else { return nil }
        event = .key(k, Mods(rawValue: m))
      case 7:
        guard let s = r.string(), s.count == 1, let m = r.u8() else { return nil }
        event = .char(s.first!, Mods(rawValue: m))
      default: return nil
      }
      events.append(Sequenced(seq: seq, time: t, event: event))
    }
  }
}

extension Reply: WireCoded {
  public var wire: Data {
    var w = Data(capacity: 40)
    w.put(session); w.put(ack); w.put(echo); w.put(name)
    if let aspect { w.put(aspect) }
    return w
  }

  public init?(wire: Data) {
    var r = Reader(wire)
    guard let session = r.u64(), let ack = r.u32(), let echo = r.f64(), let name = r.string() else { return nil }
    self.init(session: session, ack: ack, echo: echo, name: name,
              aspect: r.isEmpty ? nil : r.f64())
  }
}

private extension Data {
  mutating func put<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
  mutating func put(_ v: Double) { put(v.bitPattern) }
  /// Longer than a UInt16 can count: cut, on a character boundary.
  mutating func put(_ s: String) {
    var s = s
    while s.utf8.count > Int(UInt16.max) { s.removeLast(Swift.max(1, s.count / 8)) }
    put(UInt16(s.utf8.count)); append(contentsOf: s.utf8)
  }
}

/// Every read is bounds-checked and returns nil past the end: the bytes come
/// off the network, sealed or not.
private struct Reader {
  private var data: Data
  init(_ data: Data) { self.data = data }
  var isEmpty: Bool { data.isEmpty }

  mutating func bytes(_ n: Int) -> Data? {
    guard data.count >= n else { return nil }
    defer { data = data.dropFirst(n) }
    return Data(data.prefix(n))
  }
  private mutating func int<T: FixedWidthInteger>(_: T.Type) -> T? {
    bytes(MemoryLayout<T>.size)?.reduce(0) { $0 << 8 | T($1) }
  }
  mutating func u8() -> UInt8? { int(UInt8.self) }
  mutating func u32() -> UInt32? { int(UInt32.self) }
  mutating func u64() -> UInt64? { int(UInt64.self) }
  /// NaN and infinity never come from an honest phone and poison comparisons.
  mutating func f64() -> Double? {
    guard let v = u64().map(Double.init(bitPattern:)), v.isFinite else { return nil }
    return v
  }
  mutating func string() -> String? {
    guard let n = int(UInt16.self), let b = bytes(Int(n)) else { return nil }
    return String(data: b, encoding: .utf8)
  }
}
