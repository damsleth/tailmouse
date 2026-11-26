import CoreBluetooth
import Foundation
import os
import TailmouseKit

/// The Bluetooth route on the Mac: advertises a service derived from the
/// pairing key and accepts L2CAP channels from phones. Runs on the server queue.
///
/// The same rules as the UDP flows: a channel whose first frame fails to open
/// is closed, a channel that never authenticates goes after 3 s, and the
/// number of channels is capped.
final class BLEPeripheral: NSObject, CBPeripheralManagerDelegate {
  /// A datagram from a phone; answers with `reply`. Returns whether it opened.
  var onDatagram: ((Data, _ reply: @escaping (Data) -> Void) -> Bool)?

  private let queue: DispatchQueue
  private let log = Logger(subsystem: "tailmouse", category: "ble")
  private var manager: CBPeripheralManager?
  /// What to advertise; nil while the route is off.
  private var service: CBUUID?
  private var psm: CBL2CAPPSM?
  private var links: [ObjectIdentifier: (link: BLELink, opened: TimeInterval, authed: Bool)] = [:]
  private static let maxLinks = 4

  init(queue: DispatchQueue) { self.queue = queue }

  /// Advertise for this key, or stop with nil. The first call asks the user
  /// for Bluetooth access, so the manager is not made before it is needed.
  func set(key: Data?) {
    let wanted = key.map { CBUUID(nsuuid: Wire.bleService(key: $0)) }
    guard wanted != service else { return }
    teardown()
    service = wanted
    guard wanted != nil else { return }
    if manager == nil { manager = CBPeripheralManager(delegate: self, queue: queue) }
    publish()
  }

  /// Called once a second by the server.
  func sweep(now: TimeInterval) {
    for entry in links.values where !entry.authed && now - entry.opened > 3 { entry.link.close() }
  }

  private func teardown() {
    links.values.forEach { $0.link.close() }
    guard let manager, manager.state == .poweredOn else { psm = nil; return }
    manager.stopAdvertising()
    manager.removeAllServices()
    if let psm { manager.unpublishL2CAPChannel(psm) }
    psm = nil
  }

  private func publish() {
    guard let manager, manager.state == .poweredOn, service != nil, psm == nil else { return }
    manager.publishL2CAPChannel(withEncryption: false)   // every datagram is sealed already
  }

  func peripheralManagerDidUpdateState(_ m: CBPeripheralManager) {
    log.notice("state: \(m.state.text, privacy: .public)")
    if m.state == .poweredOn { publish() } else { psm = nil }
  }

  func peripheralManager(_ m: CBPeripheralManager, didPublishL2CAPChannel psm: CBL2CAPPSM, error: Error?) {
    guard error == nil, let service else {
      log.error("publish failed: \(String(describing: error), privacy: .public)")
      return
    }
    self.psm = psm
    // No stored value: the read comes to us, which is where we learn the
    // central and can ask it for a short connection interval.
    let c = CBMutableCharacteristic(type: blePSMCharacteristic, properties: .read, value: nil, permissions: .readable)
    let s = CBMutableService(type: service, primary: true)
    s.characteristics = [c]
    m.add(s)
    m.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service]])
    log.notice("advertising, psm \(psm)")
  }

  func peripheralManager(_ m: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    guard let psm, request.characteristic.uuid == blePSMCharacteristic, request.offset == 0 else {
      m.respond(to: request, withResult: .attributeNotFound)
      return
    }
    request.value = Data([UInt8(psm & 0xFF), UInt8(psm >> 8)])
    m.respond(to: request, withResult: .success)
    m.setDesiredConnectionLatency(.low, for: request.central)
    log.notice("psm read, asked for low latency")
  }

  func peripheralManager(_ m: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
    guard let channel, error == nil, links.count < Self.maxLinks else {
      log.error("channel refused: \(String(describing: error), privacy: .public)")
      return
    }
    let link = BLELink(channel, queue: queue)
    let id = ObjectIdentifier(link)
    links[id] = (link, ProcessInfo.processInfo.systemUptime, false)
    log.notice("channel open (\(self.links.count))")
    link.onDatagram = { [weak self, weak link] data in
      guard let self, let link else { return }
      if self.onDatagram?(data, { [weak link] in link?.send($0) }) == true {
        self.links[id]?.authed = true
      } else if self.links[id]?.authed != true {
        link.close()
      }
    }
    link.onClose = { [weak self] in
      self?.links[id] = nil
      self?.log.notice("channel closed")
    }
  }
}
