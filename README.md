# Thrustmaster T300RS — macOS Driver

Userspace driver + GUI app for the **Thrustmaster T300RS / T300RS GT Edition** racing wheel on **macOS** (Apple Silicon and Intel). Out of the box macOS treats the wheel as a generic gamepad with 12-bit steering, no force feedback, a stuck default rotation range, a missing clutch pedal, and a cursor that drifts from the brake axis. This driver fixes all of that and adds **live game-aware force feedback** for Euro Truck Simulator 2.

## What's in the box

| Component | What it does |
|-----------|--------------|
| `ThrustmasterWheel` CLI | Root daemon. Switches the wheel to full T300RS mode, captures it from macOS HID, creates a clean virtual joystick for games, drives the force-feedback motor. |
| `ETS2FFControl.app` | SwiftUI GUI (non-root). Live sliders for every FF parameter, named presets, real-time speed/RPM/gear readout. Talks to the daemon over a Unix socket. |
| `ff_telemetry.so` | SCS telemetry plugin for ETS2. Publishes live game state into shared memory so the daemon can drive FF from it. |

## Features

- **Full T300RS mode** — 16-bit steering, 10-bit pedals, clutch pedal, all 13 buttons, hat switch
- **Configurable rotation range** — 40°…1080°, live-adjustable
- **Baseline force feedback** — self-centering spring + damper, always on
- **Live FF from ETS2 telemetry** — self-centering by speed, engine rumble, road-surface texture, suspension bumps, collision impacts, ABS shiver, gearshift thunk, trailer-sway correction, vertical impacts, heavy-parking effort
- **No cursor drift** — direct USB capture bypasses the macOS HID layer
- **CrossOver / Wine support** — separate mode that configures the wheel then leaves it for Wine

## Three modes

| Mode | Best for | Needs SIP/AMFI off? | Virtual device? |
|------|----------|---------------------|-----------------|
| **ETS2 native (default with `--ets2`)** | Euro Truck Simulator 2 on native macOS | Yes | Yes |
| **Native (no telemetry)** | Any other native macOS game | Yes | Yes |
| **CrossOver (`--crossover`)** | Games running in Wine/CrossOver (ETS2 via CrossOver, assetto etc.) | No | No |

---

## Requirements

- Apple Silicon or Intel Mac, macOS 13+
- **Swift 5.9 toolchain** (Xcode command-line tools `xcode-select --install`)
- SIP and AMFI **disabled** for native / ETS2 modes (one-time setup, see below). Not required for CrossOver mode.

## macOS security setup (native + ETS2 modes)

macOS won't let a userspace process create a virtual HID device without a restricted entitlement. We bypass this by disabling two security features.

### 1. Disable SIP (System Integrity Protection)

Boot into **Recovery Mode**: shut down, then hold the Power button until you see the Apple logo + "Loading startup options". Pick Options → Terminal. Then:

```bash
csrutil disable
```

Reboot.

### 2. Disable AMFI (Apple Mobile File Integrity)

From a normal Terminal:

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1"
```

Reboot.

### Consequences of disabling SIP + AMFI

- System files in `/System` become writable as root. Be careful — don't casually `rm`.
- macOS will show a warning in System Settings → Privacy & Security.
- Unsigned kernel extensions and restricted entitlements become usable.
- macOS Software Updates still work normally.
- **You can re-enable both any time:** boot into Recovery, run `csrutil enable`, then `sudo nvram -d boot-args` and reboot. The wheel driver stops working (native mode) but CrossOver mode is unaffected.

If this is too invasive, use **`--crossover` mode** instead — it doesn't need either of these disabled.

---

## Build

```bash
git clone <this-repo>
cd ThrustmasterWheel

# Build the daemon + GUI app
./build_app.sh

# (Optional) build the ETS2 plugin if you want telemetry FF
cd ets2_plugin
make
make install   # copies ff_telemetry.so into the game bundle
cd ..
```

Ad-hoc signing with entitlement (required for native/ETS2 modes):

```bash
codesign --force --sign - --entitlements entitlements.plist .build/release/ThrustmasterWheel
```

For **CrossOver mode only**, sign without the entitlement:

```bash
codesign --force --sign - .build/release/ThrustmasterWheel
```

---

## Run

### ETS2 with live telemetry FF

```bash
# Terminal 1 — daemon
sudo .build/release/ThrustmasterWheel --range 1080 --ets2

# GUI app (Finder or command line)
open ETS2FFControl.app
```

Launch ETS2. The GUI shows a green dot next to "ETS2 live" when the plugin connects. Move sliders, click **Accept**, the wheel updates instantly. Settings persist to `~/Library/Application Support/ThrustmasterWheel/settings.json`.

### Any other native macOS game

```bash
sudo .build/release/ThrustmasterWheel --range 900 --spring 70 --damper 25
```

### CrossOver / Wine

```bash
# Terminal 1 — keep open during the game
sudo .build/release/ThrustmasterWheel --crossover --range 900

# Terminal 2 — launch CrossOver with HIDAPI disabled
# (forces SDL to use IOKit so the wheel appears in DirectInput, not XInput)
SDL_JOYSTICK_HIDAPI=0 open -a CrossOver
```

In Wine's "Game Controllers → Advanced" enable SDL. The wheel appears as **Thrustmaster T300RS Racing wheel** under the DInput tab.

---

## CLI reference

| Option | Default | Description |
|--------|---------|-------------|
| `--range <40-1080>` | 1080 | Rotation range, degrees |
| `--gain <0-65535>` | 42000 | FF master gain |
| `--spring <0-100>` | 70 | Baseline self-centering spring |
| `--damper <0-100>` | 25 | Baseline damper resistance |
| `--no-ff` | – | Disable all force feedback |
| `--ets2` | off | Read ETS2 telemetry via shared memory and drive live FF |
| `--ets2-hz <30-240>` | 120 | Telemetry poll rate (Hz) |
| `--crossover` | off | Config-only mode (no capture, no virtual device) |
| `--no-modeswitch` | – | Skip USB mode switch |
| `--no-virtual` | – | Skip virtual device creation |
| `--debug` | – | Print raw HID report byte changes |
| `--axes` | – | Print live axis values every ~50 reports |
| `TM_VERBOSE=1` *(env)* | – | Enable chatty internal logs (enumeration, timing, hex dumps) |

---

## Control app sliders

Nine tuning knobs, plus range and gain, plus five named presets.

### Wheel
- **Rotation range** — physical lock-to-lock, 40°…1080°.
- **Force feedback strength** — master gain, 0…65535.

### Baseline feel (always on)
- **Self-centering spring** — 0…100%, quadratic scaling.
- **Damper resistance** — 0…100%, resistance proportional to rotation speed.

### ETS2 telemetry mix (in-game only)
- **Self-centering (speed-based)** — adds a pull toward straight that grows with speed².
- **Engine rumble** — periodic vibration whose frequency tracks RPM.
- **Road surface rumble** — amplitude varies by surface: smooth, coarse, dirt, grass, slippery, rumble strips.
- **Suspension bumps** — sharp impulses from front-wheel suspension deltas.
- **Collision impacts** — yank from lateral acceleration spikes.

### Pro tactile effects
- **ABS shiver** — ~55 Hz staccato when wheels lock under braking.
- **Gearshift thunk** — short impulse on gear change.
- **Trailer-sway correction** — counter-force when trailer yaws while driver is going straight.
- **Vertical impact** — burst from big `accel_y` spikes (potholes, curb drops).
- **Heavy parking with trailer** — amplifies steering effort at near-zero speed with trailer.

### Presets

- **Realistic Truck** — 1080°, balanced, full telemetry mix on.
- **Light Arcade** — 540°, responsive, lighter feel.
- **Heavy Rig** — 1080°, strong FF, for a rigid wheel stand.
- **Quiet Night** — 900°, gentle, no sharp impulses.
- **Custom** — auto-selected the moment you drag a slider.

---

## File layout

```
ThrustmasterWheel/
├── Package.swift
├── Sources/
│   ├── CUSBModeSwitch/          # C layer: USB I/O, FF packets, virtual HID
│   ├── ETS2FFCore/              # Shared Swift types (Settings, ControlMessage)
│   ├── ThrustmasterWheel/       # Daemon (CLI)
│   └── ETS2FFControl/           # SwiftUI GUI app
├── ets2_plugin/                 # ETS2 SCS telemetry plugin (C++)
│   ├── ff_plugin.cpp
│   ├── ets2_ff_shm.h            # Shared memory layout (seqlock)
│   └── Makefile
├── build_app.sh                 # Builds daemon + wraps .app bundle
├── entitlements.plist           # Required for IOHIDUserDevice creation
└── ETS2FFControl.app            # Built GUI app (after build_app.sh)
```

---

## Troubleshooting

**`zsh: killed`** — Binary is signed with the entitlement but AMFI is still on. Either disable AMFI (see above) or strip entitlements for CrossOver mode: `codesign --force --sign - .build/release/ThrustmasterWheel`.

**`[3/4] Virtual joystick · FAILED`** — `IOHIDUserDeviceCreate` returned NULL after 6 retries. Unplug the wheel, plug it back in, try again. If it persists, reboot.

**`[4/4] USB capture · FAILED`** — The wheel is held by another process (often a previous crashed daemon). `sudo pkill -9 ThrustmasterWheel`, disconnect/reconnect the wheel, retry.

**ETS2 plugin not loading** — Check the file is at `Euro Truck Simulator 2.app/Contents/MacOS/plugins/ff_telemetry.so` (note: plugins folder is *inside* the game bundle), is Mach-O x86_64 (`file ff_telemetry.so`), and named exactly `ff_telemetry.so`.

**ETS2 shows IDLE / 0 km/h in the daemon log** — Plugin is connected but you aren't in a truck (main menu, save screen, save loading). Load a drive.

**`ETS2 plugin version mismatch`** — You rebuilt the daemon but not the plugin (or vice versa). Rebuild and `make install` the plugin.

**`ETS2FFControl.app` stays "Waiting for daemon…"** — Start the daemon first, the app auto-reconnects every 1.5 s.

**Settings file owned by root** — If the daemon was killed hard it may have left the JSON with root ownership. `sudo chown $(whoami):staff ~/Library/Application\ Support/ThrustmasterWheel/settings.json`.

**CrossOver shows the wheel as XInput gamepad, not DirectInput wheel** — You forgot `SDL_JOYSTICK_HIDAPI=0` when launching CrossOver.

**Need to see internal timings and hex dumps** — Run with `TM_VERBOSE=1 sudo .build/release/ThrustmasterWheel …`.

---

## Limitations

- **Game-controlled FF not implemented.** Forza/F1 etc. on native macOS can't send their own FF commands to the wheel — that would need a DriverKit extension we haven't built. Our ETS2 integration works because we read telemetry ourselves. CrossOver/Wine games have whatever FF Wine supports.
- **ETS2 plugin is x86_64 only.** SCS macOS game is x86_64 (runs under Rosetta on Apple Silicon); the plugin matches. No arm64 support needed or provided.
- **Collision detection is heuristic.** SCS SDK 1.14 doesn't expose a clean collision event; we infer from lateral-acceleration spikes.
- **Requires `sudo`.** USB device capture needs root.
- **SIP + AMFI disabled** for native modes. See above for consequences.

---

## Credits

The USB protocol, HID descriptor, and FF packet formats were reverse-engineered from the Linux [hid-tmff2](https://github.com/Kimplul/hid-tmff2) kernel driver by Kimplul. Telemetry integration uses the [SCS Software Telemetry SDK](https://modding.scssoft.com/wiki/Documentation/Engine/SDK/Telemetry) v1.14.

For the full design story and every technical hurdle along the way, see [`progress.md`](./progress.md).

[Русский перевод README](./README_RU.md)
