import CryptoKit
import Foundation

/// The Mac's phones. Each has a key of its own, so the key that opens a
/// datagram says which phone sent it, and removing a phone deletes its key:
/// nothing it sends opens any more.
public struct Keyring: Sendable {
  /// Sessions are kept per phone, so one phone can't ask for another's
  /// session by sending its `Packet.client`.
  private struct Phone {
    var seal: Seal
    var sessions: Sessions
    /// The public key it paired with: the same phone pairing again has the same.
    var publicKey: Data?
  }
  private var phones: [String: Phone] = [:]
  /// The private half of the pairing code on screen. The first phone that
  /// claims it gets a key; the Mac then shows a new code.
  private var offered: (id: String, key: Seal.PairingKey)?
  private let name: String

  /// Width over height of the drawing area, told to every phone.
  public var aspect: Double? {
    didSet { for id in phones.keys { phones[id]!.sessions.aspect = aspect } }
  }

  /// - Parameter keys: per phone, its 32-byte key, then its public key if it
  ///   paired with one (what `Received.paired` gave).
  public init(name: String, keys: [String: Data] = [:]) {
    self.name = name
    for (id, key) in keys {
      if let seal = Seal(keyData: Data(key.prefix(32))) { add(id, seal, key.count == 64 ? Data(key.suffix(32)) : nil) }
    }
  }

  public var ids: Set<String> { Set(phones.keys) }

  private mutating func add(_ id: String, _ seal: Seal, _ publicKey: Data?) {
    var sessions = Sessions(name: name)
    sessions.aspect = aspect
    phones[id] = Phone(seal: seal, sessions: sessions, publicKey: publicKey)
  }

  /// Accept one new phone that claims this key's code; nil withdraws it.
  public mutating func offer(_ o: (id: String, key: Seal.PairingKey)?) { offered = o }

  public mutating func remove(_ id: String) { phones[id] = nil }

  public struct Received: Sendable {
    public var id: String
    public var packet: Packet
    public var reply: Reply
    /// The reply, sealed under that phone's key.
    public var datagram: Data?
    public var actions: [Sessions.Action]
    /// Set when this datagram used up the offered code: the phone's key and
    /// its public key, 64 bytes, to store and hand back to `init`.
    public var paired: Data?
  }

  /// nil when no key opens it: no reply, as for any stranger.
  // ponytail: tries every key, a few microseconds each. A key id in the
  // header if someone pairs dozens of phones.
  public mutating func receive(_ data: Data, now: TimeInterval) -> Received? {
    // A phone keeps claiming until it hears an answer, so a claim may come
    // from a phone that already has its key.
    let claim = Seal.claimed(data)
    let datagram = claim?.datagram ?? data
    var hit = phones.lazy.compactMap { id, p in p.seal.open(Packet.self, from: datagram).map { (id, $0) } }.first
    var paired: Data?
    if hit == nil, let claim, let o = offered,
       let key = Seal.agree(o.key, with: claim.phone, mac: o.key.publicKey.rawRepresentation, phone: claim.phone),
       let seal = Seal(keyData: key), let p = seal.open(Packet.self, from: datagram) {
      // It opens, so the sender worked out the key: it has seen the code and
      // holds the private half of `claim.phone`. A phone that is here already
      // under that public key keeps its id and gets the new key; the old one dies.
      let id = phones.first { $0.value.publicKey == claim.phone }?.key ?? o.id
      add(id, seal, claim.phone)
      offered = nil
      (hit, paired) = ((id, p), key + claim.phone)
    }
    guard let (id, packet) = hit else { return nil }
    let (reply, actions) = phones[id]!.sessions.receive(packet, now: now)
    return Received(id: id, packet: packet, reply: reply, datagram: try? phones[id]!.seal.seal(reply),
                    actions: actions, paired: paired)
  }

  /// True when a session ended, so the caller can release held input.
  public mutating func expire(now: TimeInterval) -> Bool {
    var any = false
    for id in phones.keys where phones[id]!.sessions.expire(now: now) { any = true }
    return any
  }
}
