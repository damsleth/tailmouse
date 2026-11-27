import CoreBluetooth
import Foundation
import Network
import TailmouseKit

/// Something the client can send a sealed datagram on.
protocol Flow: AnyObject {
  var isReady: Bool { get }
  func transmit(_ datagram: Data)
  func stop()
}

extension NWConnection: Flow {
  var isReady: Bool { state == .ready }
  func transmit(_ datagram: Data) { send(content: datagram, completion: .idempotent) }
  func stop() { cancel() }
}

extension BLELink: Flow {
  var isReady: Bool { ready }
  func transmit(_ datagram: Data) { send(datagram) }
  func stop() { close() }
}

/// The Bluetooth route on the phone: finds the paired Mac by the service
/// named in the pairing, reads the L2CAP PSM and opens a channel.
/// Everything on the main queue. Keeps looking until `stop`.
final class BLECentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  /// The link when it is ready, nil when it is gone.
  var onLink: ((BLELink?) -> Void)?
  /// For the Settings screen; the only view into this from outside the phone.
  var onState: ((String) -> Void)?

  private var manager: CBCentralManager?
  private var service: CBUUID?
  /// Held while connecting and connected, or CoreBluetooth drops it.
  private var peripheral: CBPeripheral?
  private var link: BLELink?

  /// The first call asks the user for Bluetooth access.
  func start(service id: UUID) {
    let wanted = CBUUID(nsuuid: id)
    guard wanted != service else { return }
    stop()
    service = wanted
    if manager == nil { manager = CBCentralManager(delegate: self, queue: .main) }
    scan()
  }

  func stop() {
    service = nil
    drop()
    manager?.stopScan()
  }

  private func drop() {
    link?.onClose = nil
    link?.close()
    if link != nil { onLink?(nil) }
    link = nil
    if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
    peripheral = nil
  }

  private func scan(after why: String? = nil) {
    guard let manager, manager.state == .poweredOn, let service, peripheral == nil else { return }
    manager.scanForPeripherals(withServices: [service])
    // The reason stays visible: this line is all anyone sees of a failure.
    onState?(why.map { "searching (last: \($0))" } ?? "searching")
  }

  private func retry(_ why: String) {
    drop()
    scan(after: why)
  }

  func centralManagerDidUpdateState(_ m: CBCentralManager) {
    onState?(m.state.text)
    if m.state == .poweredOn { scan() } else { drop() }
  }

  func centralManager(_ m: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
    guard peripheral == nil else { return }
    peripheral = p
    p.delegate = self
    m.stopScan()
    m.connect(p)
    onState?("connecting")
  }

  func centralManager(_ m: CBCentralManager, didConnect p: CBPeripheral) {
    p.discoverServices(service.map { [$0] })
  }

  func centralManager(_ m: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { retry("connect failed") }

  func centralManager(_ m: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { retry("disconnected") }

  func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    guard let s = p.services?.first(where: { $0.uuid == service }) else { return retry("no service") }
    p.discoverCharacteristics([blePSMCharacteristic], for: s)
  }

  func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
    guard let c = s.characteristics?.first(where: { $0.uuid == blePSMCharacteristic }) else { return retry("no channel number") }
    p.readValue(for: c)
  }

  func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
    guard let v = c.value, v.count == 2 else { return retry("bad channel number") }
    p.openL2CAPChannel(CBL2CAPPSM(v[v.startIndex]) | CBL2CAPPSM(v[v.startIndex + 1]) << 8)
    onState?("opening channel")
  }

  func peripheral(_ p: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
    guard let channel, error == nil else { return retry("channel failed") }
    let l = BLELink(channel, queue: .main, window: SendWindow())
    link = l
    l.onReady = { [weak self, weak l] in
      self?.onState?("connected")
      self?.onLink?(l)
    }
    l.onClose = { [weak self] in self?.retry("channel closed") }
  }
}
