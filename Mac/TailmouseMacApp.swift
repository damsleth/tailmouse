import ApplicationServices
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
  @Published var pairing: Pairing

  @Published var port: Int {
    didSet {
      guard port != oldValue else { return }
      guard (1024...65535).contains(port) else { port = oldValue; return }
      defaults.set(port, forKey: "port")
      pairing.port = UInt16(port)
      server.apply(config)
    }
  }
  @Published var routes: Set<Route> {
    didSet {
      defaults.set(routes.map(\.rawValue), forKey: "routes")
      server.apply(config)
    }
  }
  @Published var requirePin: Bool {
    didSet {
      defaults.set(requirePin, forKey: "requirePin")
      server.apply(config)
    }
  }
  @Published var pin: String {
    didSet {
      let clean = String(pin.filter { $0.isASCII && $0.isNumber }.prefix(4))
      guard clean == pin else { pin = clean; return }
      if pin.count == 4 { KeyStore.save(Data(pin.utf8), "pin") }
      if pin.isEmpty { KeyStore.delete("pin") }
      server.apply(config)
    }
  }

  private let defaults = UserDefaults.standard
  private let server: Server
  private var axTimer: Timer?

  var config: ServerConfig {
    ServerConfig(port: UInt16(port), routes: routes, pin: Self.effectivePin(requirePin, pin))
  }

  /// Required but not all four digits in yet: "" lets no one in (fail closed).
  static func effectivePin(_ required: Bool, _ pin: String) -> String? {
    required ? (pin.count == 4 ? pin : "") : nil
  }

  init() {
    let name = Host.current().localizedName ?? "Mac"
    let key: Data
    do {
      key = try KeyStore.load() ?? {
        let k = Seal.newKey().data
        KeyStore.save(k)
        return k
      }()
    } catch {
      // Don't overwrite a key we couldn't read; run unpaired until relaunch.
      key = Seal.newKey().data
      keychainError = "Couldn't read the pairing key from the Keychain (\(error)). Relaunch to try again."
    }
    let d = UserDefaults.standard
    let port = (d.object(forKey: "port") as? Int).flatMap { (1024...65535).contains($0) ? $0 : nil } ?? Int(Wire.defaultPort)
    let routes = Set((d.stringArray(forKey: "routes") ?? Route.allCases.map(\.rawValue)).compactMap(Route.init))
    let requirePin = d.bool(forKey: "requirePin")
    let pin = (try? KeyStore.load("pin")).flatMap { $0.flatMap { String(data: $0, encoding: .utf8) } } ?? ""
    let devices = d.data(forKey: "devices").flatMap { try? JSONDecoder().decode([DeviceRecord].self, from: $0) } ?? []
    (self.port, self.routes, self.requirePin, self.pin, self.devices) = (port, routes, requirePin, pin, devices)
    pairing = Pairing(key: key, name: name, port: UInt16(port), hosts: tailnetAddresses())
    server = Server(key: key, name: name, devices: devices, config: ServerConfig(
      port: UInt16(port), routes: routes, pin: Self.effectivePin(requirePin, pin)))
    server.onDevices = { [weak self] list in
      guard let self else { return }
      // Assign every tick even when equal: "connected" is relative to now.
      let changed = list != self.devices
      self.devices = list
      if changed, let data = try? JSONEncoder().encode(list) { self.defaults.set(data, forKey: "devices") }
    }
    server.onState = { [weak self] s in self?.state = s }
    server.onPinLocked = { [weak self] in
      self?.resetPairing()
      self?.state = "5 wrong PINs: made a new key"
    }
    server.start()
    axTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.trusted = AXIsProcessTrusted()
        // Tailscale may come up after launch; keep the QR current.
        let hosts = tailnetAddresses()
        if self?.pairing.hosts != hosts { self?.pairing.hosts = hosts }
      }
    }
  }

  var connected: [DeviceRecord] { devices.filter(\.isConnected) }

  func promptAccessibility() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    trusted = AXIsProcessTrustedWithOptions(opts)
  }

  func resetPairing() {
    let k = Seal.newKey().data
    KeyStore.save(k)
    pairing.key = k
    server.rekey(k)
  }

  func forget(_ id: String) {
    devices.removeAll { $0.id == id }
    server.forget(device: id)
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
    Binding(get: { self.routes.contains(r) },
            set: { on in if on { self.routes.insert(r) } else { self.routes.remove(r) } })
  }
}

struct MenuContent: View {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    if model.connected.isEmpty {
      Text("No iPhone connected")
    } else {
      ForEach(model.connected) { Text("\($0.name) · \($0.via)") }
    }
    Text(model.state)
    if let e = model.keychainError { Text(e) }
    if !model.trusted {
      Button("Grant Accessibility…") { model.promptAccessibility() }
    }
    Divider()
    Button("Open Tailmouse…") {
      openSettings()
      NSApp.activate()
    }
    .keyboardShortcut(",")
    Button("Pair iPhone…") {
      openWindow(id: "pair")
      NSApp.activate()
    }
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
          Text(d.isConnected ? "Now" : d.lastSeen.formatted(.relative(presentation: .named)))
        }
        .width(140)
      }
      .contextMenu(forSelectionType: String.self) { ids in
        Button("Remove from List") { ids.forEach(model.forget) }
      }
      HStack(alignment: .top) {
        Text("Removing a phone only clears it from this list. To lock a phone out, make a new key in Pair iPhone.")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
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
                note(r.detail)
              }
            }
            .accessibilityLabel(r.title)
          }
          note("The iPhone uses the fastest route that answers and switches when it stops.")
        }
      }
      .padding(.top, 12)
      LabeledContent("Security:") {
        VStack(alignment: .leading, spacing: 6) {
          Toggle("Require a PIN to connect", isOn: $model.requirePin)
            .accessibilityLabel("Require a PIN to connect")
          if model.requirePin {
            TextField("4 digits", text: $model.pin)
              .labelsHidden()
              .accessibilityLabel("PIN")
              .frame(width: 80)
          }
          if model.requirePin && model.pin.count < 4 {
            Text("Enter 4 digits. Until then no iPhone can connect.")
              .font(.caption).foregroundStyle(.orange)
          }
          note("Asked for on the iPhone, in addition to the pairing code. 5 different wrong PINs make a new key, and every iPhone has to scan again.")
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
    case .lan: "Local network"
    case .awdl: "Peer-to-peer Wi-Fi (AWDL)"
    case .tailnet: "Tailnet"
    }
  }

  var detail: String {
    switch self {
    case .lan: "Wi-Fi or Ethernet, found with Bonjour. Blocked on networks that isolate clients."
    case .awdl: "The direct link AirDrop uses. Works on isolated networks when the iPhone is nearby."
    case .tailnet: "Through Tailscale, from anywhere. Slow when Tailscale has to relay (DERP)."
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

  var body: some View {
    VStack(spacing: 14) {
      if let img = qrImage(for: model.pairing.url.absoluteString) {
        Image(decorative: img, scale: 2)
          .interpolation(.none)
          .padding(10)
          .background(.white, in: RoundedRectangle(cornerRadius: 12))
      }
      Text("Scan with the iPhone Camera, then tap “Open in Tailmouse”.")
        .font(.callout)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Label {
        Text("This code is the key to your Mac. Anyone who scans it or gets the link can control your mouse and keyboard until you press New Key. Keep it off shared screens.")
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      }
      .font(.caption)
      .padding(10)
      .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      Text(model.pairing.hosts.isEmpty
           ? "Tailscale is not running on this Mac: LAN and AWDL only."
           : "Tailnet: \(model.pairing.hosts.joined(separator: ", "))")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Copy Link") { copySecret(model.pairing.url.absoluteString) }
        Button("New Key", role: .destructive) { model.resetPairing() }
          .help("Unpairs every iPhone. They have to scan again.")
      }
    }
    .padding(24)
    .frame(width: 340)
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
