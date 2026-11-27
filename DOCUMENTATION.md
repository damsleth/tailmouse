# Tailmouse documentation

The [README](README.md) tells you what Tailmouse is and how to build it. This document describes the routes, the modes of the iPhone app, how to pair and remove an iPhone, tells you what to expect from the Bluetooth route, and tells you how to find the cause of a pointer that stutters.

## Routes

A route is one way for the iPhone to reach the Mac. The same encrypted packets travel on every route.

| Route | Name on the iPhone | Needs | Typical round trip |
|---|---|---|---|
| USB cable | `USB` | The iPhone plugged into the Mac | Below 1 ms |
| Local network | `LAN` | Both devices on the same Wi-Fi or Ethernet | 2 to 5 ms |
| Peer-to-peer Wi-Fi | `AWDL` | Both devices near each other | 5 to 10 ms, with pauses |
| Tailnet | `Tailnet` | Tailscale on both devices | A few ms direct, more through a relay |
| Bluetooth | `BLE` | Both devices near each other | 30 to 60 ms |

The round trips are estimates. Only the Local network, Tailnet and Bluetooth values were measured. Measure your routes with the jitter log before you rely on them.

### How the iPhone selects a route

1. The iPhone sends a probe on every route once a second.
2. If the USB route answers, the iPhone uses it.
3. If the USB route does not answer, the iPhone uses the route with the lowest round trip.
4. The iPhone starts the AWDL route only when no other route answered for 2 seconds.

The round trip does not show short pauses. A route with a low round trip can still stutter. The Bluetooth route has a higher round trip than Wi-Fi, so the iPhone selects it only when the Wi-Fi routes are off.

### How to control the routes

- On the Mac, open **Settings › Routes**. Each route has a switch. The Mac does not answer on a route that is off.
- On the iPhone, **Settings › Use AWDL** permits or prevents the AWDL route.
- When the Mac is on a 6 GHz Wi-Fi network, the Mac sets the AWDL route to off and you cannot change the switch. Your selection comes back when the Mac joins a 2.4 GHz or 5 GHz network.
- To use the AWDL route on a 6 GHz network, set **Allow it on 6 GHz networks anyway** to on. Do this only on a network that blocks devices from each other, where AWDL is the only Wi-Fi route. The pointer then stops approximately two times each second on all Wi-Fi routes. Refer to [The pointer stutters about once a second](#the-pointer-stutters-about-once-a-second).
- On the iPhone, **Settings › Paths** shows the routes that are open. The **Bluetooth** line shows the state of the Bluetooth route.

To use the Bluetooth route, set the Local network, AWDL and Tailnet switches on the Mac to off.

### Permissions

- The Mac app asks for Bluetooth access when the Bluetooth route is on.
- The iPhone app asks for Bluetooth access after you pair it.
- If you refuse, the other routes continue to work.

## Modes

On the iPhone, **Settings › Mode** sets what the touch surface is.

| Mode | The surface |
|---|---|
| Trackpad | A trackpad, with the iPhone upright |
| Trackpad, landscape | A trackpad, with the iPhone on its side. The surface is wide, like the trackpad of a Mac |
| Drawing tablet | A drawing area of the Mac screen, with the iPhone on its side. Refer to [Drawing mode](#drawing-mode) |

The app does not turn when you turn the iPhone. The mode sets the direction.

## Drawing mode

In drawing mode, the surface of the iPhone is an area of the Mac screen. A touch puts the pointer at the same position in that area and holds the mouse button down. Thus a finger that moves makes a line in a drawing app.

### How to select the drawing area on the Mac

1. Open the Tailmouse menu in the menu bar and select **Drawing Area…**.
2. Select a mode in the bar at the bottom of the screen.

   | Mode | What to do |
   |---|---|
   | Entire Screen | Click a screen |
   | Window | Click a window |
   | Portion | Drag inside the rectangle to move it. Drag a side or a corner to change its size. Drag outside the rectangle to make a new one |

3. Push **Done** or the Return key. **Cancel** or the Esc key keeps the area that you had.

- When the area is a window, the area follows the window. The Mac reads the position of the window again each 2 seconds.
- If the window closes or the screen disconnects, the area is the main screen until you select a new one.

### How to draw on the iPhone

1. Set **Settings › Mode** to **Drawing tablet**.
2. The surface gets the same shape as the drawing area. This keeps a circle round.
3. Touch the surface and move your finger. Lift your finger to stop the line.
4. Set the mode to a trackpad mode to go back.

Limits:

- Only the first finger draws. There is no pressure: the iPhone does not measure it.
- You cannot move the pointer without a line. Go back to a trackpad mode to do that.
- On the Bluetooth route, the line gets approximately 30 points each second.

## How to pair and remove an iPhone

Each iPhone has its own key. The pairing code does not contain the key. The code holds a public key of the Mac, and the iPhone and the Mac calculate the key together (X25519). A copy of the code does not give the key.

### How to pair an iPhone

1. On the Mac, open **Open Tailmouse… › Devices** and push **Pair iPhone…**.
2. In Tailmouse on the iPhone, tap **Scan QR code**, allow the camera and point it at the code. The Camera app works too: scan the code and tap **Open in Tailmouse**.
3. The window closes when the iPhone has paired. Make sure that the iPhone is in the Devices list.

- One code pairs one iPhone. For a second iPhone, push **Pair iPhone…** again.
- A code that no iPhone used stops when you close the window.
- Keep the code off shared screens. The first iPhone that scans the code gets paired. If the window closes and your iPhone does not connect, a different iPhone used the code: remove it from the list and pair your iPhone again.
- An iPhone that you paired with an older version must pair again.
- If you pair an iPhone that is in the list already, it keeps its row and gets a new key. Its old key stops. If you deleted and installed the app again, the Mac sees a new iPhone: remove the old row.

### How to remove an iPhone

1. On the Mac, open **Open Tailmouse… › Devices**.
2. Select the iPhone and push **Remove**.

The Mac deletes the key of that iPhone. The Mac then gives no answer to it, and the iPhone shows `searching...`. The other iPhones stay paired. To use the removed iPhone again, pair it again.

### The names in the device list

iOS does not tell an app the name of the iPhone. The Mac finds the name from the address of the iPhone: the name of the iPhone in Tailscale, or its `.local` name on the local network. If the Mac finds no name, the list shows `iPhone`.

## The Bluetooth route

The Bluetooth route does not use the Wi-Fi radio, so AWDL does not disturb it. It is slower than Wi-Fi. Use it when there is no cable and no Wi-Fi route.

- iOS sets the time between two radio events to 30 ms. Thus the pointer gets a maximum of 33 new positions each second. The app cannot change this value.
- The iPhone sends a new position only when the Mac answered recent ones. A maximum of 3 positions wait for an answer. Without this limit, positions collect in the iPhone and arrive late.

The measurements below come from one iPhone and one Mac, approximately 1 m apart.

| Version of the route | Positions each second | Longest delay in a typical second |
|---|---|---|
| No limit on positions that wait | 30 to 60 | 150 to 1,850 ms |
| Limit of 2, packets of approximately 290 bytes | 11 to 31 | 50 to 100 ms |
| Limit of 3, packets of approximately 200 bytes | 25 to 47 | 50 to 70 ms |
| Limit of 3, packets of 77 bytes (current) | 17 to 48 | 30 to 60 ms |

The same test on a Local network route without AWDL pauses gives a longest delay of 5 ms.

## Versions

The iPhone app and the Mac app must use the same wire version. The current version is 3. An app with a different version gets no answer, and the iPhone shows `searching...`. Install the two apps from the same build.

## The pointer stutters about once a second

### Symptom

The pointer stops for approximately 100 ms, one or two times each second. The movement between the stops is smooth. The symptom is the same on the Local network route and the Tailnet route.

### Cause

AWDL is the peer-to-peer Wi-Fi that AirDrop, Handoff, Sidecar and Universal Control use. AWDL uses fixed channels: channel 6 on 2.4 GHz, and channels 44 and 149 on 5 GHz.

A Mac or an iPhone has one Wi-Fi radio. When the Wi-Fi network uses a different channel, the radio leaves the network at regular intervals to listen for AWDL. A 6 GHz network always uses a different channel. During each interval, the access point holds all the packets for that device.

The Local network route and the Tailnet route use the same radio. Thus the two routes stop at the same time.

The measurements below come from one 6 GHz network (channel 69, 160 MHz).

| Condition | Longest pause in a typical second |
|---|---|
| AWDL active on the Mac and on the iPhone, Local network route | 90 ms |
| AWDL active on the two devices, Tailnet route | 90 ms |
| AWDL route in use | 135 ms |
| AWDL stopped on the two devices, Local network route | 5 ms |
| AWDL stopped on the two devices, Tailnet route | 6 ms |

Each device adds its own pauses. The pointer is smooth only when AWDL is quiet on the Mac and on the iPhone.

The table below shows what makes the radio of the Mac leave the channel. Each value is the number of slow answers (more than 30 ms) in 500 pings to the router, sent at 50 each second, on the same network.

| Condition on the Mac | Slow answers |
|---|---|
| AirDrop set to Everyone | 58 to 64 |
| AirDrop set to Contacts Only or No One, AWDL route off | 0 |
| AirDrop set to Contacts Only, AWDL route on | 117 to 120 |

The AWDL interface (`awdl0`) stayed active in all three conditions. An active interface does not cause the pauses. A service that uses the interface does.

### What starts AWDL

- On the iPhone, an app that searches for a service with peer-to-peer Wi-Fi starts AWDL. Tailmouse did this at all times in early versions. It now does this only as a last resort.
- On the Mac, AirDrop starts AWDL when it is set to **Everyone**. With **Contacts Only** or **No One**, the radio stays on the channel.
- On the Mac, the AirDrop window in the Finder starts AWDL while it is open, with any AirDrop setting. Close the window. This was seen as a pointer that stutters. It was not measured with pings.
- On the Mac, the AWDL route of Tailmouse starts AWDL. Thus the Mac sets this route to off on a 6 GHz network.
- Sidecar and Universal Control use AWDL while they are in use. This was not measured.

### How to find the cause

1. Make sure that the iPhone is not connected with a cable.
2. Find the address of your Wi-Fi router.

   ```sh
   route -n get default | grep gateway
   ```

3. Send 500 pings to the router at 50 per second. Replace `192.0.2.1` with the address of your router.

   ```sh
   ping -i 0.02 -c 500 192.0.2.1
   ```

4. Read the `time=` values. A good result stays below 20 ms.
5. If the values go to 80 ms or more some times each second, the radio of the Mac leaves the channel.
6. Send the same pings to the address of the iPhone, with Tailmouse open on the iPhone.
7. If only the pings to the iPhone show the pauses, the radio of the iPhone leaves the channel.

If the radio of the Mac leaves the channel, look at the AirDrop setting first (refer to the remedies below). To confirm that AWDL on the Mac is the cause when the AirDrop setting is not, stop AWDL for 60 seconds and do the test again. This command needs an administrator password.

```sh
sudo sh -c 'for i in $(seq 60); do ifconfig awdl0 down; sleep 1; done'
```

AirDrop, Handoff, Sidecar and Universal Control do not work while AWDL is down. macOS starts AWDL again after the command stops.

### How to remove the stutter

Use the first remedy that is possible for you.

1. **Use the USB cable.** The USB route does not use a radio.
2. **Update the iPhone app.** Versions that use AWDL only as a last resort remove the pauses of the iPhone. Alternatively, set **Use AWDL** to off.
3. **Set AirDrop on the Mac to Contacts Only or No One.** Open **System Settings › General › AirDrop & Continuity**. The Mac app shows a warning in **Settings › Routes** and in its menu when AirDrop is set to Everyone on a 6 GHz network. AirDrop, Handoff and the other services continue to work.
4. **Close the AirDrop window in the Finder.**
5. **Move the Wi-Fi network to a 5 GHz channel that AWDL uses** (44 or 149). The radio then stays on one channel. This remedy is the common advice for AWDL pauses. It was not tested with Tailmouse.
6. **Use the Bluetooth route.** It does not use the Wi-Fi radio. The delay is 30 to 60 ms and the pointer gets approximately 30 positions each second. Refer to [The Bluetooth route](#the-bluetooth-route).
7. **Keep AWDL down on the Mac while you use Tailmouse.** Use the command above. The macOS services that use AWDL stop during that time. This is necessary only if the remedies above do not stop the pauses.

## The jitter log

The Mac app can write timing data for each route. Use it to find where a pause comes from.

1. Find the bundle identifier of the Mac app.

   ```sh
   osascript -e 'id of app "Tailmouse"'
   ```

2. Set the log to on. Replace `com.example.tailmouse.mac` with the bundle identifier.

   ```sh
   defaults write com.example.tailmouse.mac jitterLog -bool YES
   ```

3. Start the Mac app again.
4. Move one finger in circles on the iPhone for 15 seconds.
5. Read the log.

   ```sh
   /usr/bin/log show --last 5m --style compact --predicate 'subsystem == "tailmouse"'
   ```

Each line shows one route during one second.

```text
lan n=240 bursts=118 bytes=77 sendGap=16.6 arriveGap=102.7 late=95.6 ms
```

| Field | Meaning |
|---|---|
| `n` | The number of packets in that second |
| `bursts` | The number of arrivals more than 5 ms apart. On Bluetooth, this is the number of radio events in the second |
| `bytes` | The size of the smallest packet |
| `sendGap` | The longest time between two packets when the iPhone sent them |
| `arriveGap` | The longest time between two packets when the Mac received them |
| `late` | The longest delay of a packet, compared with the fastest packet on that route |

- If `sendGap` is high, the iPhone stopped. A finger that stops or lifts has the same effect.
- If `sendGap` is low and `late` is high, the network or a radio held the packets.
- If the two values are low and the pointer stutters, the cause is on the Mac after the packet arrived.

The category `ble` in the same log shows the state of the Bluetooth route on the Mac.

```sh
/usr/bin/log show --last 5m --style compact --predicate 'subsystem == "tailmouse" AND category == "ble"'
```
