import SwiftUI
import TailmouseKit
import UIKit

/// Latched modifiers, applied to the next key and then cleared.
@MainActor
final class Modifiers: ObservableObject {
  @Published var mods: Mods = []

  func toggle(_ m: Mods) {
    if mods.contains(m) { mods.remove(m) } else { mods.insert(m) }
  }
}

/// An invisible view that owns the iOS keyboard while it is first responder.
struct KeyboardCatcher: UIViewRepresentable {
  @Binding var active: Bool
  let client: Client
  let modifiers: Modifiers

  func makeUIView(context: Context) -> KeyCatcherView {
    let v = KeyCatcherView()
    v.client = client
    v.modifiers = modifiers
    let bar = UIHostingController(rootView: KeyBar(client: client, modifiers: modifiers))
    bar.view.backgroundColor = .clear
    bar.sizingOptions = .intrinsicContentSize
    bar.view.frame.size.height = 52
    v.bar = bar
    v.onResign = { active = false }
    return v
  }

  func updateUIView(_ v: KeyCatcherView, context: Context) {
    if active && !v.isFirstResponder { v.becomeFirstResponder() }
    if !active && v.isFirstResponder { v.resignFirstResponder() }
  }
}

final class KeyCatcherView: UIView, UIKeyInput {
  weak var client: Client?
  weak var modifiers: Modifiers?
  var bar: UIHostingController<KeyBar>?
  var onResign: (() -> Void)?

  // Plain keystrokes: no autocorrect, capitals, smart quotes or dashes.
  var autocorrectionType: UITextAutocorrectionType = .no
  var autocapitalizationType: UITextAutocapitalizationType = .none
  var spellCheckingType: UITextSpellCheckingType = .no
  var smartQuotesType: UITextSmartQuotesType = .no
  var smartDashesType: UITextSmartDashesType = .no
  var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
  var keyboardType: UIKeyboardType = .asciiCapable
  var inlinePredictionType: UITextInlinePredictionType = .no

  override var canBecomeFirstResponder: Bool { true }
  override var inputAccessoryView: UIView? { bar?.view }

  override func resignFirstResponder() -> Bool {
    let r = super.resignFirstResponder()
    onResign?()
    return r
  }

  var hasText: Bool { true }   // so backspace always fires

  func insertText(_ text: String) {
    guard let client else { return }
    let mods = modifiers?.mods ?? []
    if text == "\n" {
      client.send(.key(.enter, mods))
    } else if !mods.isEmpty, text.count == 1, let c = text.first {
      client.send(.char(c, mods))
    } else {
      client.send(.text(text))
    }
    modifiers?.mods = []
  }

  func deleteBackward() {
    client?.send(.key(.backspace, modifiers?.mods ?? []))
    modifiers?.mods = []
  }
}

/// Accessory bar above the iOS keyboard: modifiers and the keys iOS lacks.
struct KeyBar: View {
  let client: Client
  @ObservedObject var modifiers: Modifiers

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        mod("⌘", .command)
        mod("⌥", .option)
        mod("⌃", .control)
        mod("⇧", .shift)
        key("esc", .escape)
        key("⇥", .tab)
        key("←", .left)
        key("↓", .down)
        key("↑", .up)
        key("→", .right)
        key("⌦", .forwardDelete)
      }
      .padding(.horizontal, 8)
    }
    .frame(height: 52)
    .background(.bar)
  }

  private func mod(_ label: String, _ m: Mods) -> some View {
    Button(label) { modifiers.toggle(m) }
      .buttonStyle(.bordered)
      .tint(modifiers.mods.contains(m) ? .accentColor : .secondary)
      .font(.title3)
  }

  private func key(_ label: String, _ k: Key) -> some View {
    Button(label) {
      client.send(.key(k, modifiers.mods))
      modifiers.mods = []
    }
    .buttonStyle(.bordered)
    .tint(.secondary)
    .font(.title3)
  }
}
