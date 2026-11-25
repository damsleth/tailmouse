import Foundation

/// Wire format shared by the phone and the Mac.
///
/// One UDP socket carries everything. Each datagram is `header + sealed JSON`
/// (see `Seal`). Every client packet carries the latest pointer state
/// (`motion`, lossy, cumulative) plus every event the Mac has not acknowledged
/// yet (`events`, reliable, ordered). The Mac answers each packet with a `Reply`.
public enum Wire {
  public static let version: UInt8 = 1
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
public struct Packet: Codable, Equatable, Sendable {
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
  // Optional so a phone built before they existed still decodes.
  /// Stable per install, unlike `client`; keys the Mac's device list.
  public var device: UUID?
  /// The phone's name as the user set it in the app.
  public var name: String?
  /// The path the phone sends hot traffic on ("AWDL", "LAN", "Tailnet").
  public var via: String?
  /// Required to start a session when the Mac has a PIN set.
  public var pin: String?

  public init(client: UInt64, session: UInt64, time: Double, motion: Motion? = nil, events: [Sequenced] = [],
              device: UUID? = nil, name: String? = nil, via: String? = nil, pin: String? = nil) {
    self.client = client
    self.session = session
    self.time = time
    self.motion = motion
    self.events = events
    self.device = device
    self.name = name
    self.via = via
    self.pin = pin
  }
}

/// Mac → phone.
public struct Reply: Codable, Equatable, Sendable {
  public var session: UInt64
  /// Highest event seq delivered, in order.
  public var ack: UInt32
  /// The `time` of the packet this answers.
  public var echo: Double
  public var name: String
  /// Set when the Mac wants a PIN before it starts a session (`session` is 0).
  public var pin: PinStatus?

  public enum PinStatus: String, Codable, Sendable { case required, wrong }

  public init(session: UInt64, ack: UInt32, echo: Double, name: String, pin: PinStatus? = nil) {
    self.session = session
    self.ack = ack
    self.echo = echo
    self.name = name
    self.pin = pin
  }
}

/// Running total of the current gesture. The Mac applies `total - lastApplied`,
/// so a lost, duplicated or late packet costs nothing.
public struct Motion: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case pointer, scroll }
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

public struct Sequenced: Codable, Equatable, Sendable {
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

public enum Button: String, Codable, Sendable { case left, right }

/// Modifier bitmask.
public struct Mods: OptionSet, Codable, Hashable, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let command = Mods(rawValue: 1)
  public static let option = Mods(rawValue: 2)
  public static let shift = Mods(rawValue: 4)
  public static let control = Mods(rawValue: 8)
}

/// Named non-character keys. Characters travel as `text`, or as `char` when a
/// modifier is held (⌘C has to be a key event, not inserted text).
public enum Key: String, Codable, CaseIterable, Sendable {
  case escape, tab, enter, backspace, forwardDelete
  case up, down, left, right, home, end, pageUp, pageDown
}

/// Reliable, ordered events. New cases go at the end; v2 reserves dock,
/// spaces, media and clipboard here.
public enum Event: Codable, Equatable, Sendable {
  case click(Button)
  case dragBegin
  case dragEnd
  case scrollBegin
  case scrollEnd
  case text(String)
  case key(Key, Mods)
  /// A character typed with modifiers, mapped to its key on the Mac.
  case char(Character, Mods)

  // Character isn't Codable; carry it as a one-character string.
  private enum CodingKeys: String, CodingKey { case t, s, k, m, b }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .click(let b): try c.encode("click", forKey: .t); try c.encode(b, forKey: .b)
    case .dragBegin: try c.encode("dragBegin", forKey: .t)
    case .dragEnd: try c.encode("dragEnd", forKey: .t)
    case .scrollBegin: try c.encode("scrollBegin", forKey: .t)
    case .scrollEnd: try c.encode("scrollEnd", forKey: .t)
    case .text(let s): try c.encode("text", forKey: .t); try c.encode(s, forKey: .s)
    case .key(let k, let m): try c.encode("key", forKey: .t); try c.encode(k, forKey: .k); try c.encode(m, forKey: .m)
    case .char(let ch, let m): try c.encode("char", forKey: .t); try c.encode(String(ch), forKey: .s); try c.encode(m, forKey: .m)
    }
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .t) {
    case "click": self = .click(try c.decode(Button.self, forKey: .b))
    case "dragBegin": self = .dragBegin
    case "dragEnd": self = .dragEnd
    case "scrollBegin": self = .scrollBegin
    case "scrollEnd": self = .scrollEnd
    case "text": self = .text(try c.decode(String.self, forKey: .s))
    case "key": self = .key(try c.decode(Key.self, forKey: .k), try c.decode(Mods.self, forKey: .m))
    case "char":
      let s = try c.decode(String.self, forKey: .s)
      guard let ch = s.first, s.count == 1 else {
        throw DecodingError.dataCorruptedError(forKey: .s, in: c, debugDescription: "char must be one character")
      }
      self = .char(ch, try c.decode(Mods.self, forKey: .m))
    case let other:
      throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "unknown event \(other)")
    }
  }
}
