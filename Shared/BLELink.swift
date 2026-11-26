import CoreBluetooth
import Foundation
import TailmouseKit

/// One Bluetooth L2CAP channel as a datagram pipe (`Framer`). Every call and
/// callback happens on `queue`.
///
/// Sends are latest-wins. The stream takes bytes long before the radio does,
/// so `hasSpaceAvailable` says nothing about the link: with a `window`, the
/// phone sends only as fast as the Mac answers and keeps the newest datagram
/// beyond that. Events ride in every packet until acked, so dropping is safe.
/// The Mac answers once per packet and needs no window.
final class BLELink: NSObject, StreamDelegate {
  var onReady: (() -> Void)?
  var onDatagram: ((Data) -> Void)?
  var onClose: (() -> Void)?
  /// Both streams are open.
  private(set) var ready = false

  /// Held for the life of the link: releasing the channel closes it.
  private let channel: CBL2CAPChannel
  private let queue: DispatchQueue
  private var framer = Framer()
  private var opened = 0
  private var closed = false
  /// The rest of a frame the stream took only part of.
  private var partial = Data()
  /// The newest datagram waiting for its turn.
  private var held: Data?
  private var window: SendWindow?
  private var timerSet = false

  init(_ channel: CBL2CAPChannel, queue: DispatchQueue, window: SendWindow? = nil) {
    self.channel = channel
    self.queue = queue
    self.window = window
    super.init()
    for s in [channel.inputStream, channel.outputStream] as [Stream] { s.delegate = self }
    CFReadStreamSetDispatchQueue(channel.inputStream, queue)
    CFWriteStreamSetDispatchQueue(channel.outputStream, queue)
    channel.inputStream.open()
    channel.outputStream.open()
  }

  func send(_ datagram: Data) {
    guard ready else { return }
    held = datagram
    pump()
  }

  func close() {
    guard !closed else { return }
    closed = true
    ready = false
    for s in [channel.inputStream, channel.outputStream] as [Stream] {
      s.delegate = nil
      s.close()
    }
    onClose?()
  }

  private func pump() {
    flush()
    guard partial.isEmpty, let next = held else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let wait = window?.wait(now: now) ?? 0
    if wait > 0 {
      guard !timerSet else { return }
      timerSet = true
      queue.asyncAfter(deadline: .now() + wait) { [weak self] in
        self?.timerSet = false
        self?.pump()
      }
      return
    }
    held = nil
    window?.sent(now: now)
    partial = Framer.frame(next) ?? Data()
    flush()
  }

  private func flush() {
    let out: OutputStream = channel.outputStream
    while !partial.isEmpty, !closed, out.hasSpaceAvailable {
      let n = partial.withUnsafeBytes { out.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: $0.count) }
      guard n > 0 else { return }
      partial = Data(partial.dropFirst(n))
    }
  }

  func stream(_ stream: Stream, handle event: Stream.Event) {
    switch event {
    case .openCompleted:
      opened += 1
      if opened == 2 { ready = true; onReady?() }
    case .hasBytesAvailable:
      var chunk = [UInt8](repeating: 0, count: 4096)
      while !closed, channel.inputStream.hasBytesAvailable {
        let n = channel.inputStream.read(&chunk, maxLength: chunk.count)
        guard n > 0 else { break }
        guard let datagrams = framer.feed(Data(chunk[..<n])) else { close(); return }
        datagrams.forEach { window?.answered(); onDatagram?($0) }
      }
      pump()
    case .hasSpaceAvailable: pump()
    case .errorOccurred, .endEncountered: close()
    default: break
    }
  }
}

extension CBManagerState {
  var text: String {
    switch self {
    case .poweredOn: "on"
    case .poweredOff: "Bluetooth is off"
    case .unauthorized: "not allowed (Settings › Privacy › Bluetooth)"
    case .unsupported: "not available"
    case .resetting: "resetting"
    default: "starting"
    }
  }
}

/// The standard characteristic a peripheral publishes its L2CAP PSM in.
let blePSMCharacteristic = CBUUID(string: CBUUIDL2CAPPSMCharacteristicString)
