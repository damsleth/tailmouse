# tailmouse

Use your iPhone as a trackpad and keyboard for your Mac. It connects over the local network, over Apple's peer-to-peer Wi-Fi (AWDL, the link AirDrop uses) or over Tailscale, whichever is fastest. That means it still works on Wi-Fi networks that isolate clients. Both ends are native Swift.

Status: early. v1 covers the trackpad and keyboard.

## Build

Requires Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set your team ID
make test       # protocol tests
make run-mac    # build and launch the menu bar app
make ipa        # unsigned build/Tailmouse.ipa, for SideStore
```

Credit: the pointer model (cumulative totals) and several CGEvent details come from [Entangle](https://github.com/gabrieldonadel/entangle) (MIT).
