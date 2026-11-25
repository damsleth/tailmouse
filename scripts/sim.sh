#!/bin/sh
# Install the simulator build, pair it with the Mac app running on this machine
# (key read from the login Keychain), and launch it. No QR scan, no tapping.
# Usage: scripts/sim.sh [screenshot.png]
set -eu
cd "$(dirname "$0")/.."
app=build/Build/Products/Debug-iphonesimulator/Tailmouse.app
bid=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")
dev=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1 || true)
if [ -z "$dev" ]; then
  dev=$(xcrun simctl list devices available | grep -E 'iPhone' | grep -oE '[0-9A-F-]{36}' | head -1)
  xcrun simctl boot "$dev"
fi
xcrun simctl install "$dev" "$app"
data=$(xcrun simctl get_app_container "$dev" "$bid" data)
mkdir -p "$data/Library/Application Support"
key=$(security find-generic-password -s tailmouse -a pairing-key -w)
name=$(scutil --get ComputerName)
# This Mac's tailnet addresses (100.64.0.0/10), so the tailnet path runs too.
hosts=$(ifconfig | awk '/inet 100\./ {print $2}')
macbid=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' build/Build/Products/Debug/Tailmouse.app/Contents/Info.plist)
port=$(defaults read "$macbid" port 2>/dev/null || echo 47474)
python3 -I - "$key" "$name" "$port" "$data/Library/Application Support/pairing.json" $hosts <<'EOF'
import base64, ipaddress, json, sys
h, name, port, out, *hosts = sys.argv[1:]
hosts = [a for a in hosts if ipaddress.ip_address(a) in ipaddress.ip_network("100.64.0.0/10")]
key = bytes.fromhex(h) if len(h) == 64 else h.encode()
json.dump({"key": base64.b64encode(key).decode(), "name": name, "port": int(port), "hosts": hosts}, open(out, "w"))
EOF
xcrun simctl terminate "$dev" "$bid" 2>/dev/null || true
xcrun simctl launch "$dev" "$bid" >/dev/null
if [ $# -gt 0 ]; then
  sleep 4
  xcrun simctl io "$dev" screenshot "$1" >/dev/null 2>&1
  echo "$1"
fi
