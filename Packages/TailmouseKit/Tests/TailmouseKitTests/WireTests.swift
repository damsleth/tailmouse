import CryptoKit
import Network
import Foundation
import Testing
@testable import TailmouseKit

// MARK: - Seal

@Test func sealRoundTrip() throws {
  let seal = Seal(key: Seal.newKey())
  let p = Packet(client: 7, session: 9, time: 1.5, motion: Motion(kind: .pointer, gesture: 1, x: 3, y: -4),
                 events: [Sequenced(seq: 1, time: 0, event: .char("c", [.command])), Sequenced(seq: 2, time: 0, event: .text("hæ 👋"))])
  let datagram = try seal.seal(p)
  #expect(seal.open(Packet.self, from: datagram) == p)
}

@Test func wrongKeyOrTamperedPacketIsDropped() throws {
  let seal = Seal(key: Seal.newKey())
  var datagram = try seal.seal(Packet(client: 1, session: 0, time: 0))
  #expect(Seal(key: Seal.newKey()).open(Packet.self, from: datagram) == nil)
  datagram[datagram.count - 1] ^= 1
  #expect(seal.open(Packet.self, from: datagram) == nil)
  #expect(seal.open(Packet.self, from: Data("hello".utf8)) == nil)
}

// MARK: - Motion

@Test func motionAppliesDifferenceOnce() {
  var t = MotionTracker()
  func dx(_ g: UInt32, _ x: Double) -> Double? { t.resolve(Motion(kind: .pointer, gesture: g, x: x, y: 0))?.dx }
  #expect(dx(1, 5) == 5)
  #expect(dx(1, 5) == nil)      // duplicate
  #expect(dx(1, 12) == 7)       // a lost frame in between costs nothing
  #expect(dx(1, 9) == -3)       // late frame: totals still converge
  #expect(dx(2, 2) == 2)        // new gesture
  #expect(dx(1, 100) == nil)    // old gesture ignored
}

@Test func motionGestureCounterWraps() {
  var t = MotionTracker()
  func dx(_ g: UInt32, _ x: Double) -> Double? { t.resolve(Motion(kind: .pointer, gesture: g, x: x, y: 0))?.dx }
  #expect(dx(.max, 1) == 1)
  #expect(dx(0, 4) == 4)
}

// MARK: - Pairing

@Test func pairingURLRoundTrip() {
  let p = Pairing(key: Seal.newKey().data, ble: UUID(), name: "Example Mac", hosts: ["100.64.0.1", "example-mac.tail0000.ts.net"])
  #expect(Pairing(url: p.url) == p)
  #expect(Pairing(url: URL(string: "tailmouse://pair?k=short&n=x")!) == nil)
  // Without the Bluetooth service: a link from an older Mac build.
  #expect(Pairing(url: URL(string: p.url.absoluteString.replacingOccurrences(of: "b=", with: "x="))!) == nil)
}

// MARK: - Sessions over a bad link

/// Phone and Mac talking through a link that drops, duplicates and reorders.
@Test(arguments: [1, 2, 3, 42, 1337])
func eventsArriveOnceInOrderOverLossyLink(seed: UInt64) {
  var rng = SplitMix(seed: seed)
  var mac = Sessions(name: "mac")
  var outbox = Outbox()
  var session: UInt64 = 0
  var delivered: [Event] = []
  var inFlight: [Packet] = []
  let sent: [Event] = (0..<200).map { .text(String($0)) }
  var toSend = sent[...]
  var now = 0.0

  for _ in 0..<5000 {
    now += 0.001
    if let e = toSend.first, rng.next() % 3 == 0 { outbox.push(e, time: now); toSend = toSend.dropFirst() }
    let p = Packet(client: 1, session: session, time: now, events: session == 0 ? [] : outbox.pending)
    // The link: drop 30%, duplicate 10%, deliver in shuffled batches.
    if rng.next() % 10 >= 3 { inFlight.append(p) }
    if rng.next() % 10 == 0 { inFlight.append(p) }
    if rng.next() % 4 == 0 {
      inFlight.shuffle(using: &rng)
      for q in inFlight {
        let (reply, actions) = mac.receive(q, now: now, newID: { 99 })
        delivered += actions.compactMap { if case .event(let e) = $0 { e } else { nil } }
        if rng.next() % 10 < 3 { continue }          // replies get lost too
        if reply.session != session { session = reply.session; outbox.restart() }
        outbox.ack(reply.ack)
      }
      inFlight.removeAll()
    }
    if toSend.isEmpty && outbox.pending.isEmpty { break }
  }
  #expect(delivered == sent)
}

@Test func replayedPacketsFromOldSessionNeverRun() {
  var mac = Sessions(name: "mac")
  let (hello, _) = mac.receive(Packet(client: 1, session: 0, time: 0), now: 0, newID: { 11 })
  let typed = Packet(client: 1, session: hello.session, time: 1,
                     events: [Sequenced(seq: 1, time: 0, event: .text("secret"))])
  let first = mac.receive(typed, now: 1).1
  let dup = mac.receive(typed, now: 1.1).1                       // duplicate within session
  #expect(first == [.event(.text("secret"))])
  #expect(dup == [])

  // Session times out; an attacker replays the hello and the recorded packet.
  let expired = mac.expire(now: 10)
  _ = mac.receive(Packet(client: 1, session: 0, time: 0), now: 10, newID: { 22 })
  let replayed = mac.receive(typed, now: 10.1).1
  #expect(expired)
  #expect(replayed == [])
}

@Test func motionIsAppliedBeforeEventsInSamePacket() {
  var mac = Sessions(name: "mac")
  let id = mac.receive(Packet(client: 1, session: 0, time: 0), now: 0).0.session
  let p = Packet(client: 1, session: id, time: 1, motion: Motion(kind: .pointer, gesture: 1, x: 10, y: 0),
                 events: [Sequenced(seq: 1, time: 0, event: .click(.left))])
  let actions = mac.receive(p, now: 1).1
  #expect(actions == [.move(dx: 10, dy: 0), .event(.click(.left))])
}

/// Deterministic RNG so a failing seed reproduces.
struct SplitMix: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

@Test func lateMotionFromSlowPathIsIgnored() {
  var mac = Sessions(name: "mac")
  let id = mac.receive(Packet(client: 1, session: 0, time: 0), now: 0).0.session
  func move(_ x: Double, sentAt t: Double) -> [Sessions.Action] {
    mac.receive(Packet(client: 1, session: id, time: t, motion: Motion(kind: .pointer, gesture: 1, x: x, y: 0)), now: t).1
  }
  let fast = move(30, sentAt: 2)        // fast path, sent later, arrives first
  let slow = move(10, sentAt: 1)        // slow path, older total, arrives late
  #expect(fast == [.move(dx: 30, dy: 0)])
  #expect(slow == [])
}

@Test func lateEventsAreConsumedButReleasesStillRun() {
  var mac = Sessions(name: "mac")
  let id = mac.receive(Packet(client: 1, session: 0, time: 0), now: 0).0.session
  let p = Packet(client: 1, session: id, time: 5, events: [
    Sequenced(seq: 1, time: 1, event: .click(.left)),   // waited 4 s for a path
    Sequenced(seq: 2, time: 1, event: .dragEnd),
    Sequenced(seq: 3, time: 4.5, event: .text("a")),
  ])
  let (reply, actions) = mac.receive(p, now: 5)
  #expect(actions == [.event(.dragEnd), .event(.text("a"))])
  #expect(reply.ack == 3)
}

@Test func silentSessionExpires() {
  var mac = Sessions(name: "mac")
  _ = mac.receive(Packet(client: 1, session: 0, time: 0), now: 0)
  let early = mac.expire(now: Wire.sessionTimeout - 0.1)
  let late = mac.expire(now: Wire.sessionTimeout + 0.1)
  #expect(!early)
  #expect(late)
  #expect(mac.activeClients == 0)
}

@Test func fullOutboxRefusesNewEventsWithoutGaps() {
  var o = Outbox()
  for i in 0..<(Outbox.window + 5) { o.push(.text(String(i)), time: 0) }
  #expect(o.pending.count == Outbox.window)
  #expect(o.pending.map(\.seq) == Array(1...UInt32(Outbox.window)))
}

// MARK: - Compatibility, PIN, routes

@Test func everyFieldSurvivesTheWire() {
  let events: [Event] = [.click(.left), .click(.right), .dragBegin, .dragEnd, .scrollBegin, .scrollEnd,
                         .text("blåbær 🫐"), .key(.pageDown, [.command, .shift]), .char("é", .option)]
  let p = Packet(client: .max, session: 7, time: 12.5,
                 motion: Motion(kind: .scroll, gesture: 9, x: -1.25, y: 3e6),
                 events: events.enumerated().map { Sequenced(seq: UInt32($0.offset), time: 1.5, event: $0.element) },
                 name: "Example iPhone", via: "BLE")
  #expect(Packet(wire: p.wire) == p)
  let r = Reply(session: 7, ack: 3, echo: 12.5, name: "Example Mac")
  #expect(Reply(wire: r.wire) == r)
}

@Test func pointerPacketIsSmallAndTrailingBytesAreIgnored() {
  let p = Packet(client: 1, session: 2, time: 3, motion: Motion(kind: .pointer, gesture: 4, x: 5, y: 6))
  #expect(p.wire.count == 46)
  // A newer build appends fields; this one reads what it knows.
  #expect(Packet(wire: p.wire + Data([1, 2, 3])) == p)
}

@Test func drawingPositionAppliesOnceAndOnlyInsideTheArea() {
  var mac = Sessions(name: "mac")
  mac.aspect = 1.6
  let (hello, _) = mac.receive(Packet(client: 1, session: 0, time: 0), now: 0)
  #expect(hello.aspect == 1.6)
  func send(_ t: Double, _ m: Motion) -> [Sessions.Action] {
    mac.receive(Packet(client: 1, session: hello.session, time: t, motion: m), now: t).1
  }
  let at = Motion(kind: .tablet, gesture: 1, x: 0.25, y: 0.75)
  #expect(send(1, at) == [.place(x: 0.25, y: 0.75)])
  #expect(send(2, at) == [])                                     // the probe repeats it: no pull-back
  // A new stroke at the same spot still applies, and lifts first: the old
  // stroke's dragEnd may not have arrived, and the jump must not draw.
  #expect(send(3, Motion(kind: .tablet, gesture: 2, x: 0.25, y: 0.75)) == [.event(.dragEnd), .place(x: 0.25, y: 0.75)])
  #expect(send(4, Motion(kind: .tablet, gesture: 3, x: 1.5, y: 0.5)) == [])
  #expect(Packet(wire: Packet(client: 1, session: 2, time: 3, motion: at).wire)?.motion == at)
  // A reply from a Mac without a drawing area ends after the name.
  let plain = Reply(session: 1, ack: 2, echo: 3, name: "Example Mac")
  #expect(Reply(wire: plain.wire) == plain)
  #expect(Reply(wire: Reply(session: 1, ack: 2, echo: 3, name: "Example Mac", aspect: 1.6).wire)?.aspect == 1.6)
}

@Test func malformedWireIsRefused() {
  let p = Packet(client: 1, session: 2, time: 3, motion: Motion(kind: .pointer, gesture: 4, x: 5, y: 6),
                 events: [Sequenced(seq: 1, time: 0, event: .text("hi"))], name: "n")
  let wire = p.wire
  for cut in 0..<wire.count { #expect(Packet(wire: wire.prefix(cut)) == nil) }
  var nan = wire
  nan.replaceSubrange(17..<25, with: [0x7F, 0xF8, 0, 0, 0, 0, 0, 0])     // time = NaN
  #expect(Packet(wire: nan) == nil)
  var tag = Packet(client: 1, session: 2, time: 3, events: [Sequenced(seq: 1, time: 0, event: .dragBegin)]).wire
  tag[tag.count - 1] = 200                                               // an event this build doesn't know
  #expect(Packet(wire: tag) == nil)
}

@Test func eachPhoneHasItsOwnKeyAndRemovingItRevokesIt() throws {
  let a = Seal(key: Seal.newKey()), b = Seal(key: Seal.newKey())
  var mac = Keyring(name: "mac", keys: ["a": a.key.data, "b": b.key.data])
  // #expect can't call a mutating method.
  func rx(_ d: Data, now: Double) -> Keyring.Received? { mac.receive(d, now: now) }
  let hello = Packet(client: 1, session: 0, time: 0)
  let fromA = try #require(rx(try a.seal(hello), now: 0))
  let fromB = try #require(rx(try b.seal(hello), now: 0))
  #expect(fromA.id == "a" && fromB.id == "b")
  // Each answer opens only with the asker's key.
  #expect(a.open(Reply.self, from: try #require(fromA.datagram)) == fromA.reply)
  #expect(b.open(Reply.self, from: try #require(fromA.datagram)) == nil)
  // The same client id under another key is another session: b can't learn a's.
  #expect(fromA.reply.session != fromB.reply.session)
  mac.remove("a")
  #expect(rx(try a.seal(hello), now: 1) == nil)
  #expect(rx(try b.seal(hello), now: 1)?.id == "b")
  #expect(rx(try Seal(key: Seal.newKey()).seal(hello), now: 1) == nil)   // a stranger
}

@Test func pairingCodeMakesOnePhoneWithAKeyTheCodeDoesNotGive() throws {
  var mac = Keyring(name: "mac")
  func rx(_ d: Data, now: Double) -> Keyring.Received? { mac.receive(d, now: now) }
  let offer = Seal.PairingKey()
  let code = Pairing(key: offer.publicKey.rawRepresentation, ble: UUID(), name: "Example Mac", hosts: [])
  func hello(_ p: Pairing, claim: Bool = true) throws -> Data {
    let d = try #require(Seal(keyData: p.key)).seal(Packet(client: 1, session: 0, time: 0))
    return claim ? Seal.claim(try #require(p.claim), d) : d
  }
  let phone = try #require(code.claimed())
  #expect(rx(try hello(phone), now: 0) == nil)                       // no code on screen
  mac.offer((id: "first", key: offer))
  // The code itself is not a key: what is on screen opens nothing.
  #expect(rx(try hello(code, claim: false), now: 0) == nil)
  let first = try #require(rx(try hello(phone), now: 0))
  #expect(first.id == "first" && first.paired == phone.key + (phone.claim ?? Data()))
  // A second scan of the same code gets another key, and the Mac has no use for it.
  let copy = try #require(code.claimed())
  #expect(copy.key != phone.key)
  #expect(rx(try hello(copy), now: 1) == nil)
  // Even with a new code on screen: that one has another private key.
  mac.offer((id: "second", key: Seal.PairingKey()))
  #expect(rx(try hello(copy), now: 1) == nil)
  // The phone may claim again (its answer was lost), and then stops claiming.
  let again = try #require(rx(try hello(phone), now: 1))
  #expect(again.id == "first" && again.paired == nil && mac.ids == ["first"])
  #expect(rx(try hello(phone, claim: false), now: 1)?.id == "first")
  // The window closes with its code unused.
  mac.offer(nil)
  let ended = mac.expire(now: 100)
  #expect(ended)
}

@Test func samePhonePairingAgainKeepsItsRowAndLosesItsOldKey() throws {
  var mac = Keyring(name: "mac")
  func rx(_ d: Data, now: Double) -> Keyring.Received? { mac.receive(d, now: now) }
  func hello(_ p: Pairing, claim: Bool = true) throws -> Data {
    let d = try #require(Seal(keyData: p.key)).seal(Packet(client: 1, session: 0, time: 0))
    return claim ? Seal.claim(try #require(p.claim), d) : d
  }
  func code(_ id: String) -> Pairing {
    let offer = Seal.PairingKey()
    mac.offer((id: id, key: offer))
    return Pairing(key: offer.publicKey.rawRepresentation, ble: UUID(), name: "Example Mac", hosts: [])
  }
  let phone = Seal.PairingKey(), other = Seal.PairingKey()
  let first = try #require(code("a").claimed(with: phone))
  let stored = try #require(rx(try hello(first), now: 0)?.paired)
  // The Mac restarts with what it stored, and the phone scans a new code.
  mac = Keyring(name: "mac", keys: ["a": stored])
  let second = try #require(code("b").claimed(with: phone))
  let again = try #require(rx(try hello(second), now: 1))
  #expect(again.id == "a" && again.paired != nil && mac.ids == ["a"])
  #expect(second.key != first.key)
  #expect(rx(try hello(first, claim: false), now: 2) == nil)      // the old key is dead
  #expect(rx(try hello(second, claim: false), now: 2)?.id == "a")
  // Another phone is another row.
  #expect(rx(try hello(try #require(code("c").claimed(with: other))), now: 3)?.id == "c")
  #expect(mac.ids == ["a", "c"])
}

@Test func routesClassifyByAddress() {
  func route(_ host: String) -> Route { Route.of(.hostPort(host: NWEndpoint.Host(host), port: 1)) }
  #expect(route("100.64.0.1") == .tailnet)
  #expect(route("100.200.1.2") == .lan)       // outside 100.64/10
  #expect(route("fd7a:115c:a1e0::1") == .tailnet)
  #expect(route("192.168.1.20") == .lan)
  #expect(route("127.0.0.1") == .lan)
  // Link-local: the interface decides, and only the Mac knows which one is the
  // cable. The scope survives parsing only for an interface that exists here,
  // so the test uses lo0.
  func linkLocal(usb: String) -> Route {
    Route.of(.hostPort(host: NWEndpoint.Host("fe80::1%lo0"), port: 1)) { $0 == usb }
  }
  #expect(linkLocal(usb: "lo0") == .usb)
  #expect(linkLocal(usb: "en99") == .lan)
}

// MARK: - Security review

@Test func heldBackPacketRunsNothingAndKeepsNoSessionAlive() {
  var mac = Sessions(name: "mac")
  let id = mac.receive(Packet(client: 1, session: 0, time: 100), now: 0).0.session
  let held = Packet(client: 1, session: id, time: 100.5, events: [Sequenced(seq: 1, time: 100.5, event: .key(.enter, []))])
  // Same phone timestamps, released 5 s later by the Mac's clock.
  let late = mac.receive(held, now: 5.5)
  #expect(late.1.isEmpty)
  let expired = mac.expire(now: 5.6)   // the late packet did not refresh it
  #expect(expired)
  #expect(mac.activeClients == 0)
}

@Test func freshPacketsStillRunAfterAPathSwitch() {
  var mac = Sessions(name: "mac")
  let id = mac.receive(Packet(client: 1, session: 0, time: 100), now: 0.003).0.session
  // A slower path (300 ms) is late by the Mac's clock but within eventMaxAge.
  let p = Packet(client: 1, session: id, time: 101, events: [Sequenced(seq: 1, time: 101, event: .click(.left))])
  let actions = mac.receive(p, now: 1.3).1
  #expect(actions == [.event(.click(.left))])
}

@Test func absurdMotionIsDropped() {
  var mac = Sessions(name: "mac")
  let id = mac.receive(Packet(client: 1, session: 0, time: 0), now: 0).0.session
  for x in [1e20, .infinity, .nan] {
    let p = Packet(client: 1, session: id, time: 0, motion: Motion(kind: .scroll, gesture: 1, x: x, y: 0))
    let actions = mac.receive(p, now: 0).1
    #expect(actions.isEmpty)
  }
}

@Test func pairingLinkKeepsOnlyTailnetHosts() {
  let p = Pairing(key: Seal.newKey().data, ble: UUID(), name: "Example Mac", hosts: ["100.64.0.1", "evil.example", "8.8.8.8", "fd7a:115c:a1e0::1", "x.tail0000.ts.net"])
  #expect(Pairing(url: p.url)?.hosts == ["100.64.0.1", "fd7a:115c:a1e0::1", "x.tail0000.ts.net"])
}

// MARK: - Bluetooth framing

@Test func framesSurviveSplittingAndCoalescing() {
  let a = Data(repeating: 1, count: 300), b = Data([2]), c = Data(repeating: 3, count: Framer.maxFrame)
  let stream = Framer.frame(a)! + Framer.frame(b)! + Framer.frame(c)!
  var whole = Framer()
  #expect(whole.feed(stream) == [a, b, c])
  var bytewise = Framer(), out: [Data] = []
  for byte in stream { out += bytewise.feed(Data([byte]))! }
  #expect(out == [a, b, c])
}

@Test func framerRejectsEmptyAndOversize() {
  #expect(Framer.frame(Data()) == nil)
  #expect(Framer.frame(Data(repeating: 0, count: Framer.maxFrame + 1)) == nil)
  var zero = Framer()
  #expect(zero.feed(Data([0, 0])) == nil)
  var huge = Framer()
  #expect(huge.feed(Data([0xFF, 0xFF, 1])) == nil)     // refused on the length, before the body arrives
}

@Test func sendWindowWaitsForAnswersAndReopens() {
  var w = SendWindow(size: 2)
  #expect(w.wait(now: 0) <= 0); w.sent(now: 0)
  #expect(w.wait(now: 0.01) <= 0); w.sent(now: 0.01)
  #expect(w.wait(now: 0.02) > 0)                       // two unanswered: hold
  w.answered()
  #expect(w.wait(now: 0.03) <= 0); w.sent(now: 0.03)
  #expect(w.wait(now: 0.04) > 0)
  #expect(w.wait(now: 0.03 + SendWindow.timeout) <= 0) // no answer: start over
  w.answered(); w.answered(); w.answered()             // extra answers don't widen it
  w.sent(now: 1); w.sent(now: 1)
  #expect(w.wait(now: 1.01) > 0)
}
