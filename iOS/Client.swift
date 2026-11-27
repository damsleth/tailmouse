import Foundation
import Network
import TailmouseKit
import UIKit

/// The phone's connection to its paired Mac.
///
/// Opens one UDP flow per path: each tailnet address from the pairing, and the
/// Mac's Bonjour service on every interface it shows up on (Wi-Fi = LAN,
/// awdl0 = AWDL, wired = the USB cable). Every path is probed once a second; hot traffic goes to the
/// fastest live one (`PathPicker`). All on the main queue: touches arrive
/// there, and a send is a few microseconds.
@MainActor
final class Client: ObservableObject {
  @Published private(set) var pairing: Pairing?
  @Published private(set) var macName: String?
  @Published private(set) var path: String?
  @Published private(set) var rtt: Double?
  @Published private(set) var paths: [String] = []
  /// What the Bluetooth route is doing, for Settings.
  @Published private(set) var bleState = "off"
  /// Width over height of the Mac's drawing area.
  @Published private(set) var aspect = 1.6

  var interpreter = TouchInterpreter()
  /// Whether AWDL may be used at all. Even then it is a last resort (`awdlUp`).
  var useAWDL = UserDefaults.standard.object(forKey: "awdl") as? Bool ?? true
  /// AWDL is browsed and connected only after nothing else answered. Merely
  /// browsing with it makes the phone's radio leave the Wi-Fi channel about
  /// twice a second for ~100 ms, which stalls every other wireless path.
  private var awdlUp = false

  /// New per launch, so the Mac starts a fresh session (see `Packet.client`).
  private let clientID = UInt64.random(in: 1...UInt64.max)
  private var seal: Seal?
  private var session: UInt64 = 0
  private var outbox = Outbox()
  private var motion: Motion?
  private var picker = PathPicker()
  /// When any path last answered; see `probe`.
  private var lastReply = 0.0
  /// Newest `Reply.echo` that changed state, overall and per path. An older
  /// reply is a straggler or a replay: it must not roll back the session or
  /// acks, or keep a dead path looking alive.
  private var newestEcho = -Double.infinity
  private var newestEchoOnPath: [String: Double] = [:]
  private var flows: [String: Flow] = [:]
  /// The Bluetooth route keeps itself up: it takes seconds to set up, so it
  /// stays out of `reconnect`, and its flow lives under `bleLabel`.
  private let ble = BLECentral()
  private static let bleLabel = "BLE"
  private var browser: NWBrowser?
  /// Interfaces that already have a Bonjour flow; `open` numbers duplicate labels.
  private var pinned: Set<String> = []
  private let monitor = NWPathMonitor()
  private var probeTimer: Timer?
  private var resendTimer: Timer?
  private let tapHaptic = UIImpactFeedbackGenerator(style: .light)
  private let dragHaptic = UIImpactFeedbackGenerator(style: .medium)

  init() {
    ble.onState = { [weak self] s in MainActor.assumeIsolated { self?.bleState = s } }
    ble.onLink = { [weak self] link in MainActor.assumeIsolated { self?.bluetooth(link) } }
    if let p = PairingStore.load() { use(p) }
    // Path updates arrive every few seconds with a cable or AWDL in play, and
    // a rebuild stalls the pointer until Bonjour resolves again. So rebuild
    // only when nothing answers; the browser adds new interfaces by itself.
    monitor.pathUpdateHandler = { [weak self] _ in
      Task { @MainActor in
        guard let self, self.now() - self.lastReply > 1.5 else { return }
        self.reconnect(awdl: self.awdlUp)
      }
    }
    monitor.start(queue: .main)
    probeTimer = Timer.scheduledTimer(withTimeInterval: Wire.keepalive, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.probe() }
    }
    // Retransmit unacked events quickly; idle when there are none.
    resendTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, !self.outbox.pending.isEmpty else { return }
        self.send(to: self.hotFlows(), identity: false)
      }
    }
  }

  var status: String {
    guard pairing != nil else { return "not paired" }
    guard let path else { return "searching…" }
    let ms = rtt.map { String(format: "%.0f ms", $0 * 1000) } ?? ""
    // "LAN 2" is a second LAN flow; the number only matters in Settings.
    return "\(path.split(separator: " ")[0]) · \(ms)"
  }

  // MARK: Pairing

  /// A link waiting for the user to confirm (`confirmPairing`).
  @Published var pendingPairing: Pairing?

  /// Any app or web page can open a tailmouse:// link, so nothing changes
  /// until the user confirms the Mac it names.
  func pair(with url: URL) -> Bool {
    guard let p = Pairing(url: url) else { return false }
    pendingPairing = p
    return true
  }

  func confirmPairing() {
    // The code holds the Mac's public key; this makes the key only this
    // phone and the Mac can work out.
    guard let p = pendingPairing?.claimed(with: PairingStore.identity) else { return }
    pendingPairing = nil
    PairingStore.save(p)
    use(p)
  }

  func forget() {
    PairingStore.save(nil)
    pairing = nil
    seal = nil
    ble.stop()
    teardown()
  }

  private func use(_ p: Pairing) {
    pairing = p
    seal = Seal(keyData: p.key)
    // Nothing meant for the previous Mac goes to this one.
    session = 0
    outbox = Outbox()
    motion = nil
    newestEcho = -.infinity
    macName = p.name
    ble.start(service: p.ble)
    reconnect()
  }

  // MARK: Input from the UI

  func touches(fingers: Int, x: Double, y: Double, time: Double) {
    handle(interpreter.update(fingers: fingers, x: x, y: y, time: time))
  }

  func tick(time: Double) {
    handle(interpreter.tick(time: time))
  }

  // Drawing mode: the finger's place on the surface (0…1) is the cursor's
  // place in the Mac's drawing area, and a finger down is the button down.
  private var stroke: UInt32 = 0
  private var stroking = false

  func draw(x: Double, y: Double) {
    if !stroking { stroke &+= 1 }
    motion = Motion(kind: .tablet, gesture: stroke, x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    // The Mac applies the position before the press, so the stroke starts here.
    if !stroking { stroking = true; outbox.push(.dragBegin, time: now()) }
    send(to: hotFlows(), identity: false)
  }

  func endStroke() {
    guard stroking else { return }
    stroking = false
    send(.dragEnd)
  }

  func send(_ event: Event) {
    outbox.push(event, time: now())
    send(to: hotFlows(), identity: false)
  }

  private func handle(_ outputs: [TouchInterpreter.Output]) {
    guard !outputs.isEmpty else { return }
    var dirty = false
    for o in outputs {
      switch o {
      case .motion(let m): motion = m; dirty = true
      case .event(let e):
        outbox.push(e, time: now())
        dirty = true
        if e == .dragBegin { dragHaptic.impactOccurred() }
      case .haptic: tapHaptic.impactOccurred()
      }
    }
    if dirty { send(to: hotFlows(), identity: false) }
  }

  // MARK: Paths

  /// Rebuild every flow. Called on pairing, network change and foregrounding.
  /// Without AWDL unless asked: a fresh start (launch, foreground, new
  /// pairing) tries the quiet paths first.
  func reconnect(awdl: Bool = false) {
    teardown()
    awdlUp = awdl && useAWDL
    lastReply = now()
    guard let p = pairing else { return }
    for host in p.hosts {
      open("Tailnet", NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: p.port)!, using: udp(p2p: false)))
    }
    let params = udp(p2p: awdlUp)
    let b = NWBrowser(for: .bonjour(type: Wire.bonjourType, domain: nil), using: params)
    b.browseResultsChangedHandler = { [weak self] results, _ in
      Task { @MainActor in self?.found(results) }
    }
    b.start(queue: .main)
    browser = b
  }

  private func found(_ results: Set<NWBrowser.Result>) {
    guard let p = pairing else { return }
    for r in results {
      guard case .service(let name, _, _, _) = r.endpoint, name == p.name else { continue }
      // One flow per interface, pinned to it. An unpinned UDP flow would settle
      // on Wi-Fi even where client isolation drops every packet.
      for iface in r.interfaces {
        // ponytail: anything that isn't Wi-Fi or AWDL counts as the cable, so
        // a USB-C Ethernet adapter on the phone reads "USB" here. The Mac's
        // own classification (`isPhoneUSB`) is what its route switches use.
        let label = iface.name.hasPrefix("awdl") ? "AWDL"
          : [.wifi, .loopback].contains(iface.type) ? "LAN" : PathPicker.wired
        guard awdlUp || label != "AWDL", pinned.insert(iface.name).inserted else { continue }
        let params = udp(p2p: awdlUp)
        params.requiredInterface = iface
        open(label, NWConnection(to: r.endpoint, using: params), iface: iface.name)
      }
    }
  }

  private func bluetooth(_ link: BLELink?) {
    flows[Self.bleLabel] = link
    paths = flows.keys.sorted()
    guard let link else { return picker.remove(path: Self.bleLabel) }
    link.onDatagram = { [weak self] data in MainActor.assumeIsolated { self?.received(data, via: Self.bleLabel) } }
    send(to: [link])
  }

  private func udp(p2p: Bool) -> NWParameters {
    let params = NWParameters.udp
    params.includePeerToPeer = p2p
    // Wi-Fi sends this ahead of bulk traffic (WMM voice queue).
    params.serviceClass = .interactiveVoice
    return params
  }

  private func open(_ label: String, _ c: NWConnection, iface: String? = nil) {
    var label = label
    var n = 2
    while flows[label] != nil { label = "\(label.split(separator: " ")[0]) \(n)"; n += 1 }
    flows[label] = c
    paths = flows.keys.sorted()
    c.stateUpdateHandler = { [weak self, weak c] state in
      Task { @MainActor in
        guard let self, let c, self.flows[label] === c else { return }
        switch state {
        case .ready: self.send(to: [c])   // the hello
        case .failed:
          // Unpinned, so the browser can open it again (cable plugged back in).
          if let iface { self.pinned.remove(iface) }
          self.flows[label] = nil
          self.picker.remove(path: label)
          self.paths = self.flows.keys.sorted()
        default: break
        }
      }
    }
    c.start(queue: .main)
    receive(label, c)
  }

  private func receive(_ label: String, _ c: NWConnection) {
    c.receiveMessage { [weak self] data, _, _, error in
      Task { @MainActor in
        guard let self else { return }
        if let data { self.received(data, via: label) }
        if error == nil, self.flows[label] === c { self.receive(label, c) }
      }
    }
  }

  private func received(_ data: Data, via label: String) {
    guard let reply = seal?.open(Reply.self, from: data),
          reply.echo >= newestEchoOnPath[label] ?? -.infinity, reply.echo <= now() else { return }
    newestEchoOnPath[label] = reply.echo
    // The Mac has this phone's key now; no need to say who is asking any more.
    if pairing?.claim != nil {
      pairing?.claim = nil
      PairingStore.save(pairing)
    }
    let t = now()
    lastReply = t
    picker.replied(path: label, rtt: t - reply.echo, now: t)
    // The Mac answers every packet, and a @Published write redraws the whole
    // UI on the thread that handles touches even when the value is the same.
    // So: publish only changes, and the RTT once a second from `probe`.
    if path != picker.active {
      path = picker.active
      rtt = path.flatMap(picker.rtt(of:))
    }
    guard reply.echo >= newestEcho else { return }
    newestEcho = reply.echo
    if reply.session != session {
      session = reply.session
      outbox.restart()
      motion = nil   // a total or a drawing position from the old session would jump the cursor
    }
    outbox.ack(reply.ack)
    if macName != reply.name { macName = reply.name }
    if let a = reply.aspect, a > 0.05, a < 20, a != aspect { aspect = a }
  }

  private func probe() {
    // Nothing has answered for a while (the Mac restarted or changed port):
    // start over, so Bonjour resolves the service again.
    // The first rebuild comes sooner and brings AWDL in, if it is allowed.
    let fallback = useAWDL && !awdlUp
    if pairing != nil, now() - lastReply > (fallback ? 2 : 5) { reconnect(awdl: true) }
    picker.choose(now: now())
    path = picker.active
    rtt = path.flatMap(picker.rtt(of:))
    send(to: Array(flows.values))
  }

  private func hotFlows() -> [Flow] {
    if let a = picker.active, let c = flows[a] { return [c] }
    return Array(flows.values)
  }

  /// `identity` (name, path) rides on hellos and the 1 s probe only:
  /// it is half of a pointer packet, and Bluetooth carries few bytes.
  private func send(to targets: [Flow], identity: Bool = true) {
    guard let seal, !targets.isEmpty else { return }
    // Before the Mac issues a session nothing would run, so send nothing but the hello.
    let live = session != 0
    let p = Packet(client: clientID, session: session, time: now(),
                   motion: live ? motion : nil, events: live ? outbox.pending : [],
                   // "iPhone" since iOS 16; the Mac looks up the host name itself.
                   name: identity ? UIDevice.current.name : nil,
                   via: identity ? picker.active.map { String($0.split(separator: " ")[0]) } : nil)
    guard var data = try? seal.seal(p) else { return }
    if let claim = pairing?.claim { data = Seal.claim(claim, data) }
    // Ready flows only. A flow that is still resolving or waiting for a route
    // queues every send, and cancelling it with a few thousand queued crashes
    // inside Network.framework (it frees the queue recursively).
    for c in targets where c.isReady { c.transmit(data) }
  }

  private func teardown() {
    browser?.cancel()
    browser = nil
    let kept = flows[Self.bleLabel]
    for (label, flow) in flows where label != Self.bleLabel { flow.stop() }
    flows = kept.map { [Self.bleLabel: $0] } ?? [:]
    pinned.removeAll()
    picker = PathPicker()
    paths = flows.keys.sorted()
    path = nil
    rtt = nil
  }

  private func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

/// The pairing lives in a file inside the app's container.
///
/// ponytail: not the Keychain. A sideloaded (SideStore re-signed) app may lack
/// a keychain access group, and the container is already sandboxed and
/// encrypted at rest. Move to the Keychain if the app ever ships signed.
enum PairingStore {
  private static var url: URL {
    URL.applicationSupportDirectory.appending(path: "pairing.json")
  }

  static func load() -> Pairing? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Pairing.self, from: data)
  }

  /// This phone's key pair for pairing, made once and kept when the pairing
  /// is forgotten: the Mac knows the phone by its public half, so pairing
  /// again replaces the phone's row instead of adding one.
  static var identity: Seal.PairingKey {
    let file = URL.applicationSupportDirectory.appending(path: "identity.key")
    if let d = try? Data(contentsOf: file), let k = try? Seal.PairingKey(rawRepresentation: d) { return k }
    let k = Seal.PairingKey()
    write(k.rawRepresentation, to: file)
    return k
  }

  static func save(_ p: Pairing?) {
    guard let p, let data = try? JSONEncoder().encode(p) else {
      try? FileManager.default.removeItem(at: url)
      return
    }
    write(data, to: url)
  }

  /// Protected until first unlock and kept out of backups: a restore to
  /// another phone must not carry the keys.
  private static func write(_ data: Data, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var u = url
    try? data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? u.setResourceValues(values)
  }
}
