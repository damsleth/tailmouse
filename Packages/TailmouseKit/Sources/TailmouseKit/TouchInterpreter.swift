/// Phone side: turns raw finger counts and positions into wire output.
///
/// Feed it every touch sample (`update`) and a frame tick while a finger is
/// down (`tick`, for the hold-to-drag timer). Pure, so the gesture rules are
/// tested without a phone.
///
/// - 1 finger: move. Quick tap: left click. Hold still 0.45 s: drag.
/// - 2 fingers: move = scroll. Quick tap: right click.
/// - 3+ fingers: ignored in v1 (reserved for spaces / Mission Control).
public struct TouchInterpreter: Sendable {
  public enum Output: Equatable, Sendable {
    case motion(Motion)
    case event(Event)
    case haptic
  }

  public var sensitivity = 1.5
  public var scrollSpeed = 1.0
  /// Content follows the fingers, like a Mac trackpad's natural scrolling.
  public var naturalScroll = true

  public static let tapMaxDuration = 0.25
  public static let twoFingerTapMaxDuration = 0.3
  public static let tapSlop = 8.0
  public static let holdDelay = 0.45
  public static let scrollSlop = 4.0

  enum Phase { case idle, one, dragging, two, scrolling, lifting }

  private(set) var phase = Phase.idle
  private var fingers = 0
  private var maxFingers = 0
  private var last = (x: 0.0, y: 0.0)
  private var startTime = 0.0
  private var travel = 0.0
  private var pointerGesture: UInt32 = 0
  private var scrollGesture: UInt32 = 0
  private var pointer = (x: 0.0, y: 0.0)
  private var scroll = (x: 0.0, y: 0.0)

  public init() {}

  /// `fingers` is the number of touches still down; `x`/`y` their centroid.
  public mutating func update(fingers n: Int, x: Double, y: Double, time: Double) -> [Output] {
    if n == fingers { return move(x: x, y: y) }
    let old = fingers
    fingers = n
    // The centroid jumps when a finger lands or lifts; start measuring again.
    last = (x, y)
    maxFingers = max(maxFingers, n)
    if old == 0 { return begin(n, time: time) }
    if n > old { return added(n) }
    return lifted(n, time: time)
  }

  public mutating func tick(time: Double) -> [Output] {
    guard phase == .one, time - startTime >= Self.holdDelay, travel <= Self.tapSlop else { return [] }
    phase = .dragging
    return [.haptic, .event(.dragBegin)]
  }

  private mutating func begin(_ n: Int, time: Double) -> [Output] {
    startTime = time
    travel = 0
    maxFingers = n
    switch n {
    case 1:
      phase = .one
      pointerGesture &+= 1
      pointer = (0, 0)
    case 2: phase = .two
    default: phase = .lifting
    }
    return []
  }

  private mutating func added(_ n: Int) -> [Output] {
    switch phase {
    case .one where n == 2:
      // The second finger of a two-finger touch rarely lands in the same frame.
      phase = .two
      travel = 0
      return []
    case .scrolling:
      phase = .lifting
      return [.event(.scrollEnd)]
    case .dragging:
      return []
    default:
      phase = .lifting
      return []
    }
  }

  private mutating func lifted(_ n: Int, time: Double) -> [Output] {
    var out: [Output] = []
    switch phase {
    case .one where n == 0:
      if time - startTime <= Self.tapMaxDuration && travel <= Self.tapSlop {
        out = [.haptic, .event(.click(.left))]
      }
    case .dragging where n == 0:
      out = [.event(.dragEnd)]
    case .dragging:
      return []
    case .two:
      // Fingers lift one at a time; decide on the first one up.
      if maxFingers == 2 && time - startTime <= Self.twoFingerTapMaxDuration && travel <= Self.tapSlop {
        out = [.haptic, .event(.click(.right))]
      }
    case .scrolling:
      out = [.event(.scrollEnd)]
    default:
      break
    }
    phase = n == 0 ? .idle : .lifting
    if n == 0 { maxFingers = 0 }
    return out
  }

  private mutating func move(x: Double, y: Double) -> [Output] {
    let dx = x - last.x, dy = y - last.y
    last = (x, y)
    guard dx != 0 || dy != 0 else { return [] }
    travel += (dx * dx + dy * dy).squareRoot()
    switch phase {
    case .one, .dragging:
      pointer.x += dx * sensitivity
      pointer.y += dy * sensitivity
      return [.motion(Motion(kind: .pointer, gesture: pointerGesture, x: pointer.x, y: pointer.y))]
    case .two:
      guard travel > Self.scrollSlop else { return [] }
      phase = .scrolling
      scrollGesture &+= 1
      scroll = (0, 0)
      return [.event(.scrollBegin)] + addScroll(dx, dy)
    case .scrolling:
      return addScroll(dx, dy)
    case .idle, .lifting:
      return []
    }
  }

  private mutating func addScroll(_ dx: Double, _ dy: Double) -> [Output] {
    let sign = naturalScroll ? 1.0 : -1.0
    scroll.x += dx * sign * scrollSpeed
    scroll.y += dy * sign * scrollSpeed
    return [.motion(Motion(kind: .scroll, gesture: scrollGesture, x: scroll.x, y: scroll.y))]
  }
}
