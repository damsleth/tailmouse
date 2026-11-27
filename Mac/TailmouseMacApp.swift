import ApplicationServices
import CoreWLAN
import ServiceManagement
import SwiftUI
import TailmouseKit

@main
struct TailmouseMacApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      MenuContent(model: model)
    } label: {
      Image("MenuBarIcon")
    }
    Settings {
      MainView(model: model)
    }
    Window("Pair iPhone", id: "pair") {
      PairView(model: model)
    }
    .windowResizability(.contentSize)
  }
}

@MainActor
final class AppModel: ObservableObject {
  @Published var devices: [DeviceRecord]
  @Published var state = "Starting…"
  @Published var keychainError: String?
  @Published var trusted = AXIsProcessTrusted()
  /// The code on screen while the Pair window is open. Its `key` is a public
  /// key made for this code; the phone that claims it gets a key of its own.
  @Published private(set) var pairing: Pairing?
  /// One key per paired phone, by device id; in the Keychain.
  private var phones: [String: Data] = [:]
  private let name = Host.current().localizedName ?? "Mac"
  /// The Bluetooth service this Mac advertises; in every pairing code.
  private let bleService: UUID

  @Published var port: Int {
    didSet {
      guard port != oldValue else { return }
      guard (1024...65535).contains(port) else { port = oldValue; return }
      defaults.set(port, forKey: "port")
      pairing?.port = UInt16(port)
      server.apply(config)
    }
  }
  @Published var routes: Set<Route> {
    didSet {
      defaults.set(routes.map(\.rawValue), forKey: "routes")
      server.apply(config)
    }
  }
  @Published var momentum: Double {
    didSet {
      defaults.set(momentum, forKey: "momentum")
      server.apply(config)
    }
  }

  /// AWDL lives on 2.4 and 5 GHz. On a 6 GHz network the one radio leaves the
  /// network about twice a second to serve it, and every Wi-Fi route stalls
  /// (measured: 120 pings in 500 over 30 ms with the AWDL route on, 0 with it
  /// off). So there the route is off whatever the switch says.
  // ponytail: 6 GHz only, because that is what was measured. A 5 GHz network
  // off channels 44 and 149 probably hops too; widen this when someone measures it.
  @Published private(set) var on6GHz = Radio.on6GHz {
    didSet { if on6GHz != oldValue { server.apply(config) } }
  }
  /// AirDrop open to everyone keeps the radio hopping the same way.
  @Published private(set) var airDropEveryone = Radio.airDropEveryone

  var awdlStutters: Bool { on6GHz && airDropEveryone }
  /// The way out: on a 6 GHz network that isolates clients, a stuttering AWDL
  /// link can still beat a relayed tailnet or Bluetooth.
  @Published var awdlAnyway: Bool {
    didSet {
      defaults.set(awdlAnyway, forKey: "awdlOn6GHz")
      server.apply(config)
    }
  }
  /// The AWDL switch means nothing right now.
  var awdlLocked: Bool { on6GHz && !awdlAnyway }

  /// What the phone's drawing mode maps to, and where that is right now: a
  /// window moves, so the timer below reads it again.
  @Published var tablet: TabletTarget {
    didSet {
      if let data = try? JSONEncoder().encode(tablet) { defaults.set(data, forKey: "tablet") }
      tabletRegion = tablet.region
    }
  }
  @Published private(set) var tabletRegion: CGRect? {
    didSet { if tabletRegion != oldValue { server.apply(config) } }
  }
  private var picker: TabletPicker?

  func chooseTablet() {
    guard picker == nil else { return }
    picker = TabletPicker(current: tablet.region == nil ? .main : tablet) { [weak self] chosen in
      self?.picker = nil
      if let chosen { self?.tablet = chosen }
    }
    picker?.show()
  }

  private let defaults = UserDefaults.standard
  private let server: Server
  private var axTimer: Timer?

  var config: ServerConfig {
    // A closed window or an unplugged display: the main display until it is chosen again.
    ServerConfig(port: UInt16(port), routes: Self.usable(routes, on6GHz: awdlLocked),
                 momentum: momentum, tablet: tabletRegion ?? TabletTarget.main.region)
  }

  static func usable(_ routes: Set<Route>, on6GHz: Bool) -> Set<Route> {
    on6GHz ? routes.subtracting([.awdl]) : routes
  }

  init() {
    let d = UserDefaults.standard
    var keys: [String: Data] = [:]
    do {
      phones = try KeyStore.load("phones").flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
      keys = phones
      #if DEBUG
      // `make sim` pairs the simulator with this key, without a QR scan. Kept
      // out of `phones`, so a Release build never accepts it.
      keys["sim"] = try KeyStore.load("sim-key") ?? {
        let k = Seal.newKey().data
        KeyStore.save(k, "sim-key")
        return k
      }()
      #endif
    } catch {
      // Don't overwrite keys we couldn't read; no pairing until relaunch.
      keychainError = "Couldn't read the phones' keys from the Keychain (\(error)). Relaunch to try again."
    }
    // The key every phone shared, and the PIN: both gone.
    KeyStore.delete("pairing-key")
    KeyStore.delete("pin")
    bleService = d.string(forKey: "bleService").flatMap(UUID.init) ?? {
      let id = UUID()
      d.set(id.uuidString, forKey: "bleService")
      return id
    }()
    let port = (d.object(forKey: "port") as? Int).flatMap { (1024...65535).contains($0) ? $0 : nil } ?? Int(Wire.defaultPort)
    var routes = Set((d.stringArray(forKey: "routes") ?? Route.allCases.map(\.rawValue)).compactMap(Route.init))
    // Routes added after the first release: on by default for saved settings too.
    for (route, seen) in [(Route.usb, "routesHaveUSB"), (.ble, "routesHaveBLE")] where !d.bool(forKey: seen) {
      routes.insert(route)
      d.set(true, forKey: seen)
      d.set(routes.map(\.rawValue), forKey: "routes")
    }
    let momentum = d.object(forKey: "momentum") as? Double ?? 0.5
    let devices = d.data(forKey: "devices").flatMap { try? JSONDecoder().decode([DeviceRecord].self, from: $0) } ?? []
    (self.port, self.routes, self.devices) = (port, routes, devices)
    self.momentum = momentum
    awdlAnyway = d.bool(forKey: "awdlOn6GHz")
    let tablet = d.data(forKey: "tablet").flatMap { try? JSONDecoder().decode(TabletTarget.self, from: $0) } ?? .main
    self.tablet = tablet
    tabletRegion = tablet.region
    server = Server(keys: keys, bleService: bleService, name: name, devices: devices, config: ServerConfig(
      port: UInt16(port), routes: Self.usable(routes, on6GHz: Radio.on6GHz && !d.bool(forKey: "awdlOn6GHz")),
      momentum: momentum, tablet: tablet.region ?? TabletTarget.main.region))
    server.onPaired = { [weak self] id, key in
      guard let self else { return }
      self.phones[id] = key
      self.savePhones()
      self.pairing = nil   // used up
    }
    server.onDevices = { [weak self] list in
      guard let self else { return }
      // Assign every tick even when equal: "connected" is relative to now.
      let changed = list != self.devices
      self.devices = list
      if changed, let data = try? JSONEncoder().encode(list) { self.defaults.set(data, forKey: "devices") }
    }
    server.onState = { [weak self] s in self?.state = s }
    server.start()
    axTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.trusted = AXIsProcessTrusted()
        // Tailscale may come up after launch; keep the QR current.
        let hosts = tailnetAddresses()
        if let p = self?.pairing, p.hosts != hosts { self?.pairing?.hosts = hosts }
        // The Mac roams between bands, and AirDrop is set elsewhere.
        let (six, everyone) = (Radio.on6GHz, Radio.airDropEveryone)
        if self?.on6GHz != six { self?.on6GHz = six }
        if self?.airDropEveryone != everyone { self?.airDropEveryone = everyone }
        if let region = self?.tablet.region, self?.tabletRegion != region { self?.tabletRegion = region }
        else if self?.tablet.region == nil, self?.tabletRegion != nil { self?.tabletRegion = nil }
      }
    }
  }

  var connected: [DeviceRecord] { devices.filter(\.isConnected) }

  func promptAccessibility() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    trusted = AXIsProcessTrustedWithOptions(opts)
  }

  /// Shows a new code. The first phone to claim it agrees on a key with the
  /// Mac; the Mac accepts a claim only while the Pair window is open.
  func beginPairing() {
    guard keychainError == nil else { return }
    let key = Seal.PairingKey()
    pairing = Pairing(key: key.publicKey.rawRepresentation, ble: bleService, name: name, port: UInt16(port), hosts: tailnetAddresses())
    server.offer((id: UUID().uuidString, key: key))
  }

  func endPairing() {
    pairing = nil
    server.offer(nil)
  }

  private func savePhones() {
    guard keychainError == nil, let data = try? JSONEncoder().encode(phones) else { return }
    KeyStore.save(data, "phones")
  }

  /// Deletes the phone's key. It has to pair again to come back.
  func forget(_ id: String) {
    devices.removeAll { $0.id == id }
    phones[id] = nil
    savePhones()
    server.remove(phone: id)
    if let data = try? JSONEncoder().encode(devices) { UserDefaults.standard.set(data, forKey: "devices") }
  }

  var launchAtLogin: Bool {
    get { SMAppService.mainApp.status == .enabled }
    set {
      try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
      objectWillChange.send()
    }
  }

  func route(_ r: Route) -> Binding<Bool> {
    Binding(get: { self.routes.contains(r) && !(r == .awdl && self.awdlLocked) },
            set: { on in if on { self.routes.insert(r) } else { self.routes.remove(r) } })
  }
}

struct MenuContent: View {
  @ObservedObject var model: AppModel
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    if model.connected.isEmpty {
      Text("No iPhone connected")
    } else {
      ForEach(model.connected) { Text("\($0.name) · \($0.via)") }
    }
    Text(model.state)
    if let e = model.keychainError { Text(e) }
    if model.awdlStutters { Text("AirDrop is open to Everyone: the pointer will stutter") }
    if !model.trusted {
      Button("Grant Accessibility…") { model.promptAccessibility() }
    }
    Divider()
    Button("Open Tailmouse…") {
      openSettings()
      NSApp.activate()
    }
    .keyboardShortcut(",")
    Button("Drawing Area…") { model.chooseTablet() }
    Divider()
    Button("Quit Tailmouse") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
  }
}

// MARK: - Main window

struct MainView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    TabView {
      Tab("Devices", systemImage: "iphone") { DevicesTab(model: model) }
      Tab("Settings", systemImage: "slider.horizontal.3") { SettingsTab(model: model) }
      Tab("About", systemImage: "info.circle") { AboutTab() }
    }
    .frame(width: 600)
  }
}

struct DevicesTab: View {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow
  @State private var selection = Set<String>()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Table(model.devices, selection: $selection) {
        TableColumn("Name") { d in
          HStack(spacing: 6) {
            Circle().fill(d.isConnected ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            Text(d.name)
          }
        }
        TableColumn("Connection") { d in Text(d.via.isEmpty ? "–" : d.via) }
          .width(100)
        TableColumn("Last active") { d in
          Text(d.isConnected ? "Now" : d.lastSeen == .distantPast ? "Never" : d.lastSeen.formatted(.relative(presentation: .named)))
        }
        .width(140)
      }
      .contextMenu(forSelectionType: String.self) { ids in
        Button("Remove") { ids.forEach(model.forget) }
      }
      HStack(alignment: .top) {
        Text("Each iPhone has its own key. Removing one deletes its key: it has to pair again to come back.")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Remove") { selection.forEach(model.forget); selection = [] }
          .disabled(selection.isEmpty)
        Button("Pair iPhone…") { openWindow(id: "pair") }
      }
    }
    .padding(20)
    .frame(height: 340)
  }
}

struct SettingsTab: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Form {
      LabeledContent("General:") {
        VStack(alignment: .leading, spacing: 10) {
          Toggle("Launch Tailmouse at login",
                 isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
          HStack {
            Circle().fill(model.trusted ? Color.green : Color.orange).frame(width: 10, height: 10)
            Text(model.trusted ? "Accessibility granted" : "Accessibility not granted")
            Spacer()
            if !model.trusted { Button("Grant…") { model.promptAccessibility() } }
          }
        }
      }
      LabeledContent("Scrolling:") {
        VStack(alignment: .leading, spacing: 4) {
          Picker("Momentum", selection: $model.momentum) {
            Text("Off").tag(0.0)
            Text("Light").tag(0.3)
            Text("Normal").tag(0.5)
            Text("Heavy").tag(0.8)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(width: 280)
          note("How far a two-finger scroll keeps gliding after you lift your fingers, like a Mac trackpad.")
        }
      }
      .padding(.top, 12)
      LabeledContent("Listening port:") {
        VStack(alignment: .leading, spacing: 4) {
          TextField("Port", value: $model.port, format: .number.grouping(.never))
            .labelsHidden()
            .frame(width: 80)
          note("UDP, \(Wire.defaultPort) by default. Phones that connect over the tailnet have to scan the pairing code again after a change.")
        }
      }
      .padding(.top, 12)
      LabeledContent("Routes:") {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(Route.allCases) { r in
            Toggle(isOn: model.route(r)) {
              VStack(alignment: .leading, spacing: 2) {
                Text(r.title)
                note(r == .awdl && model.awdlLocked ? Route.awdlOn6GHz : r.detail)
              }
            }
            .accessibilityLabel(r.title)
            .disabled(r == .awdl && model.awdlLocked)
            if r == .awdl && model.on6GHz {
              VStack(alignment: .leading, spacing: 4) {
                Toggle("Allow it on 6 GHz networks anyway", isOn: $model.awdlAnyway)
                  .accessibilityLabel("Allow AWDL on 6 GHz networks anyway")
                if model.awdlAnyway && model.routes.contains(.awdl) {
                  Label("The pointer stops about twice a second on every Wi-Fi route while this is on. For networks that block devices from each other, where AWDL is the only Wi-Fi route that gets through.",
                        systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
              }
              .padding(.leading, 20)
            }
          }
          if model.awdlStutters {
            Label {
              VStack(alignment: .leading, spacing: 4) {
                Text("AirDrop is open to Everyone. On this 6 GHz network that makes the pointer stop about twice a second on every Wi-Fi route. Set AirDrop to Contacts Only or No One.")
                  .fixedSize(horizontal: false, vertical: true)
                Button("Open AirDrop Settings…") { NSWorkspace.shared.open(Radio.airDropSettings) }
              }
            } icon: {
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.caption)
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
          }
          note("The iPhone uses the cable when it is plugged in, otherwise the fastest route that answers, and switches when one stops.")
        }
      }
      .padding(.top, 12)
    }
    .formStyle(.columns)
    .padding(24)
  }

  private func note(_ s: String) -> some View {
    Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }
}

extension Route {
  var title: String {
    switch self {
    case .usb: "USB cable"
    case .lan: "Local network"
    case .awdl: "Peer-to-peer Wi-Fi (AWDL)"
    case .tailnet: "Tailnet"
    case .ble: "Bluetooth"
    }
  }

  static let awdlOn6GHz = "Off while this Mac is on a 6 GHz Wi-Fi network. AWDL works on 2.4 and 5 GHz only, so the Wi-Fi radio would leave the network about twice a second and every Wi-Fi route would stutter. It comes back on a 2.4 or 5 GHz network, or with the switch below."

  var detail: String {
    switch self {
    case .usb: "The iPhone plugged into this Mac. The fastest and steadiest route; used whenever it answers."
    case .lan: "Wi-Fi or Ethernet, found with Bonjour. Blocked on networks that isolate clients."
    case .awdl: "The direct link AirDrop uses. Works on isolated networks when the iPhone is nearby."
    case .tailnet: "Through Tailscale, from anywhere. Slow when Tailscale has to relay (DERP)."
    case .ble: "Bluetooth LE, nearby. Slower than Wi-Fi but steady where Wi-Fi stutters; switch the Wi-Fi routes off to use it."
    }
  }
}

struct AboutTab: View {
  private let info = Bundle.main.infoDictionary ?? [:]

  var body: some View {
    VStack(spacing: 10) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 112, height: 112)
      Text("Tailmouse").font(.title.bold())
      Text("Version \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))")
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      Text("Your iPhone as a trackpad and keyboard, over the local network, peer-to-peer Wi-Fi or Tailscale.")
        .multilineTextAlignment(.center)
        .padding(.top, 4)
      // REPO_SLUG (owner/repo) comes from Config/Local.xcconfig; no link without it.
      if let slug = info["TailmouseRepo"] as? String, !slug.isEmpty,
         let url = URL(string: "https://github.com/\(slug)") {
        Link("github.com/\(slug)", destination: url)
      }
      Text("Pointer model and input details from Entangle by Gabriel Donadel (MIT).")
        .font(.caption).foregroundStyle(.secondary)
        .padding(.top, 8)
    }
    .padding(32)
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Pairing

struct PairView: View {
  @ObservedObject var model: AppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 14) {
      if let pairing = model.pairing {
        if let img = qrImage(for: pairing.url.absoluteString) {
          Image(decorative: img, scale: 2)
            .interpolation(.none)
            .padding(10)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
        }
        Text("In Tailmouse on the iPhone, tap “Scan QR code”.")
          .font(.callout)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        Label {
          Text("This code pairs one iPhone: the first to scan it, which can then control your mouse and keyboard. This window closes when a phone has paired. If your iPhone does not connect then, another phone got there first: remove it under Devices. An unused code stops working when this window closes.")
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.caption)
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        Text(pairing.hosts.isEmpty
             ? "Tailscale is not running on this Mac: LAN and AWDL only."
             : "Tailnet: \(pairing.hosts.joined(separator: ", "))")
          .font(.caption).foregroundStyle(.secondary)
        Button("Copy Link") { copySecret(pairing.url.absoluteString) }
      } else if let e = model.keychainError {
        Text(e).fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(24)
    .frame(width: 340)
    .onAppear { model.beginPairing() }
    // The code is spent once a phone has paired: the Devices list shows it.
    .onChange(of: model.pairing == nil) { _, used in if used { dismiss() } }
    .onDisappear { model.endPairing() }
  }
}

/// Copies the pairing link marked as concealed, so clipboard managers skip it,
/// and clears it after a minute if nothing else was copied since.
func copySecret(_ s: String) {
  let pb = NSPasteboard.general
  pb.clearContents()
  pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
  pb.setString(s, forType: .string)
  pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
  let count = pb.changeCount
  DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
    if pb.changeCount == count { pb.clearContents() }
  }
}

/// What macOS says about the two things that make the Wi-Fi radio hop.
enum Radio {
  static let airDropSettings = URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")!

  static var on6GHz: Bool { CWWiFiClient.shared().interface()?.wlanChannel()?.channelBand == .band6GHz }

  static var airDropEveryone: Bool {
    let app = "com.apple.sharingd" as CFString
    CFPreferencesAppSynchronize(app)
    return CFPreferencesCopyAppValue("DiscoverableMode" as CFString, app) as? String == "Everyone"
  }
}
