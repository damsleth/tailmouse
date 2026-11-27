import CryptoKit
import Foundation

/// What the Mac's QR code carries: `tailmouse://pair?k=<key>&b=<ble>&n=<name>&p=<port>&h=<host>&h=<host>`.
///
/// `hosts` are tailnet addresses (100.x, MagicDNS names) to try directly; the
/// LAN path is found by Bonjour using `name`. `k` is base64url, 32 bytes: in the code,
/// the public key the Mac made for it, good for one phone (`claimed`); in a
/// stored pairing, the key that phone and the Mac agreed on.
/// `ble` is the Bluetooth service the Mac advertises, the same for every phone.
public struct Pairing: Codable, Equatable, Sendable {
  public var key: Data
  /// This phone's public key, until the Mac has answered: see `Seal.claim`.
  public var claim: Data?
  public var ble: UUID
  public var name: String
  public var port: UInt16
  public var hosts: [String]

  public init(key: Data, ble: UUID, name: String, port: UInt16 = Wire.defaultPort, hosts: [String]) {
    self.key = key
    self.ble = ble
    self.name = name
    self.port = port
    self.hosts = hosts
  }

  public var url: URL {
    var c = URLComponents()
    c.scheme = "tailmouse"
    c.host = "pair"
    c.queryItems = [
      URLQueryItem(name: "k", value: Self.base64url(key)),
      URLQueryItem(name: "b", value: ble.uuidString),
      URLQueryItem(name: "n", value: name),
      URLQueryItem(name: "p", value: String(port)),
    ] + hosts.map { URLQueryItem(name: "h", value: $0) }
    return c.url!
  }

  public init?(url: URL) {
    guard url.scheme == "tailmouse", url.host == "pair",
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
          let k = items.first(where: { $0.name == "k" })?.value,
          let key = Self.data(base64url: k), key.count == 32,
          let ble = items.first(where: { $0.name == "b" })?.value.flatMap(UUID.init),
          let name = items.first(where: { $0.name == "n" })?.value, !name.isEmpty
    else { return nil }
    let port = items.first(where: { $0.name == "p" })?.value.flatMap(UInt16.init) ?? Wire.defaultPort
    let hosts = items.filter { $0.name == "h" }.compactMap(\.value).filter(Route.isTailnet(host:)).prefix(8)
    self.init(key: key, ble: ble, name: String(name.prefix(64)), port: port, hosts: Array(hosts))
  }

  /// What the phone stores after scanning the code: a key only it and the Mac
  /// can work out, and the public key to tell the Mac.
  /// `mine` is the phone's own key pair, the same at every pairing, so the
  /// Mac recognises a phone it has already and replaces its key.
  public func claimed(with mine: Seal.PairingKey = Seal.PairingKey()) -> Pairing? {
    let pub = mine.publicKey.rawRepresentation
    guard let k = Seal.agree(mine, with: key, mac: key, phone: pub) else { return nil }
    var p = self
    (p.key, p.claim) = (k, pub)
    return p
  }

  static func base64url(_ d: Data) -> String {
    d.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func data(base64url s: String) -> Data? {
    var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    b += String(repeating: "=", count: (4 - b.count % 4) % 4)
    return Data(base64Encoded: b)
  }
}
