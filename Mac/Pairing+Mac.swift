import CoreImage.CIFilterBuiltins
import Foundation
import Security

/// Secrets (pairing key, PIN) live in the login Keychain.
enum KeyStore {
  private static func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "tailmouse",
     kSecAttrAccount as String: account]
  }

  static func load(_ account: String = "pairing-key") -> Data? {
    var q = query(account)
    q[kSecReturnData as String] = true
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
    return out as? Data
  }

  static func delete(_ account: String) {
    SecItemDelete(query(account) as CFDictionary)
  }

  static func save(_ data: Data, _ account: String = "pairing-key") {
    SecItemDelete(query(account) as CFDictionary)
    var q = query(account)
    q[kSecValueData as String] = data
    SecItemAdd(q as CFDictionary, nil)
  }
}

/// This Mac's tailnet IPv4 addresses (100.64.0.0/10), read from the interfaces
/// so there is no dependency on the tailscale CLI.
func tailnetAddresses() -> [String] {
  var head: UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&head) == 0 else { return [] }
  defer { freeifaddrs(head) }
  var out: [String] = []
  var p = head
  while let ifa = p?.pointee {
    defer { p = ifa.ifa_next }
    guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
    let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
    guard addr & 0xFFC0_0000 == 0x6440_0000 else { continue }
    out.append("\(addr >> 24).\(addr >> 16 & 0xFF).\(addr >> 8 & 0xFF).\(addr & 0xFF)")
  }
  return out
}

func qrImage(for string: String) -> CGImage? {
  let f = CIFilter.qrCodeGenerator()
  f.message = Data(string.utf8)
  f.correctionLevel = "M"
  guard let img = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
  return CIContext().createCGImage(img, from: img.extent)
}
