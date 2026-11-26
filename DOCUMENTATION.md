# Tailmouse documentation

The [README](README.md) tells you what Tailmouse is and how to build it. This document describes the routes and tells you what to expect from the Bluetooth route, and tells you how to find the cause of a pointer that stutters.

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
- On the iPhone, **Settings › Paths** shows the routes that are open. The **Bluetooth** line shows the state of the Bluetooth route.

To use the Bluetooth route, set the Local network, AWDL and Tailnet switches on the Mac to off.

### Permissions

- The Mac app asks for Bluetooth access when the Bluetooth route is on.
- The iPhone app asks for Bluetooth access after you pair it.
- If you refuse, the other routes continue to work.

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

The iPhone app and the Mac app must use the same wire version. The current version is 2. An app with a different version gets no answer, and the iPhone shows `searching...`. Install the two apps from the same build.

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

### What starts AWDL

- On the iPhone, an app that searches for a service with peer-to-peer Wi-Fi starts AWDL. Tailmouse did this at all times in early versions. It now does this only as a last resort.
- On the Mac, macOS starts AWDL for its own services. The AWDL switch in Tailmouse does not stop them.

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

To confirm that AWDL on the Mac is the cause, stop it for 60 seconds and do the test again.

```sh
sudo sh -c 'for i in $(seq 60); do ifconfig awdl0 down; sleep 1; done'
```

AirDrop, Handoff, Sidecar and Universal Control do not work while AWDL is down. macOS starts AWDL again after the command stops.

### How to remove the stutter

Use the first remedy that is possible for you.

1. **Use the USB cable.** The USB route does not use a radio.
2. **Update the iPhone app.** Versions that use AWDL only as a last resort remove the pauses of the iPhone. Alternatively, set **Use AWDL** to off.
3. **Move the Wi-Fi network to a 5 GHz channel that AWDL uses** (44 or 149). The radio then stays on one channel. This remedy is the common advice for AWDL pauses. It was not tested with Tailmouse.
4. **Use the Bluetooth route.** It does not use the Wi-Fi radio. The delay is 30 to 60 ms and the pointer gets approximately 30 positions each second. Refer to [The Bluetooth route](#the-bluetooth-route).
5. **Keep AWDL down on the Mac while you use Tailmouse.** Use the command above. The macOS services that use AWDL stop during that time.

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
