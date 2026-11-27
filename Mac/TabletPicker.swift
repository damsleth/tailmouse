import AppKit
import SwiftUI

/// What the phone's drawing surface maps to. Coordinates are CoreGraphics
/// global ones (origin at the top left of the main display), the space CGEvents
/// are posted in.
enum TabletTarget: Codable, Equatable {
  case display(CGDirectDisplayID)
  case window(CGWindowID)
  case rect(CGRect)

  static var main: TabletTarget { .display(CGMainDisplayID()) }

  /// Where it is now. A window moves and closes, a display unplugs: nil then.
  var region: CGRect? {
    let r: CGRect? = switch self {
    case .display(let id): CGDisplayIsActive(id) != 0 ? CGDisplayBounds(id) : nil
    case .window(let id): Self.bounds(ofWindow: id)
    case .rect(let r): r
    }
    guard let r, r.width >= Self.minSide, r.height >= Self.minSide else { return nil }
    return r
  }

  static let minSide: CGFloat = 40

  var title: String {
    switch self {
    case .display: "Entire screen"
    case .window: "A window"
    case .rect(let r): "Part of the screen, \(Int(r.width)) × \(Int(r.height))"
    }
  }

  private static func bounds(ofWindow id: CGWindowID) -> CGRect? {
    guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
          info[kCGWindowIsOnscreen as String] as? Bool == true,
          let b = info[kCGWindowBounds as String] else { return nil }
    return CGRect(dictionaryRepresentation: b as! CFDictionary)
  }
}

/// Chooses the drawing area the way the Screenshot bar chooses what to
/// capture: the entire screen, a window, or a part you drag out and adjust.
/// Return or Done keeps it, Esc cancels.
@MainActor
final class TabletPicker {
  enum Mode: Int { case screen, window, portion }

  private(set) var target: TabletTarget
  private(set) var mode: Mode
  /// What a click would choose, in screen and window mode.
  private var hover: TabletTarget?
  private var overlays: [NSWindow] = []
  private var bar: NSPanel?
  private let finish: (TabletTarget?) -> Void

  /// Which edges of the rectangle a drag moves; all four moves it whole.
  private struct Grab { var left = false, right = false, top = false, bottom = false; var from = CGPoint.zero; var start = CGRect.zero }
  private var grab: Grab?

  init(current: TabletTarget, finish: @escaping (TabletTarget?) -> Void) {
    target = current
    mode = switch current { case .display: .screen; case .window: .window; case .rect: .portion }
    self.finish = finish
  }

  func show() {
    for screen in NSScreen.screens {
      let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
      w.level = .statusBar
      w.isOpaque = false
      w.backgroundColor = .clear
      w.acceptsMouseMovedEvents = true
      // Said out loud: left alone, a click on the clear, lit part falls through
      // to the window underneath.
      w.ignoresMouseEvents = false
      w.isReleasedWhenClosed = false
      w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      let v = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
      v.picker = self
      w.contentView = v
      w.makeKeyAndOrderFront(nil)
      w.makeFirstResponder(v)   // for Esc and Return
      overlays.append(w)
    }
    let host = NSHostingView(rootView: PickerBar(picker: self, mode: mode))
    let size = host.fittingSize
    let main = NSScreen.main?.frame ?? .zero
    let p = NSPanel(contentRect: CGRect(x: main.midX - size.width / 2, y: main.minY + 90, width: size.width, height: size.height),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.level = .popUpMenu
    p.isOpaque = false
    p.backgroundColor = .clear
    p.isReleasedWhenClosed = false
    p.contentView = host
    p.orderFront(nil)
    bar = p
    NSApp.activate()   // an LSUIElement app gets no keys (Esc) until it is active
    if mode == .portion, case .rect = target {} else if mode == .portion { startPortion() }
  }

  func set(_ m: Mode) {
    mode = m
    hover = nil
    if m == .portion { startPortion() }
    redraw()
  }

  func end(keep: Bool) {
    overlays.forEach { $0.close() }
    bar?.close()
    overlays = []
    bar = nil
    finish(keep ? target : nil)
  }

  /// A starting rectangle to adjust: the middle of the main display.
  private func startPortion() {
    if case .rect = target { return }
    let d = CGDisplayBounds(CGMainDisplayID())
    target = .rect(d.insetBy(dx: d.width / 4, dy: d.height / 4))
  }

  private func redraw() { overlays.forEach { $0.contentView?.needsDisplay = true } }

  /// The lit area: the choice so far, or what a click would choose.
  fileprivate var lit: CGRect? { (hover ?? target).region }

  // MARK: Mouse, in CG global coordinates

  fileprivate func moved(to p: CGPoint) {
    switch mode {
    case .screen:
      var id: CGDirectDisplayID = 0, n: UInt32 = 0
      CGGetDisplaysWithPoint(p, 1, &id, &n)
      hover = n > 0 ? .display(id) : nil
    case .window:
      let mine = ProcessInfo.processInfo.processIdentifier
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
      // Front to back: the first ordinary window under the cursor.
      hover = list.lazy.filter {
        $0[kCGWindowLayer as String] as? Int == 0 && $0[kCGWindowOwnerPID as String] as? Int32 != mine
      }.compactMap { w -> TabletTarget? in
        guard let b = w[kCGWindowBounds as String], let r = CGRect(dictionaryRepresentation: b as! CFDictionary),
              r.contains(p), let id = w[kCGWindowNumber as String] as? CGWindowID else { return nil }
        return .window(id)
      }.first
    case .portion: return
    }
    redraw()
  }

  fileprivate func down(at p: CGPoint) {
    guard mode == .portion else {
      if let hover { target = hover; redraw() }
      return
    }
    guard case .rect(let r) = target else { return }
    let near: CGFloat = 10
    var g = Grab(from: p, start: r)
    if r.insetBy(dx: -near, dy: -near).contains(p) {
      g.left = abs(p.x - r.minX) < near
      g.right = abs(p.x - r.maxX) < near
      g.top = abs(p.y - r.minY) < near
      g.bottom = abs(p.y - r.maxY) < near
      if !(g.left || g.right || g.top || g.bottom) { (g.left, g.right, g.top, g.bottom) = (true, true, true, true) }
    } else {
      // Outside: drag out a new one from here.
      g.start = CGRect(origin: p, size: .zero)
      (g.right, g.bottom) = (true, true)
    }
    grab = g
  }

  fileprivate func dragged(to p: CGPoint) {
    guard let g = grab else { return }
    let dx = p.x - g.from.x, dy = p.y - g.from.y
    var (x0, x1, y0, y1) = (g.start.minX, g.start.maxX, g.start.minY, g.start.maxY)
    if g.left { x0 += dx }
    if g.right { x1 += dx }
    if g.top { y0 += dy }
    if g.bottom { y1 += dy }
    target = .rect(CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)))
    redraw()
  }

  fileprivate func up() {
    grab = nil
    // A click that dragged out nothing leaves no area: start over in the middle.
    if mode == .portion, target.region == nil { target = .main; startPortion(); redraw() }
  }
}

/// A borderless window refuses keys unless it says otherwise.
private final class KeyWindow: NSWindow {
  override var canBecomeKey: Bool { true }
}

private final class OverlayView: NSView {
  weak var picker: TabletPicker?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// This view's top-left corner in CG global coordinates. AppKit counts up
  /// from the bottom of the main display, CG down from its top.
  private var origin: CGPoint {
    guard let f = window?.frame, let primary = NSScreen.screens.first else { return .zero }
    return CGPoint(x: f.minX, y: primary.frame.height - f.maxY)
  }

  private func global(_ e: NSEvent) -> CGPoint {
    let p = convert(e.locationInWindow, from: nil), o = origin
    return CGPoint(x: p.x + o.x, y: p.y + o.y)
  }

  override func draw(_ dirty: CGRect) {
    NSColor.black.withAlphaComponent(0.45).setFill()
    bounds.fill()
    guard let lit = picker?.lit else { return }
    let o = origin
    let r = lit.offsetBy(dx: -o.x, dy: -o.y)
    NSColor.clear.setFill()
    r.fill(using: .copy)
    NSColor.white.setStroke()
    let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
    path.lineWidth = 1
    path.stroke()
    guard picker?.mode == .portion else { return }
    NSColor.white.setFill()
    for x in [r.minX, r.midX, r.maxX] {
      for y in [r.minY, r.midY, r.maxY] where !(x == r.midX && y == r.midY) {
        NSBezierPath(ovalIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)).fill()
      }
    }
  }

  override func updateTrackingAreas() {
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
  }

  override func mouseMoved(with e: NSEvent) { picker?.moved(to: global(e)) }
  override func mouseDown(with e: NSEvent) { picker?.down(at: global(e)) }
  override func mouseDragged(with e: NSEvent) { picker?.dragged(to: global(e)) }
  override func mouseUp(with e: NSEvent) { picker?.up() }

  /// Esc reaches a window as this, not always as a key.
  override func cancelOperation(_ sender: Any?) { picker?.end(keep: false) }

  override func keyDown(with e: NSEvent) {
    switch e.keyCode {
    case 53: picker?.end(keep: false)        // Esc
    case 36, 76: picker?.end(keep: true)     // Return, Enter
    default: super.keyDown(with: e)
    }
  }
}

private struct PickerBar: View {
  let picker: TabletPicker
  @State var mode: TabletPicker.Mode

  var body: some View {
    HStack(spacing: 14) {
      Picker("Drawing area", selection: $mode) {
        Label("Entire Screen", systemImage: "macwindow.on.rectangle").tag(TabletPicker.Mode.screen)
        Label("Window", systemImage: "macwindow").tag(TabletPicker.Mode.window)
        Label("Portion", systemImage: "rectangle.dashed").tag(TabletPicker.Mode.portion)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .labelStyle(.titleAndIcon)
      .fixedSize()
      .onChange(of: mode) { picker.set(mode) }
      Text(hint).font(.callout).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
      Button("Cancel") { picker.end(keep: false) }
      Button("Done") { picker.end(keep: true) }.buttonStyle(.borderedProminent)
    }
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .padding(8)
  }

  private var hint: String {
    switch mode {
    case .screen: "Click a screen"
    case .window: "Click a window"
    case .portion: "Drag to move or resize"
    }
  }
}
