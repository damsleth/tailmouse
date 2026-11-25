import Foundation

/// What the Mac's QR code carries: `tailmouse://pair?k=<key>&n=<name>&p=<port>&h=<host>&h=<host>`.
///
/// `hosts` are tailnet addresses (100.x, MagicDNS names) to try directly; the
/// LAN path is found by Bonjour using `name`. The key is base64url, 32 bytes.
public struct Pairing: Codable, Equatable, Sendable {
  public var key: Data
  public var name: String
  public var port: UInt16
  public var hosts: [String]
  /// Entered on the phone when the Mac asks; never in the URL or QR.
  public var pin: String?

  public init(key: Data, name: String, port: UInt16 = Wire.defaultPort, hosts: [String]) {
    self.key = key
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
          let name = items.first(where: { $0.name == "n" })?.value, !name.isEmpty
    else { return nil }
    let port = items.first(where: { $0.name == "p" })?.value.flatMap(UInt16.init) ?? Wire.defaultPort
    let hosts = items.filter { $0.name == "h" }.compactMap(\.value)
    self.init(key: key, name: name, port: port, hosts: hosts)
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
