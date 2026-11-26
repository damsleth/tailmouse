# AGENTS.md

Tailmouse turns an iPhone into a trackpad and keyboard for a Mac. Both ends are native Swift. They talk over one UDP socket that works over a USB cable, over the LAN (Bonjour), over AWDL (Apple peer-to-peer Wi-Fi, the AirDrop link) and over a tailnet (Tailscale). The phone probes all four and uses the cable when it answers, otherwise the fastest live one. AWDL and the tailnet get around Wi-Fi client isolation; AWDL avoids the DERP relay detour.

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
- The phone sends only on flows in `.ready`. An `NWConnection` that is still resolving or waiting queues every send, and cancelling one with a few thousand queued overflows the stack in Network.framework's recursive dealloc (SIGBUS in `NWConcrete_nw_write_request dealloc`). The 1 s probe fills such a queue in under an hour while another path keeps the session alive.
- USB: a plugged-in iPhone shows up on the Mac as two NCM Ethernet interfaces (`enN`, link-local only, absent from `networksetup`), and Bonjour runs on them, so the cable needs no code of its own beyond a name. The phone labels any Bonjour interface that is not Wi-Fi or AWDL "USB"; the Mac recognises the interface in the IORegistry (`isPhoneUSB`: `AppleUSBNCMData` under an Apple `IOUSBHostDevice`). `PathPicker` picks a live "USB" path over any radio, whatever the RTTs say. The simulator has no cable; `lsof -nP -a -c Tailmouse -iUDP` on the Mac shows whether a real phone has a flow on the USB interface.
- The phone rebuilds its flows (`reconnect`) on a network path update only when nothing has answered for 1.5 s. Path updates come every few seconds with a cable or AWDL around, and each rebuild stalls the pointer while Bonjour resolves. New interfaces arrive through the browser instead.
- AWDL is a last resort on the phone (`Client.awdlUp`): it browses and connects over AWDL only after nothing else answered for 2 s. A peer-to-peer browse alone makes the phone's radio leave the Wi-Fi channel for ~100 ms about twice a second (measured on a 6 GHz network), which stalls LAN and tailnet too. The Mac's radio does the same for macOS's own AWDL services (Handoff, AirDrop); only `sudo ifconfig awdl0 down`, a 5 GHz network on channel 44 or 149, or the cable avoids that, not the app.
- The Mac caps flows at 32. A flow whose first datagram fails to open is cancelled, and flows that never authenticated go after 3 s.
- `make install-mac` installs a Release build: a Debug build carries `get-task-allow`, so any same-user process could attach to an app that holds Accessibility.
- The iOS app refuses third-party keyboards (`AppDelegate`), since everything typed goes to the Mac.
- Route switches are enforced on the Mac: `Route.of` classifies each flow by the phone's address and a switched-off route gets no reply, so the phone's picker drops it. The Devices list shows the path the phone reports in `Packet.via` instead, because probes reach the Mac on every route.
- The iOS IPA ships unsigned (`make ipa`), and SideStore re-signs it on the phone.
- Pointer stutter: `defaults write <Mac bundle id> jitterLog -bool YES`, restart the Mac app, then `/usr/bin/log stream --predicate 'subsystem == "tailmouse"'` prints one line per route per second of traffic. `sendGap` spikes mean the phone stalled, `late` spikes with a steady `sendGap` mean the radio or network did. A stall of about 100 ms once or twice a second with a steady `sendGap` is AWDL: `ping -i 0.02` from the Mac to the gateway shows the Mac's radio hopping, to the phone the phone's.
- `Client` publishes only changed values from `received`: the Mac answers every packet, and each `@Published` write redraws the UI on the thread that handles touches.
- Raw UIKit touches with coalesced touches drive the trackpad. The screen has to stay at 120 Hz while a finger is down, because iOS delivers touches in step with the display.
- Mac input code ported from Entangle (MIT, (c) 2026 Gabriel Donadel) keeps that notice next to it.

## Public repo

Fixtures, docs and examples use fake data: `Example Mac`, `100.64.0.1`, `*.tail0000.ts.net`, `com.example.*`. Machine detail (team ID, hostnames, tailnet names, Apple ID) goes in gitignored `Config/Local.xcconfig` or `AGENTS.local.md`.
