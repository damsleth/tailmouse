import SwiftUI
import TailmouseKit

/// Keystrokes typed for the Mac (passwords included) stay away from
/// third-party keyboards, which can log or upload what they see.
final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   shouldAllowExtensionPointIdentifier id: UIApplication.ExtensionPointIdentifier) -> Bool {
    id != .keyboard
  }
}

@main
struct TailmouseApp: App {
  @UIApplicationDelegateAdaptor private var delegate: AppDelegate
  @StateObject private var client = Client()
  @Environment(\.scenePhase) private var phase
  @AppStorage("sensitivity") private var sensitivity = 1.5
  @AppStorage("naturalScroll") private var naturalScroll = true
  @AppStorage("deviceName") private var deviceName = ""
  @AppStorage("awdl") private var awdl = true

  var body: some Scene {
    WindowGroup {
      Group {
        if client.pairing == nil {
          PairScreen(client: client)
        } else {
          TabView {
            Tab("Trackpad", systemImage: "hand.point.up.left") { TrackpadScreen(client: client) }
            Tab("Settings", systemImage: "gear") { SettingsScreen(client: client) }
          }
        }
      }
      .preferredColorScheme(.dark)
      .onOpenURL { _ = client.pair(with: $0) }
      .alert("Pair with “\(client.pendingPairing?.name ?? "")”?",
             isPresented: Binding(get: { client.pendingPairing != nil }, set: { if !$0 { client.pendingPairing = nil } })) {
        Button("Pair") { client.confirmPairing() }
        Button("Cancel", role: .cancel) { client.pendingPairing = nil }
      } message: {
        Text(client.pairing.map { "This replaces \($0.name). " } ?? "")
          + Text("Your touches and typing will go to this Mac. Only pair with a code shown on your own Mac.")
      }
      .onAppear(perform: applySettings)
      .onChange(of: sensitivity) { applySettings() }
      .onChange(of: naturalScroll) { applySettings() }
      .onChange(of: deviceName) { applySettings() }
      .onChange(of: awdl) { applySettings(); client.reconnect() }
      // iOS tears down sockets in the background; start over on return.
      .onChange(of: phase) { if phase == .active { client.reconnect() } }
    }
  }

  private func applySettings() {
    client.interpreter.sensitivity = sensitivity
    client.interpreter.naturalScroll = naturalScroll
    client.deviceName = deviceName.isEmpty ? UIDevice.current.name : deviceName
    client.useAWDL = awdl
  }
}

struct TrackpadScreen: View {
  @ObservedObject var client: Client
  @StateObject private var modifiers = Modifiers()
  @State private var typing = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(client.macName ?? "Mac").font(.largeTitle.bold())
          Text(client.status).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
        }
        Spacer()
        Button { typing.toggle() } label: {
          Image(systemName: typing ? "keyboard.chevron.compact.down" : "keyboard")
            .font(.title2)
            .frame(width: 56, height: 56)
        }
        .buttonStyle(.glass)
        .clipShape(Circle())
      }
      if client.needsPin {
        PinEntry(client: client)
      } else {
      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: 24).fill(Color(white: 0.11))
        Text("Tap · 2-finger tap = right-click · 2-finger drag = scroll · Hold, then drag")
          .font(.footnote).foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
          .padding()
        TrackpadSurface(client: client)
        KeyboardCatcher(active: $typing, client: client, modifiers: modifiers)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
      }
      }
    }
    .padding()
  }
}

struct SettingsScreen: View {
  @ObservedObject var client: Client
  @AppStorage("sensitivity") private var sensitivity = 1.5
  @AppStorage("naturalScroll") private var naturalScroll = true
  @AppStorage("deviceName") private var deviceName = ""
  @AppStorage("awdl") private var awdl = true

  var body: some View {
    NavigationStack {
      Form {
        Section("Connection") {
          LabeledContent("Mac", value: client.macName ?? "–")
          LabeledContent("Status", value: client.status)
          LabeledContent("Paths", value: client.paths.isEmpty ? "–" : client.paths.joined(separator: ", "))
          LabeledContent("Bluetooth", value: client.bleState)
          Button("Reconnect") { client.reconnect() }
        }
        Section {
          Toggle("Use AWDL", isOn: $awdl)
        } footer: {
          Text("Peer-to-peer Wi-Fi reaches the Mac where the network blocks devices from each other. Used only when nothing else answers, because it makes every wireless route stutter.")
        }
        Section {
          TextField(UIDevice.current.name, text: $deviceName)
        } header: {
          Text("This iPhone's name")
        } footer: {
          Text("Shown in the Mac's device list.")
        }
        Section("Pointer speed") {
          Picker("Speed", selection: $sensitivity) {
            Text("Slow").tag(1.0)
            Text("Normal").tag(1.5)
            Text("Fast").tag(2.5)
          }
          .pickerStyle(.segmented)
        }
        Section {
          Toggle("Natural scrolling", isOn: $naturalScroll)
        } footer: {
          Text("Content follows your fingers. Turn off if scrolling feels inverted.")
        }
        Section {
          Button("Forget this Mac", role: .destructive) { client.forget() }
        }
      }
      .navigationTitle("Settings")
    }
  }
}

struct PairScreen: View {
  @ObservedObject var client: Client
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Image(systemName: "cursorarrow.rays").font(.system(size: 44))
      Text("Pair with your Mac").font(.largeTitle.bold())
      Text("On the Mac, open Tailmouse in the menu bar and choose Pair iPhone. Scan the code with the Camera app and tap “Open in Tailmouse”.")
        .foregroundStyle(.secondary)
      Button("Paste pairing link") {
        let s = UIPasteboard.general.url ?? UIPasteboard.general.string.flatMap(URL.init(string:))
        failed = !(s.map(client.pair(with:)) ?? false)
      }
      .buttonStyle(.bordered)
      if failed { Text("That's not a Tailmouse pairing link.").foregroundStyle(.red) }
      Spacer()
    }
    .padding(24)
  }
}

/// Replaces the trackpad while the Mac asks for its PIN.
struct PinEntry: View {
  @ObservedObject var client: Client
  @State private var pin = ""
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "lock.fill").font(.system(size: 36)).foregroundStyle(.secondary)
      Text("Enter the PIN set on \(client.macName ?? "the Mac")").font(.headline)
      SecureField("PIN", text: $pin)
        .keyboardType(.numberPad)
        .multilineTextAlignment(.center)
        .font(.title2.monospacedDigit())
        .frame(width: 140)
        .padding(10)
        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 10))
        .focused($focused)
        .onChange(of: pin) {
          pin = String(pin.filter(\.isNumber).prefix(4))
          if pin.count == 4 { client.enter(pin: pin); pin = "" }
        }
      if client.pinWasWrong { Text("Wrong PIN.").foregroundStyle(.red) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 24))
    .onAppear { focused = true }
  }
}
