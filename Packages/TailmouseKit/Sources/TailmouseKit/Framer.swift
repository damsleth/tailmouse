import CryptoKit
import Foundation

/// Datagrams over a byte stream, for the Bluetooth route: a 2-byte big-endian
/// length, then the sealed datagram. The length comes from a peer that has
/// proved nothing yet, so it is capped.
public struct Framer: Sendable {
  public static let maxFrame = 16_384

  private var buffer = Data()

  public init() {}

  /// Nil for a datagram that is empty or too long to frame.
  public static func frame(_ datagram: Data) -> Data? {
    guard !datagram.isEmpty, datagram.count <= maxFrame else { return nil }
    return Data([UInt8(datagram.count >> 8), UInt8(datagram.count & 0xFF)]) + datagram
  }

  /// The datagrams completed by `bytes`. Nil when the stream is out of step
  /// (a zero or oversize length); the caller closes it.
  public mutating func feed(_ bytes: Data) -> [Data]? {
    buffer.append(bytes)
    var out: [Data] = []
    while buffer.count >= 2 {
      let length = Int(buffer[buffer.startIndex]) << 8 | Int(buffer[buffer.startIndex + 1])
      guard length > 0, length <= Self.maxFrame else { return nil }
      guard buffer.count >= 2 + length else { break }
      out.append(Data(buffer.dropFirst(2).prefix(length)))
      buffer = Data(buffer.dropFirst(2 + length))
    }
    return out
  }
}

/// Sends clocked by the peer's answers, for a link that buffers instead of
/// dropping (Bluetooth): at most `size` datagrams unanswered, so a slow link
/// holds a couple of fresh positions instead of a queue of stale ones.
public struct SendWindow: Sendable {
  /// 1 is stop-and-wait: one update per two connection intervals.
  public var size: Int
  /// An answer that never comes (a switched-off route) reopens the window.
  public static let timeout = 0.25

  private var unanswered = 0
  private var lastSent = -Double.infinity

  public init(size: Int = 3) { self.size = size }

  /// Seconds until a send is allowed; 0 or less means now.
  public mutating func wait(now: Double) -> Double {
    if unanswered >= size, now - lastSent >= Self.timeout { unanswered = 0 }
    return unanswered < size ? 0 : lastSent + Self.timeout - now
  }
  public mutating func sent(now: Double) { unanswered += 1; lastSent = now }
  public mutating func answered() { unanswered = max(0, unanswered - 1) }
}

extension Wire {
  /// The Bluetooth service a Mac advertises and its phones scan for, derived
  /// from the pairing key. A phone finds only its own Mac, the advertisement
  /// names nobody, and a new key moves the service.
  public static func bleService(key: Data) -> UUID {
    let h = Array(SHA256.hash(data: Data("tailmouse-ble-v1".utf8) + key))
    return UUID(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7],
                       h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
  }
}
