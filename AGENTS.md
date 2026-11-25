# AGENTS.md

Tailmouse turns an iPhone into a trackpad and keyboard for a Mac. Both ends are native Swift. They talk over one UDP socket that works over the LAN (Bonjour), over AWDL (Apple peer-to-peer Wi-Fi, the AirDrop link) and over a tailnet (Tailscale). The phone probes all three and uses the fastest live one. AWDL and the tailnet get around Wi-Fi client isolation; AWDL avoids the DERP relay detour.

## Layout and commands

- `Packages/TailmouseKit`: the protocol, with no sockets and no UI. Wire types, sealing, reliable ordering, motion totals, pairing URL, the Mac's session logic, and scroll momentum (`Momentum`: the Mac measures the release speed from arrival times and glides on a 120 Hz timer, so the phone sends nothing extra). Any logic that can be pure lives here, so `make test` covers it.
- `Mac/`: menu bar server. Network.framework listener plus CGEvent input. The main window is the SwiftUI `Settings` scene (Devices, Settings, About tabs); settings live in `UserDefaults`, the pairing key and PIN in the Keychain.
- `iOS/`: the phone app.
- `project.yml`: the XcodeGen spec. `Tailmouse.xcodeproj` and `iOS/Info.plist` are generated and gitignored. Change targets, Info.plist keys and settings in `project.yml`, then run `make gen`.
- `Makefile`: `test`, `mac`, `run-mac`, `install-mac`, `ios-sim`, `sim`, `ipa`. Read it for the exact `xcodebuild` lines.
- End-to-end check without a phone: `make run-mac`, then `make sim SHOT=build/shot.png`. The `sim` target writes the pairing from the Mac's Keychain straight into the simulator app's container, so no QR scan is needed. The header in the screenshot should read `LAN · n ms`, and Settings › Paths should list both LAN and Tailnet. This covers the handshake only: posting input needs Accessibility, and loopback skips the firewall, so input and the AWDL path still need a real phone.
- Driving the Mac window from a script: System Events `click` on toolbar buttons and checkboxes works. For a text field, `set value` and then `perform action "AXConfirm"`; the SwiftUI binding ignores `set value` alone. Never use `keystroke`: an `LSUIElement` app doesn't come to the front, so the keys land in whatever app does. Capture with `screencapture -l <window id>`.

## Protocol invariants

Each of these has a test in `TailmouseKitTests`. Keep the tests green when you change the protocol.

- Every datagram is sealed with ChaChaPoly under the pairing key, whatever the path. The LAN path carries keystrokes. A packet that fails to open gets no reply.
- Pointer and scroll travel as the gesture's running total (`Motion`). The Mac applies `total - lastApplied`, so loss and duplicates cost nothing.
- Clicks, keys and drag/scroll boundaries are `Event`s. Each packet carries the whole unacked window, and the Mac delivers events once, in order.
- A packet runs only under a session id that the Mac issued. First contact and stale sessions get a reply and nothing more, so replayed traffic never runs.
- Motion in a packet is applied before its events, so a click lands where the cursor is. Motion from a packet older than the newest one seen is dropped, so a slow path (DERP) can never drag the cursor back.
- An event more than `Wire.eventMaxAge` old when it reaches the Mac is consumed without running, so a click or keystroke never fires late. Releases (`dragEnd`, `scrollEnd`) always run.
- Freshness is also judged by the Mac's clock: each session tracks the smallest `now - Packet.time`, and a packet more than `eventMaxAge` behind that runs nothing and doesn't keep the session alive. Phone timestamps alone can't catch a packet an on-path attacker held back and released later.
- Motion totals must be finite and below 1e7, or the Mac's integer conversions could trap.
- When a session expires, the Mac releases held input such as an active drag.
- With a PIN set, a session starts only for a packet carrying it. Five distinct wrong PINs lock the PIN check and the Mac makes a new key. Distinct, because a phone repeats one stale PIN on every path and probe. A right PIN does not reset the count; a new key or PIN does. "Require PIN" with fewer than four digits entered lets no one in (`pin == ""`).
- The phone ignores a reply whose `echo` is older than the newest it has acted on (per path for RTT, overall for session and acks), so a replayed reply can't roll its session back.
- A `tailmouse://` link only fills `Client.pendingPairing`; nothing changes until the user confirms. Link hosts are limited to tailnet addresses and `*.ts.net` (`Route.isTailnet(host:)`), at most 8.
- Fields added to `Packet` and `Reply` are optional, so a phone on an older build still connects.
- New `Event` cases go at the end. v2 reserves dock, spaces, media and clipboard.

## Platform gotchas

- macOS Accessibility (TCC) permission is tied to the code signature. An ad-hoc signed build loses the permission on every rebuild. Sign with the team in `Config/Local.xcconfig`; see the `.example` file.
- `security find-identity -v -p codesigning` lists 0 valid identities while an Apple Development cert is present: the Apple WWDR G3 intermediate is missing from the login keychain.
- Paths: the phone opens one flow per tailnet host and one per Bonjour interface, each pinned with `requiredInterface`. An unpinned UDP flow to a Bonjour service settles on Wi-Fi and stays there, even when client isolation drops every packet. AWDL comes from `includePeerToPeer` on both the listener and the browser.
- The Mac caps flows at 32. A flow whose first datagram fails to open is cancelled, and flows that never authenticated go after 3 s.
- `make install-mac` installs a Release build: a Debug build carries `get-task-allow`, so any same-user process could attach to an app that holds Accessibility.
- The iOS app refuses third-party keyboards (`AppDelegate`), since everything typed goes to the Mac.
- Route switches are enforced on the Mac: `Route.of` classifies each flow by the phone's address and a switched-off route gets no reply, so the phone's picker drops it. The Devices list shows the path the phone reports in `Packet.via` instead, because probes reach the Mac on every route.
- The iOS IPA ships unsigned (`make ipa`), and SideStore re-signs it on the phone.
- Raw UIKit touches with coalesced touches drive the trackpad. The screen has to stay at 120 Hz while a finger is down, because iOS delivers touches in step with the display.
- Mac input code ported from Entangle (MIT, (c) 2026 Gabriel Donadel) keeps that notice next to it.

## Public repo

Fixtures, docs and examples use fake data: `Example Mac`, `100.64.0.1`, `*.tail0000.ts.net`, `com.example.*`. Machine detail (team ID, hostnames, tailnet names, Apple ID) goes in gitignored `Config/Local.xcconfig` or `AGENTS.local.md`.
