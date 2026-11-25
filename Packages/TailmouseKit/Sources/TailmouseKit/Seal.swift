import CryptoKit
import Foundation

/// Encrypts and authenticates datagrams with the key both sides got at pairing.
///
/// The LAN path carries keystrokes, so every packet is sealed, tailnet or not.
/// Layout: `"TM" | version | ChaChaPoly combined box (nonce + ciphertext + tag)`,
/// with the 3-byte header as associated data. Anything that fails to open is
/// dropped without a reply.
public struct Seal: Sendable {
  public let key: SymmetricKey
  static let header = Data([0x54, 0x4D, Wire.version])

  public init(key: SymmetricKey) { self.key = key }

  public init?(keyData: Data) {
    guard keyData.count == 32 else { return nil }
    self.key = SymmetricKey(data: keyData)
  }

  public static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

  public func seal<T: Encodable>(_ value: T) throws -> Data {
    let plain = try JSONEncoder().encode(value)
    let box = try ChaChaPoly.seal(plain, using: key, authenticating: Self.header)
    return Self.header + box.combined
  }

  public func open<T: Decodable>(_ type: T.Type, from datagram: Data) -> T? {
    guard datagram.count > Self.header.count,
          datagram.prefix(Self.header.count) == Self.header,
          let box = try? ChaChaPoly.SealedBox(combined: datagram.dropFirst(Self.header.count)),
          let plain = try? ChaChaPoly.open(box, using: key, authenticating: Self.header)
    else { return nil }
    return try? JSONDecoder().decode(type, from: plain)
  }
}

extension SymmetricKey {
  public var data: Data { withUnsafeBytes { Data($0) } }
}
