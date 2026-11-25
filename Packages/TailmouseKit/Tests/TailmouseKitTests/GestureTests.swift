import Testing
@testable import TailmouseKit

private func events(_ out: [TouchInterpreter.Output]) -> [Event] {
  out.compactMap { if case .event(let e) = $0 { e } else { nil } }
}

private func lastMotion(_ out: [TouchInterpreter.Output]) -> Motion? {
  out.compactMap { if case .motion(let m) = $0 { m } else { nil } }.last
}

@Test func quickTapIsLeftClick() {
  var t = TouchInterpreter()
  _ = t.update(fingers: 1, x: 100, y: 100, time: 0)
  _ = t.update(fingers: 1, x: 102, y: 101, time: 0.05)
  #expect(events(t.update(fingers: 0, x: 102, y: 101, time: 0.1)) == [.click(.left)])
}

@Test func slowOrLongTouchIsNotAClick() {
  var t = TouchInterpreter()
  _ = t.update(fingers: 1, x: 0, y: 0, time: 0)
  _ = t.update(fingers: 1, x: 50, y: 0, time: 0.1)
  #expect(events(t.update(fingers: 0, x: 50, y: 0, time: 0.15)) == [])
}

@Test func moveSendsScaledRunningTotal() {
  var t = TouchInterpreter()
  t.sensitivity = 2
  _ = t.update(fingers: 1, x: 0, y: 0, time: 0)
  _ = t.update(fingers: 1, x: 3, y: 1, time: 0.01)
  let m = lastMotion(t.update(fingers: 1, x: 5, y: 1, time: 0.02))
  #expect(m == Motion(kind: .pointer, gesture: 1, x: 10, y: 2))
  _ = t.update(fingers: 0, x: 5, y: 1, time: 0.5)
  _ = t.update(fingers: 1, x: 0, y: 0, time: 1)
  #expect(lastMotion(t.update(fingers: 1, x: 1, y: 0, time: 1.01))?.gesture == 2)
}

@Test func holdStillThenMoveIsADrag() {
  var t = TouchInterpreter()
  _ = t.update(fingers: 1, x: 0, y: 0, time: 0)
  #expect(events(t.tick(time: 0.2)) == [])
  #expect(events(t.tick(time: 0.5)) == [.dragBegin])
  #expect(events(t.tick(time: 0.6)) == [])
  #expect(lastMotion(t.update(fingers: 1, x: 40, y: 0, time: 0.7))?.kind == .pointer)
  #expect(events(t.update(fingers: 0, x: 40, y: 0, time: 0.8)) == [.dragEnd])
}

@Test func movingBeforeHoldDelayIsNoDrag() {
  var t = TouchInterpreter()
  _ = t.update(fingers: 1, x: 0, y: 0, time: 0)
  _ = t.update(fingers: 1, x: 30, y: 0, time: 0.2)
  #expect(events(t.tick(time: 0.6)) == [])
}

@Test func twoFingerTapIsRightClickEvenWhenFingersLandApart() {
  var t = TouchInterpreter()
  _ = t.update(fingers: 1, x: 100, y: 100, time: 0)
  _ = t.update(fingers: 2, x: 120, y: 100, time: 0.02)
  #expect(events(t.update(fingers: 1, x: 140, y: 100, time: 0.12)) == [.click(.right)])
  #expect(events(t.update(fingers: 0, x: 140, y: 100, time: 0.14)) == [])
}

@Test func twoFingerDragScrollsWithNaturalDirection() {
  var t = TouchInterpreter()
  _ = t.update(fingers: 2, x: 0, y: 0, time: 0)
  #expect(events(t.update(fingers: 2, x: 0, y: 2, time: 0.01)) == [])          // inside slop
  let out = t.update(fingers: 2, x: 0, y: 10, time: 0.02)
  #expect(events(out) == [.scrollBegin])
  #expect(lastMotion(out) == Motion(kind: .scroll, gesture: 1, x: 0, y: 8))
  #expect(events(t.update(fingers: 1, x: 0, y: 10, time: 0.5)) == [.scrollEnd])
  #expect(events(t.update(fingers: 0, x: 0, y: 10, time: 0.55)) == [])

  t.naturalScroll = false
  _ = t.update(fingers: 2, x: 0, y: 0, time: 1)
  _ = t.update(fingers: 2, x: 0, y: 10, time: 1.01)
  #expect(lastMotion(t.update(fingers: 2, x: 0, y: 20, time: 1.02))?.y == -20)
}

// MARK: - Path picking

@Test func picksFastestLivePathWithHysteresis() {
  var p = PathPicker()
  p.replied(path: "tailnet", rtt: 0.200, now: 0)
  #expect(p.active == "tailnet")
  p.replied(path: "awdl", rtt: 0.006, now: 0.1)
  #expect(p.active == "awdl")
  p.replied(path: "lan", rtt: 0.005, now: 0.2)            // not clearly faster
  #expect(p.active == "awdl")
  #expect(p.choose(now: 2.7) == "lan")                     // awdl went quiet, lan still alive
  #expect(p.choose(now: 10) == nil)
}
