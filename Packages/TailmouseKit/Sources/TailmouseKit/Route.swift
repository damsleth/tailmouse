import Network

/// How a phone's packets reach the Mac. The Mac can switch each one off.
public enum Route: String, CaseIterable, Codable, Identifiable, Sendable {
  case usb, lan, awdl, tailnet, ble

  public var id: Self { self }

  /// Classifies a flow by the phone's address: tailnet ranges first, then the
  /// interface of a link-local address (AWDL, or the phone's USB cable, which
  /// only the caller can recognise); anything else came over the local network.
  ///
  /// ponytail: an IPv4 flow over the cable (169.254/16) carries no interface
  /// and counts as LAN. Bonjour picks IPv6 link-local there; classify from the
  /// connection's path if that ever changes.
  public static func of(_ endpoint: NWEndpoint, isUSB: (String) -> Bool = { _ in false }) -> Route {
    guard case .hostPort(let host, _) = endpoint else { return .lan }
    switch host {
    case .ipv4(let a):
      return isTailnet(a) ? .tailnet : .lan
    case .ipv6(let a):
      if let v4 = a.asIPv4 { return isTailnet(v4) ? .tailnet : .lan }
      if a.rawValue.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]) { return .tailnet }  // fd7a:115c:a1e0::/48
      let iface = a.interface?.name ?? "\(host)".split(separator: "%").last.map(String.init) ?? ""
      return iface.hasPrefix("awdl") ? .awdl : isUSB(iface) ? .usb : .lan
    default:
      return .lan
    }
  }

  /// Whether a pairing URL host is a tailnet address or MagicDNS name. Other
  /// hosts are dropped, so a crafted link can't point the phone at the internet.
  public static func isTailnet(host: String) -> Bool {
    if let a = IPv4Address(host) { return isTailnet(a) }
    if let a = IPv6Address(host) { return a.rawValue.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]) }
    return host.lowercased().hasSuffix(".ts.net")
  }

  /// 100.64.0.0/10
  private static func isTailnet(_ a: IPv4Address) -> Bool {
    let b = a.rawValue
    return b[0] == 100 && b[1] & 0xC0 == 64
  }
}
