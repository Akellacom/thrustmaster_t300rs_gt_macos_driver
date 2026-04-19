import Foundation
import IOKit.hid
import CoreGraphics
import CUSBModeSwitch
import ETS2FFCore

// MARK: - Startup banner

let daemonVersion = "1.0"
print("Thrustmaster T300RS · macOS driver v\(daemonVersion)")

var config = WheelConfiguration.fromArguments()

// Merge persisted UI settings so the daemon boots with whatever the user last
// chose in ETS2FFControl.app. CLI flags always win — we only fill in fields
// the user didn't pass.
let defaultConfig = WheelConfiguration()
let persisted = SettingsStore.load()
var activeSettings = persisted

if config.range == defaultConfig.range           { config.range = UInt16(persisted.range) }
if config.gain == defaultConfig.gain             { config.gain = UInt16(persisted.gain) }
if config.springStrength == defaultConfig.springStrength { config.springStrength = UInt16(persisted.spring) }
if config.damperStrength == defaultConfig.damperStrength { config.damperStrength = UInt16(persisted.damper) }

activeSettings.range  = Int(config.range)
activeSettings.gain   = Int(config.gain)
activeSettings.spring = Int(config.springStrength)
activeSettings.damper = Int(config.damperStrength)

// MARK: - Ctrl+C handler

signal(SIGINT) { _ in
    print("\nShutting down…")
    CFRunLoopStop(CFRunLoopGetMain())
}

// MARK: - Step 1/4: Mode switch + wheel configuration

let modeSwitch = USBModeSwitch()

if config.performModeSwitch {
    if modeSwitch.isModeSwitchedDevicePresent() {
        print("[1/4] Mode switch          · already switched")
    } else {
        do {
            try modeSwitch.performModeSwitch()
            print("[1/4] Mode switch          · done")
        } catch {
            print("[1/4] Mode switch          · FAILED (\(error)) — continuing in FFB mode")
        }
    }
} else {
    print("[1/4] Mode switch          · skipped (--no-modeswitch)")
}

// Configure range + gain via interrupt OUT (captures device briefly).
let cfgResult = Int(thrustmaster_configure_wheel(
    UInt16(ThrustmasterUSB.vendorID),
    UInt16(ThrustmasterUSB.t300rsPS3Normal),
    UInt16(config.range),
    UInt16(config.gain)
))
if cfgResult == 0 {
    print("[2/4] Wheel configured     · \(config.range)° · gain \(config.gain)")
} else {
    print("[2/4] Wheel configured     · FAILED (code \(cfgResult))")
}

// Wait briefly for the device to reappear after re-enumeration.
if config.performModeSwitch && !modeSwitch.isModeSwitchedDevicePresent() {
    for _ in 1...10 {
        usleep(500_000)
        if modeSwitch.isModeSwitchedDevicePresent() { break }
    }
}

// MARK: - Step 3/4: Virtual joystick

let translator = ReportTranslator()
translator.mode = .t300rsNormal
translator.debugMode = config.debugReports

var virtualDevice: VirtualHIDDevice?

if config.crossoverMode {
    // CrossOver/Wine mode: wheel left for Wine to access directly.
    print("[3/4] CrossOver/Wine mode  · wheel left accessible to Wine")
    print("      Launch CrossOver with SDL_JOYSTICK_HIDAPI=0")
    print("Ready. Press Ctrl+C when done.")
    CFRunLoopRun()
    print("Shutting down.")
    exit(0)
}

if !config.skipVirtualDevice {
    virtualDevice = VirtualHIDDevice()
    do {
        try virtualDevice?.create()
        print("[3/4] Virtual joystick     · \(VirtualHIDDevice.Identity.t300rs.productName)")
    } catch {
        print("[3/4] Virtual joystick     · FAILED")
        print("      macOS rejected IOHIDUserDeviceCreate. Check:")
        print("        · SIP disabled (csrutil status)")
        print("        · AMFI disabled (nvram boot-args)")
        print("        · running as root (sudo)")
        print("        · unplug/replug the wheel, reboot if needed")
        virtualDevice = nil
    }
} else {
    print("[3/4] Virtual joystick     · skipped (--no-virtual)")
}

// MARK: - Step 4/4: Direct USB capture

var reportCount: UInt64 = 0

let usbResult = thrustmaster_usb_start(
    UInt16(ThrustmasterUSB.vendorID),
    UInt16(ThrustmasterUSB.t300rsPS3Normal),
    UInt16(config.range),
    UInt16(config.gain),
    { data, length, context in
        guard let data = data, length > 1 else { return }
        reportCount += 1
        let reportID = UInt32(data[0])
        let reportData = UnsafeBufferPointer(start: data + 1, count: Int(length) - 1)
        translator.processReport(reportData, reportID: reportID)
        if let vd = virtualDevice {
            try? vd.sendInputReport(translator.buildVirtualReport())
        }
        if config.printAxes && reportCount % 50 == 0 {
            translator.printState()
        }
    },
    nil,
    CFRunLoopGetCurrent()
)

if usbResult == 0 {
    print("[4/4] USB capture          · active (no cursor drift)")
} else {
    print("[4/4] USB capture          · FAILED (code \(usbResult))")
    print("      Unplug the wheel, plug it back in, try again.")
}

// MARK: - Baseline spring + damper

if usbResult == 0 && !config.noFF {
    usleep(100_000)
    if config.springStrength > 0 {
        thrustmaster_ff_spring(1, UInt16(config.springStrength))
        thrustmaster_ff_play(1)
        usleep(20_000)
    }
    if config.damperStrength > 0 {
        thrustmaster_ff_damper(2, UInt16(config.damperStrength))
        thrustmaster_ff_play(2)
        usleep(20_000)
    }
    print("Force feedback             · spring \(config.springStrength)% · damper \(config.damperStrength)%")
}

// MARK: - ETS2 telemetry bridge

var telemetryReader: TelemetryReader?
var ffMixer: FFMixer?
var ets2Timer: CFRunLoopTimer?
var ets2PrimedOnce = false

if config.ets2Enabled && !config.noFF && usbResult == 0 {
    let reader = TelemetryReader()
    let mixer = FFMixer()
    telemetryReader = reader
    ffMixer = mixer
    print("ETS2 telemetry             · waiting for plugin…")

    let intervalSec = 1.0 / Double(config.ets2PollHz)
    let tickerBody: (CFRunLoopTimer?) -> Void = { _ in
        if telemetryReader?.state.pluginAlive == false && !ets2PrimedOnce {
            _ = reader.open()
        }
        guard reader.poll() else { return }
        if !ets2PrimedOnce && reader.state.pluginAlive {
            mixer.prime(state: reader.state)
            ets2PrimedOnce = true
            print("ETS2 telemetry             · connected")
        }
        if ets2PrimedOnce {
            mixer.update(state: reader.state, live: reader.isConnected)
        }
    }
    ets2Timer = CFRunLoopTimerCreateWithHandler(
        kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + 0.5,
        intervalSec,
        0, 0,
        tickerBody
    )
    if let t = ets2Timer {
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, .commonModes)
    }
}

// MARK: - Control socket (GUI app)

let controlServer = ControlServer()
ffMixer?.applySettings(activeSettings)

let applySettingsLive: (FFSettings) -> Void = { s in
    if s.gain != activeSettings.gain {
        _ = thrustmaster_set_gain_live(UInt16(min(max(s.gain, 0), 65535)))
    }
    if s.range != activeSettings.range {
        _ = thrustmaster_set_range_live(UInt16(min(max(s.range, 40), 1080)))
    }
    if s.spring != activeSettings.spring {
        _ = thrustmaster_ff_spring(1, UInt16(min(max(s.spring, 0), 100)))
        _ = thrustmaster_ff_play(1)
    }
    if s.damper != activeSettings.damper {
        _ = thrustmaster_ff_damper(2, UInt16(min(max(s.damper, 0), 100)))
        _ = thrustmaster_ff_play(2)
    }
    ffMixer?.applySettings(s)
    activeSettings = s
    SettingsStore.save(s)
}

controlServer.onApply = applySettingsLive
controlServer.statusProvider = {
    let r = telemetryReader?.state
    return FFStatus(
        daemonVersion: daemonVersion,
        wheelConnected: usbResult == 0,
        ets2Connected: r?.pluginAlive ?? false,
        ets2Live: telemetryReader?.isConnected ?? false,
        currentSettings: activeSettings,
        speedKmh: Int((r?.speed ?? 0) * 3.6),
        rpm: Int(r?.engineRPM ?? 0),
        gear: Int(r?.engineGear ?? 0)
    )
}
do {
    try controlServer.start()
    print("Control socket             · \(ControlPaths.socketPath)")
} catch {
    print("Control socket             · failed (\(error))")
}

print("Ready. Press Ctrl+C to exit.")

// MARK: - Run loop

CFRunLoopRun()

// MARK: - Cleanup

controlServer.stop()
if let t = ets2Timer { CFRunLoopTimerInvalidate(t) }
ffMixer?.stop()
telemetryReader?.close()
thrustmaster_ff_stop(1)
thrustmaster_ff_stop(2)
usleep(50_000)
thrustmaster_usb_stop()
virtualDevice?.destroy()
print("Clean exit.")
