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

  // MARK: Pairing
  //
  // The pairing code holds a public key the Mac made for that code. The phone
  // makes a key pair of its own, and both derive the phone's key from the
  // X25519 secret. A copy of the code, even with every packet recorded, does
  // not give that key: it takes one of the two private keys.

  public typealias PairingKey = Curve25519.KeyAgreement.PrivateKey

  /// The key a phone and the Mac share from then on; nil for a bad public key.
  public static func agree(_ mine: PairingKey, with peer: Data, mac: Data, phone: Data) -> Data? {
    guard let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer),
          let secret = try? mine.sharedSecretFromKeyAgreement(with: pub) else { return nil }
    return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: mac + phone,
                                          sharedInfo: Data("tailmouse-pair".utf8), outputByteCount: 32).data
  }

  /// A claim: `"TP" | version | phone public key (32) | an ordinary datagram`.
  /// The phone sends its datagrams like this until the Mac has answered one.
  static let claimHeader = Data([0x54, 0x50, Wire.version])

  public static func claim(_ phonePublic: Data, _ datagram: Data) -> Data { claimHeader + phonePublic + datagram }

  /// The phone's public key and the datagram behind it, when this is a claim.
  static func claimed(_ d: Data) -> (phone: Data, datagram: Data)? {
    guard d.count > claimHeader.count + 32, d.prefix(claimHeader.count) == claimHeader else { return nil }
    let rest = d.dropFirst(claimHeader.count)
    return (Data(rest.prefix(32)), Data(rest.dropFirst(32)))
  }

  public func seal<T: WireCoded>(_ value: T) throws -> Data {
    let box = try ChaChaPoly.seal(value.wire, using: key, authenticating: Self.header)
    return Self.header + box.combined
  }

  public func open<T: WireCoded>(_ type: T.Type, from datagram: Data) -> T? {
    guard datagram.count > Self.header.count,
          datagram.prefix(Self.header.count) == Self.header,
          let box = try? ChaChaPoly.SealedBox(combined: datagram.dropFirst(Self.header.count)),
          let plain = try? ChaChaPoly.open(box, using: key, authenticating: Self.header)
    else { return nil }
    return T(wire: plain)
  }
}

extension SymmetricKey {
  public var data: Data { withUnsafeBytes { Data($0) } }
}
