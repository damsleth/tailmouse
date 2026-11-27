import AppKit
import CoreGraphics
import TailmouseKit

/// Posts the CGEvents for a session's actions. Called on the server queue only.
///
/// Ported from Entangle's CursorController, ScrollController and KeyController
/// (MIT, (c) 2026 Gabriel Donadel). The non-obvious parts kept from there:
/// sub-pixel virtual cursor with resync after idle, `clickState` on every
/// press (and 1 on drag events), continuous + phase fields on scroll events,
/// the secondary-Fn flag on arrow/nav keys, explicit modifier down/up around
/// a key tap.
final class Input {
  private let source = CGEventSource(stateID: .hidSystemState)
  private let queue: DispatchQueue

  /// The glide after a two-finger scroll; its `tau` is set from the settings window.
  var momentum = Momentum(tau: 0.5)

  init(queue: DispatchQueue) { self.queue = queue }

  // MARK: Pointer

  /// Where we believe the cursor is, in full precision. Reading it back each
  /// frame would drop the sub-pixel part of slow moves.
  private var virtual: CGPoint?
  private var lastMove: TimeInterval = 0
  private static let resyncAfter: TimeInterval = 0.25
  private var dragging = false

  private var lastClickAt: TimeInterval = 0
  private var lastClickAtPoint = CGPoint.zero
  private var clickState: Int64 = 1

  /// The drawing area, in CG global coordinates; nil while there is none.
  var tablet: CGRect?

  private var bounds = CGRect.null
  private var boundsAt: TimeInterval = -.infinity

  func perform(_ action: Sessions.Action) {
    // A finger back on the glass stops the coast, as on a trackpad.
    stopCoasting()
    switch action {
    case .move(let dx, let dy): move(dx: dx, dy: dy)
    case .scroll(let dx, let dy, _): scroll(dx: dx, dy: dy, phase: 2)
    case .place(let x, let y):
      guard let r = tablet else { return }
      // maxX is one past the last pixel.
      post(move: CGPoint(x: r.minX + x * (r.width - 1), y: r.minY + y * (r.height - 1)))
    case .event(let e): handle(e)
    }
  }

  func releaseAll() {
    stopCoasting()
    if dragging {
      postButton(.left, down: false, state: 1)
      dragging = false
    }
    if scrolling { scroll(dx: 0, dy: 0, phase: 4) }
  }

  private func handle(_ e: Event) {
    switch e {
    case .click(let b):
      let state = advanceClickState()
      postButton(b, down: true, state: state)
      postButton(b, down: false, state: state)
    case .dragBegin:
      guard !dragging else { return }
      dragging = true
      clickState = 1
      lastClickAt = 0
      postButton(.left, down: true, state: 1)
    case .dragEnd:
      guard dragging else { return }
      postButton(.left, down: false, state: 1)
      dragging = false
    case .scrollBegin: scroll(dx: 0, dy: 0, phase: 1)
    case .scrollEnd: scroll(dx: 0, dy: 0, phase: 4)
    case .text(let s): type(s)
    case .key(let k, let mods): tap(Self.keyCodes[k]!, mods: mods)
    case .char(let c, var mods):
      if c.isUppercase { mods.insert(.shift) }
      if let code = Self.charCodes[Character(c.lowercased())] {
        tap(code, mods: mods)
      } else {
        type(String(c))   // no key for it on an ANSI layout; insert it as text
      }
    }
  }

  private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

  private func move(dx: Double, dy: Double) {
    let origin = currentLocation()
    post(move: clamp(CGPoint(x: origin.x + dx, y: origin.y + dy)))
  }

  private func post(move target: CGPoint) {
    virtual = target
    lastMove = now()
    let e = CGEvent(mouseEventSource: source, mouseType: dragging ? .leftMouseDragged : .mouseMoved,
                    mouseCursorPosition: target, mouseButton: .left)
    // Editors and terminals ignore drag events whose click count is 0.
    if dragging { e?.setIntegerValueField(.mouseEventClickState, value: 1) }
    e?.post(tap: .cghidEventTap)
  }

  /// Just after a move the system may not have caught up, and a drawing
  /// stroke presses the button in the same packet as the jump to its start.
  private func currentLocation() -> CGPoint {
    (now() - lastMove < Self.resyncAfter ? virtual : nil) ?? CGEvent(source: nil)?.location ?? .zero
  }

  /// ponytail: clamps to the union of displays, so the cursor can sit in the
  /// dead corner of mismatched screens; clamp per display if that bites.
  private func clamp(_ p: CGPoint) -> CGPoint {
    if now() - boundsAt > 2 {
      var count: UInt32 = 0
      CGGetActiveDisplayList(0, nil, &count)
      var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
      CGGetActiveDisplayList(count, &ids, &count)
      bounds = ids.map(CGDisplayBounds).reduce(CGRect.null) { $0.union($1) }
      boundsAt = now()
    }
    guard !bounds.isNull else { return p }
    return CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX - 1),
                   y: min(max(p.y, bounds.minY), bounds.maxY - 1))
  }

  /// macOS needs clickState 2/3 on the 2nd/3rd click of a series, or apps only
  /// ever see single clicks.
  private func advanceClickState() -> Int64 {
    let t = now(), p = currentLocation()
    let near = hypot(p.x - lastClickAtPoint.x, p.y - lastClickAtPoint.y) <= 5
    clickState = (t - lastClickAt <= NSEvent.doubleClickInterval && near) ? clickState + 1 : 1
    lastClickAt = t
    lastClickAtPoint = p
    return clickState
  }

  private func postButton(_ b: Button, down: Bool, state: Int64) {
    let type: CGEventType = switch (b, down) {
    case (.left, true): .leftMouseDown
    case (.left, false): .leftMouseUp
    case (.right, true): .rightMouseDown
    case (.right, false): .rightMouseUp
    }
    let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: currentLocation(),
                    mouseButton: b == .left ? .left : .right)
    e?.setIntegerValueField(.mouseEventClickState, value: state)
    e?.post(tap: .cghidEventTap)
  }

  // MARK: Scroll

  private var scrolling = false
  /// Sub-pixel remainder carried between frames.
  private var scrollCarry = (x: 0.0, y: 0.0)

  /// Phase: 1 began, 2 changed, 4 ended (kCGScrollPhase*).
  private func scroll(dx: Double, dy: Double, phase: Int64) {
    if phase == 1 { scrolling = true; scrollCarry = (0, 0) }
    if phase == 2 { momentum.record(t: now(), dx: dx, dy: dy) }
    if phase == 4 { scrolling = false }
    post(dx: dx, dy: dy, phase: phase, momentumPhase: 0)
    if phase == 4 { coast() }
  }

  private func post(dx: Double, dy: Double, phase: Int64, momentumPhase: Int64) {
    let x = dx + scrollCarry.x, y = dy + scrollCarry.y
    // Clamped: a scroll event carries Int32, and Int32(huge) traps.
    let ix = Int32(max(-10_000, min(10_000, x.rounded(.towardZero))))
    let iy = Int32(max(-10_000, min(10_000, y.rounded(.towardZero))))
    scrollCarry = (x - Double(ix), y - Double(iy))
    if (phase == 2 || momentumPhase == 2) && ix == 0 && iy == 0 { return }
    guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                          wheel1: iy, wheel2: ix, wheel3: 0) else { return }
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
    e.post(tap: .cghidEventTap)
  }

  // MARK: Momentum

  private var coastTimer: DispatchSourceTimer?
  private var coastLast: TimeInterval = 0

  private func coast() {
    let t = now()
    guard momentum.release(t: t) else { return }
    coastLast = t
    post(dx: 0, dy: 0, phase: 0, momentumPhase: 1)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: 1.0 / 120)
    timer.setEventHandler { [weak self] in self?.coastStep() }
    timer.resume()
    coastTimer = timer
  }

  private func coastStep() {
    let t = now()
    defer { coastLast = t }
    guard let d = momentum.step(dt: t - coastLast) else { stopCoasting(); return }
    post(dx: d.dx, dy: d.dy, phase: 0, momentumPhase: 2)
  }

  private func stopCoasting() {
    guard let timer = coastTimer else { return }
    timer.cancel()
    coastTimer = nil
    post(dx: 0, dy: 0, phase: 0, momentumPhase: 3)
  }

  // MARK: Keyboard

  /// Inserts text as Unicode, bypassing the Mac's keyboard layout and IME.
  private func type(_ text: String) {
    // A CGEvent carries at most 20 UTF-16 units; split on character boundaries.
    var chunk: [UniChar] = []
    func flush() {
      guard !chunk.isEmpty,
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
      down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
      up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
      chunk.removeAll()
    }
    for ch in text {
      let units = Array(String(ch).utf16)
      if chunk.count + units.count > 20 { flush() }
      chunk += units
    }
    flush()
  }

  private func tap(_ code: CGKeyCode, mods: Mods) {
    var flags: CGEventFlags = []
    var modKeys: [CGKeyCode] = []
    if mods.contains(.command) { flags.insert(.maskCommand); modKeys.append(0x37) }
    if mods.contains(.shift) { flags.insert(.maskShift); modKeys.append(0x38) }
    if mods.contains(.option) { flags.insert(.maskAlternate); modKeys.append(0x3A) }
    if mods.contains(.control) { flags.insert(.maskControl); modKeys.append(0x3B) }
    // Press modifiers for real so they don't stay latched in the window server
    // and bleed into the next click (a stuck ⌃ turns clicks into right-clicks).
    for m in modKeys { post(m, down: true, flags: flags) }
    var keyFlags = flags
    if Self.fnKeys.contains(code) { keyFlags.insert(.maskSecondaryFn) }
    post(code, down: true, flags: keyFlags)
    post(code, down: false, flags: keyFlags)
    for m in modKeys.reversed() { post(m, down: false, flags: []) }
  }

  private func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
    e?.flags = flags
    e?.post(tap: .cghidEventTap)
  }

  /// Arrow and navigation keys carry the secondary-Fn flag on a real keyboard;
  /// system shortcuts (⌃← for Spaces) only match with it.
  private static let fnKeys: Set<CGKeyCode> = [0x7B, 0x7C, 0x7D, 0x7E, 0x73, 0x74, 0x77, 0x79, 0x75]

  private static let keyCodes: [Key: CGKeyCode] = [
    .escape: 0x35, .tab: 0x30, .enter: 0x24, .backspace: 0x33, .forwardDelete: 0x75,
    .up: 0x7E, .down: 0x7D, .left: 0x7B, .right: 0x7C,
    .home: 0x73, .end: 0x77, .pageUp: 0x74, .pageDown: 0x79,
  ]

  /// ANSI positions, for characters typed while a modifier is held (⌘C).
  private static let charCodes: [Character: CGKeyCode] = [
    "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03, "g": 0x05, "h": 0x04,
    "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23,
    "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
    "y": 0x10, "z": 0x06,
    "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A,
    "8": 0x1C, "9": 0x19,
    "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E, "\\": 0x2A, ";": 0x29, "'": 0x27, "`": 0x32,
    ",": 0x2B, ".": 0x2F, "/": 0x2C, " ": 0x31,
  ]
}
