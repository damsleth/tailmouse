import SwiftUI
import UIKit

/// The touch surface. Raw UIKit touches, not SwiftUI gestures: we need every
/// coalesced sample and the finger count, and the rules live in
/// `TouchInterpreter`.
struct TrackpadSurface: UIViewRepresentable {
  let client: Client

  func makeUIView(context: Context) -> TouchPadView {
    let v = TouchPadView()
    v.client = client
    return v
  }

  func updateUIView(_ v: TouchPadView, context: Context) { v.client = client }
}

final class TouchPadView: UIView {
  weak var client: Client?
  private var down: Set<UITouch> = []
  private var link: CADisplayLink?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isMultipleTouchEnabled = true
    backgroundColor = .clear
  }

  required init?(coder: NSCoder) { fatalError() }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    down.formUnion(touches)
    report(event)
    startLink()
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let client else { return }
    if down.count == 1, let t = down.first {
      // Every sample the digitizer produced since the last frame, not just the latest.
      for s in event?.coalescedTouches(for: t) ?? [t] {
        let p = s.location(in: self)
        client.touches(fingers: 1, x: p.x, y: p.y, time: s.timestamp)
      }
    } else {
      report(event)
    }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    down.subtract(touches)
    report(event, lifted: touches)
    if down.isEmpty { stopLink() }
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    touchesEnded(touches, with: event)
  }

  /// Sends the current finger count and centroid. When fingers just lifted,
  /// the centroid is taken over them too, so the last position is not a jump.
  private func report(_ event: UIEvent?, lifted: Set<UITouch> = []) {
    let points = (down.isEmpty ? lifted : down).map { $0.location(in: self) }
    guard !points.isEmpty else { return }
    let x = points.map(\.x).reduce(0, +) / CGFloat(points.count)
    let y = points.map(\.y).reduce(0, +) / CGFloat(points.count)
    let time = (down.first ?? lifted.first)?.timestamp ?? ProcessInfo.processInfo.systemUptime
    client?.touches(fingers: down.count, x: x, y: y, time: time)
  }

  /// Holds the display at 120 Hz while a finger is down: iOS delivers touches
  /// in step with the screen, and a still screen idles at 60 Hz. The tick also
  /// drives the hold-to-drag timer.
  private func startLink() {
    guard link == nil else { return }
    let l = CADisplayLink(target: self, selector: #selector(frame(_:)))
    l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    l.add(to: .main, forMode: .common)
    link = l
  }

  private func stopLink() {
    link?.invalidate()
    link = nil
  }

  @objc private func frame(_ l: CADisplayLink) {
    client?.tick(time: ProcessInfo.processInfo.systemUptime)
  }
}
