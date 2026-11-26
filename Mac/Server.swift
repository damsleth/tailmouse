import Foundation
import IOKit
import Network
import os
import TailmouseKit

/// What the settings window controls.
struct ServerConfig: Equatable {
  var port: UInt16 = Wire.defaultPort
  var routes: Set<Route> = Set(Route.allCases)
  var pin: String?
  /// Scroll momentum time constant in seconds; 0 is off.
  var momentum = 0.5
}

/// A phone the Mac has seen, kept across launches for the Devices list.
struct DeviceRecord: Codable, Identifiable, Equatable {
  var id: String
  var name: String
  /// The path the phone was sending on ("AWDL", "LAN", "Tailnet").
  var via: String
  var lastSeen: Date

  var isConnected: Bool { Date().timeIntervalSince(lastSeen) < Wire.sessionTimeout }
}

/// The UDP listener. Everything runs on one serial queue: open, decide
/// (`Sessions`), post input, reply. Advertised over Bonjour on the LAN and,
/// with `includePeerToPeer`, over AWDL; the tailnet reaches it by IP.
final class Server {
  /// Every known device, once a second, on the main queue.
  var onDevices: (([DeviceRecord]) -> Void)?
  var onState: ((String) -> Void)?
  /// Too many wrong PINs; the owner should make a new key. Main queue.
  var onPinLocked: (() -> Void)?

  private let queue = DispatchQueue(label: "tailmouse.server", qos: .userInteractive)
  private let name: String
  private var seal: Seal
  private var sessions: Sessions
  private var config: ServerConfig
  private var devices: [String: DeviceRecord]
  private let input: Input
  private var listener: NWListener?
  /// Every source address and port gets a flow before anything is known about
  /// it, so the table is capped and flows that never authenticate go quickly.
  private var connections: [ObjectIdentifier: (conn: NWConnection, route: Route, lastSeen: TimeInterval, authed: Bool)] = [:]
  private static let maxConnections = 32
  private static let maxDevices = 50
  private var timer: DispatchSourceTimer?
  /// A menu bar app with no window is an App Nap candidate; napping delays
  /// the queue. Idle system sleep stays allowed.
  private let activity = ProcessInfo.processInfo.beginActivity(
    options: [.latencyCritical, .userInitiatedAllowingIdleSystemSleep], reason: "Posting pointer input")

  /// Timing per route for one second of traffic, to tell a stalling phone
  /// (send gaps) from a stalling network (late). Switch on with
  /// `defaults write <bundle id> jitterLog -bool YES`, read with
  /// `log stream --predicate 'subsystem == "tailmouse"'`.
  private struct Jitter {
    var n = 0, sendGap = 0.0, arriveGap = 0.0, late = 0.0
    var lastSent = 0.0, lastArrived = 0.0, minDelay = Double.infinity
  }
  private var jitter: [Route: Jitter] = [:]
  private let jitterLog = UserDefaults.standard.bool(forKey: "jitterLog")
  private let log = Logger(subsystem: "tailmouse", category: "jitter")

  init(key: Data, name: String, devices: [DeviceRecord], config: ServerConfig) {
    self.name = name
    self.seal = Seal(keyData: key)!
    self.sessions = Sessions(name: name)
    self.sessions.pin = config.pin
    self.config = config
    self.input = Input(queue: queue)
    self.input.momentum.tau = config.momentum
    self.devices = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
  }

  func start() {
    queue.async { self.listen() }
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + 1, repeating: 1)
    t.setEventHandler { [weak self] in self?.housekeeping() }
    t.resume()
    timer = t
  }

  /// New key: every paired phone has to scan again.
  func rekey(_ key: Data) {
    queue.async {
      self.seal = Seal(keyData: key)!
      self.sessions = Sessions(name: self.name)
      self.sessions.pin = self.config.pin
      self.input.releaseAll()
    }
  }

  func apply(_ new: ServerConfig) {
    queue.async {
      let old = self.config
      self.config = new
      self.sessions.pin = new.pin
      self.input.momentum.tau = new.momentum
      // includePeerToPeer and the port are fixed per listener.
      if old.port != new.port || old.routes.contains(.awdl) != new.routes.contains(.awdl) {
        self.restart()
      }
    }
  }

  func forget(device id: String) {
    queue.async { self.devices[id] = nil }
  }

  private func restart() {
    listener?.cancel()
    listener = nil
    connections.values.forEach { $0.conn.cancel() }
    connections.removeAll()
    listen()
  }

  private func listen() {
    let params = NWParameters.udp
    params.includePeerToPeer = config.routes.contains(.awdl)
    params.allowLocalEndpointReuse = true
    let port = config.port
    do {
      let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
      l.service = NWListener.Service(name: name, type: Wire.bonjourType)
      l.newConnectionHandler = { [weak self] c in self?.accept(c) }
      l.stateUpdateHandler = { [weak self, weak l] state in
        guard let self, let l, self.listener === l else { return }
        let text: String
        switch state {
        case .ready: text = "Listening on port \(port)"
        case .failed(let e): text = "Listener failed: \(e)"
        case .waiting(let e): text = "Waiting: \(e)"
        default: return
        }
        DispatchQueue.main.async { self.onState?(text) }
        if case .failed = state {
          // Port busy or network flap: try again shortly.
          self.listener = nil
          self.queue.asyncAfter(deadline: .now() + 2) { if self.listener == nil { self.listen() } }
        }
      }
      listener = l
      l.start(queue: queue)
    } catch {
      DispatchQueue.main.async { self.onState?("Listener error: \(error)") }
    }
  }

  private func accept(_ c: NWConnection) {
    guard connections.count < Self.maxConnections else { c.cancel(); return }
    connections[ObjectIdentifier(c)] = (c, Route.of(c.endpoint, isUSB: isPhoneUSB), now(), false)
    c.stateUpdateHandler = { [weak self, weak c] state in
      guard let self, let c else { return }
      switch state {
      case .failed, .cancelled: self.connections[ObjectIdentifier(c)] = nil
      default: break
      }
    }
    c.start(queue: queue)
    receive(on: c)
  }

  private func receive(on c: NWConnection) {
    c.receiveMessage { [weak self, weak c] data, _, _, error in
      guard let self, let c else { return }
      if let data { self.handle(data, from: c) }
      if error == nil { self.receive(on: c) }
    }
  }

  private func handle(_ data: Data, from c: NWConnection) {
    // A switched-off route gets no answer, so the phone's picker never uses it.
    let id = ObjectIdentifier(c)
    guard let entry = connections[id], config.routes.contains(entry.route) else { return }
    // Unauthenticated or tampered: drop without a word, and drop the flow too
    // unless it has carried a good packet before.
    guard let packet = seal.open(Packet.self, from: data) else {
      if !entry.authed { c.cancel(); connections[id] = nil }
      return
    }
    connections[id]?.lastSeen = now()
    connections[id]?.authed = true
    if jitterLog { note(packet, route: entry.route) }
    let (reply, actions) = sessions.receive(packet, now: now())
    actions.forEach(input.perform)
    if let out = try? seal.seal(reply) {
      c.send(content: out, completion: .idempotent)
    }
    if packet.session != 0, packet.session == reply.session {
      let key = packet.device?.uuidString ?? "client-\(packet.client)"
      devices[key] = DeviceRecord(id: key, name: String((packet.name ?? "iPhone").prefix(64)),
                                  via: String((packet.via ?? devices[key]?.via ?? "").prefix(16)), lastSeen: Date())
      if devices.count > Self.maxDevices, let oldest = devices.values.min(by: { $0.lastSeen < $1.lastSeen }) {
        devices[oldest.id] = nil
      }
    }
  }

  private func note(_ p: Packet, route: Route) {
    let t = now()
    var j = jitter[route] ?? Jitter()
    // A gap over 0.25 s is a lifted finger (the 1 s probe), not a stall.
    let sent = p.time - j.lastSent, arrived = t - j.lastArrived
    if sent > 0, sent < 0.25 { j.sendGap = max(j.sendGap, sent) }
    if arrived < 0.25 { j.arriveGap = max(j.arriveGap, arrived) }
    // The phone's clock stops while it sleeps, so start over after a silence.
    if arrived > 3 { j.minDelay = .infinity }
    j.minDelay = min(j.minDelay, t - p.time)
    j.late = max(j.late, t - p.time - j.minDelay)
    j.n += 1
    j.lastSent = max(j.lastSent, p.time)
    j.lastArrived = t
    jitter[route] = j
  }

  private func housekeeping() {
    let t = now()
    for (route, j) in jitter where j.n > 5 {
      log.notice("\(route.rawValue, privacy: .public) n=\(j.n) sendGap=\(j.sendGap * 1000, format: .fixed(precision: 1)) arriveGap=\(j.arriveGap * 1000, format: .fixed(precision: 1)) late=\(j.late * 1000, format: .fixed(precision: 1)) ms")
    }
    for route in jitter.keys { (jitter[route]!.n, jitter[route]!.sendGap, jitter[route]!.arriveGap, jitter[route]!.late) = (0, 0, 0, 0) }
    if sessions.expire(now: t) { input.releaseAll() }
    for (id, entry) in connections where t - entry.lastSeen > (entry.authed ? 30 : 3) {
      entry.conn.cancel()
      connections[id] = nil
    }
    let list = devices.values.sorted { $0.lastSeen > $1.lastSeen }
    let locked = sessions.pinLocked
    DispatchQueue.main.async {
      self.onDevices?(list)
      if locked { self.onPinLocked?() }
    }
  }

  private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Whether a network interface is an iPhone's USB cable: an NCM function of an
/// Apple USB device. A USB Ethernet adapter is a LAN and doesn't match.
func isPhoneUSB(_ bsdName: String) -> Bool {
  guard !bsdName.isEmpty, let match = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return false }
  var entry = IOServiceGetMatchingService(kIOMainPortDefault, match)
  var ncm = false
  while entry != 0 {
    if IOObjectConformsTo(entry, "AppleUSBNCMData") != 0 { ncm = true }
    if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 {
      let vendor = IORegistryEntryCreateCFProperty(entry, "idVendor" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Int
      IOObjectRelease(entry)
      return ncm && vendor == 0x05AC
    }
    var parent: io_registry_entry_t = 0
    IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
    IOObjectRelease(entry)
    entry = parent
  }
  return false
}
