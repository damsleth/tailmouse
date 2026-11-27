import AVFoundation
import SwiftUI
import TailmouseKit
import VisionKit

/// Keystrokes typed for the Mac (passwords included) stay away from
/// third-party keyboards, which can log or upload what they see.
final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   shouldAllowExtensionPointIdentifier id: UIApplication.ExtensionPointIdentifier) -> Bool {
    id != .keyboard
  }

  /// One orientation at a time, chosen in Settings: a trackpad that turns
  /// with the phone would turn under the finger.
  func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
    Mode.current.isLandscape ? .landscape : .portrait
  }

  /// Turn the screen to match the setting, now.
  static func applyOrientation() {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: Mode.current.isLandscape ? .landscape : .portrait))
      scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
  }
}

/// What the touch surface is, chosen in Settings.
enum Mode: String, CaseIterable, Identifiable {
  case trackpad, landscape, drawing

  static var current: Mode { UserDefaults.standard.string(forKey: "mode").flatMap(Mode.init) ?? .trackpad }
  var id: String { rawValue }
  /// A drawing area on a Mac is wide, so the tablet lies on its side too.
  var isLandscape: Bool { self != .trackpad }

  var title: String {
    switch self {
    case .trackpad: "Trackpad"
    case .landscape: "Trackpad, landscape"
    case .drawing: "Drawing tablet"
    }
  }
}

@main
struct TailmouseApp: App {
  @UIApplicationDelegateAdaptor private var delegate: AppDelegate
  @StateObject private var client = Client()
  @Environment(\.scenePhase) private var phase
  @AppStorage("sensitivity") private var sensitivity = 1.5
  @AppStorage("naturalScroll") private var naturalScroll = true
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
      .onChange(of: awdl) { applySettings(); client.reconnect() }
      // iOS tears down sockets in the background; start over on return.
      .onChange(of: phase) { if phase == .active { client.reconnect() } }
    }
  }

  private func applySettings() {
    client.interpreter.sensitivity = sensitivity
    client.interpreter.naturalScroll = naturalScroll
    client.useAWDL = awdl
  }
}

struct TrackpadScreen: View {
  @ObservedObject var client: Client
  @StateObject private var modifiers = Modifiers()
  @State private var typing = false
  @AppStorage("mode") private var mode = Mode.trackpad

  var body: some View {
    let landscape = mode.isLandscape, drawing = mode == .drawing
    // Landscape has little height: the header goes beside the pad, not above it.
    let layout = landscape ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                           : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
    let header = landscape ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
    layout {
      header {
        VStack(alignment: .leading, spacing: 2) {
          Text(client.macName ?? "Mac").font(landscape ? .title2.bold() : .largeTitle.bold()).lineLimit(1)
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
      .frame(maxWidth: landscape ? 130 : nil)
      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: 24).fill(Color(white: 0.11))
        Text(drawing ? "Drawing tablet · touch to draw · the area is chosen on the Mac"
                     : "Tap · 2-finger tap = right-click · 2-finger drag = scroll · Hold, then drag")
          .font(.footnote).foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
          .padding()
        TrackpadSurface(client: client, drawing: drawing)
        KeyboardCatcher(active: $typing, client: client, modifiers: modifiers)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
      }
      // The Mac's area has a shape; match it, or a circle comes out an ellipse.
      .modifier(Shaped(aspect: drawing ? client.aspect : nil))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding()
  }
}

/// A fixed shape, or all the room there is. (`aspectRatio(nil)` is neither:
/// it shrinks the view to its ideal size.)
private struct Shaped: ViewModifier {
  let aspect: Double?

  func body(content: Content) -> some View {
    if let aspect { content.aspectRatio(aspect, contentMode: .fit) } else { content }
  }
}

struct SettingsScreen: View {
  @ObservedObject var client: Client
  @AppStorage("sensitivity") private var sensitivity = 1.5
  @AppStorage("naturalScroll") private var naturalScroll = true
  @AppStorage("awdl") private var awdl = true
  @AppStorage("mode") private var mode = Mode.trackpad

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
          Picker("Mode", selection: $mode) {
            ForEach(Mode.allCases) { Text($0.title).tag($0) }
          }
          .onChange(of: mode) { AppDelegate.applyOrientation() }
        } footer: {
          Text(mode == .drawing
               ? "The surface is the drawing area chosen on the Mac (menu bar › Drawing Area…). A touch puts the cursor there and holds the mouse button down."
               : "Landscape turns the app on its side, so the pad is wide like a Mac trackpad.")
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
  @State private var scanning = false
  @State private var noCamera = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Image("Wordmark").resizable().scaledToFit().frame(height: 44)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Tailmouse")
      Text("Pair with your Mac").font(.largeTitle.bold())
      Text("On the Mac, open Tailmouse from the menu bar and choose Pair iPhone under Devices. Then scan the code here.")
        .foregroundStyle(.secondary)
      HStack {
        Button(scanning ? "Stop scanning" : "Scan QR code") {
          if scanning { scanning = false; return }
          Task {
            // The scanner is absent in the simulator and on very old phones.
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            let ok = granted && DataScannerViewController.isSupported
            scanning = ok
            noCamera = !ok
          }
        }
        .buttonStyle(.borderedProminent)
        Button("Paste pairing link") {
          let s = UIPasteboard.general.url ?? UIPasteboard.general.string.flatMap(URL.init(string:))
          failed = !(s.map(client.pair(with:)) ?? false)
        }
        .buttonStyle(.bordered)
      }
      if failed { Text("That's not a Tailmouse pairing link.").foregroundStyle(.red) }
      if noCamera {
        Text("Tailmouse can't use the camera. Allow it in Settings › Apps › Tailmouse, or scan the code with the Camera app.")
          .foregroundStyle(.red)
      }
      if scanning {
        // Other QR codes are ignored; a pairing link goes to the usual confirmation.
        QRScanner { if let u = URL(string: $0), client.pair(with: u) { scanning = false } }
          .aspectRatio(1, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 16))
          .frame(maxWidth: .infinity)
      }
      Spacer(minLength: 0)
    }
    .padding(24)
  }
}

struct QRScanner: UIViewControllerRepresentable {
  let found: (String) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(found: found) }

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let c = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
    c.delegate = context.coordinator
    try? c.startScanning()
    return c
  }

  func updateUIViewController(_ c: DataScannerViewController, context: Context) {}

  static func dismantleUIViewController(_ c: DataScannerViewController, coordinator: Coordinator) {
    c.stopScanning()
  }

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    let found: (String) -> Void
    init(found: @escaping (String) -> Void) { self.found = found }

    func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
      for case .barcode(let b) in items { b.payloadStringValue.map(found) }
    }
  }
}
