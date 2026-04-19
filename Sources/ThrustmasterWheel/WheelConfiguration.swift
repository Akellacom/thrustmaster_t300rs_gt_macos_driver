import Foundation

/// Runtime configuration for the Thrustmaster T300RS driver.
struct WheelConfiguration {
    /// Rotation range in degrees (40..1080).
    var range: UInt16 = 1080

    /// Force-feedback master gain (0..65535).
    var gain: UInt16 = 42000

    /// Run the USB mode-switch from generic "FFB Wheel" to full T300RS.
    var performModeSwitch: Bool = true

    /// Print each raw HID-report axis line (debug only).
    var printAxes: Bool = false

    /// Print raw HID-report byte changes (debug only).
    var debugReports: Bool = false

    /// Skip creating the virtual HID joystick (advanced diagnostic).
    var skipVirtualDevice: Bool = false

    /// Spring baseline strength (0..100). Quadratic scaling.
    var springStrength: UInt16 = 70

    /// Damper baseline resistance (0..100). Quadratic scaling.
    var damperStrength: UInt16 = 25

    /// Disable all FF effects (both static and ETS2 live mix).
    var noFF: Bool = false

    /// CrossOver / Wine mode: configure the wheel then leave it for Wine.
    /// No virtual device, no USB capture.
    var crossoverMode: Bool = false

    /// Read ETS2 telemetry via shared memory and drive live FF effects.
    var ets2Enabled: Bool = false

    /// ETS2 telemetry poll rate (Hz).
    var ets2PollHz: Int = 120

    /// Parse command-line arguments.
    static func fromArguments() -> WheelConfiguration {
        var config = WheelConfiguration()
        let args = CommandLine.arguments

        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--range":
                if i + 1 < args.count, let val = UInt16(args[i + 1]) {
                    config.range = min(max(val, 40), 1080); i += 1
                }
            case "--gain":
                if i + 1 < args.count, let val = UInt16(args[i + 1]) {
                    config.gain = val; i += 1
                }
            case "--spring":
                if i + 1 < args.count, let val = UInt16(args[i + 1]) {
                    config.springStrength = min(val, 100); i += 1
                }
            case "--damper":
                if i + 1 < args.count, let val = UInt16(args[i + 1]) {
                    config.damperStrength = min(val, 100); i += 1
                }
            case "--no-ff":
                config.noFF = true
            case "--ets2":
                config.ets2Enabled = true
            case "--ets2-hz":
                if i + 1 < args.count, let val = Int(args[i + 1]) {
                    config.ets2PollHz = min(max(val, 30), 240); i += 1
                }
            case "--crossover":
                config.crossoverMode = true
                config.skipVirtualDevice = true
                config.noFF = true
            case "--no-modeswitch":
                config.performModeSwitch = false
            case "--no-virtual":
                config.skipVirtualDevice = true
            case "--debug":
                config.debugReports = true
            case "--axes":
                config.printAxes = true
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                break
            }
            i += 1
        }
        return config
    }

    static func printUsage() {
        print("""
        Thrustmaster T300RS — macOS Driver

        Usage: sudo ThrustmasterWheel [options]

        Wheel:
          --range <40-1080>     Rotation range in degrees (default: 1080)
          --gain <0-65535>      Force-feedback master gain (default: 42000)

        Force Feedback:
          --spring <0-100>      Baseline self-centering spring (default: 70)
          --damper <0-100>      Baseline damper resistance (default: 25)
          --no-ff               Disable all FF effects
          --ets2                Drive live FF from ETS2 telemetry
          --ets2-hz <30-240>    Telemetry poll rate (default: 120)

        Modes:
          --crossover           Config-only mode for Wine / CrossOver
                                (no USB capture, no virtual device)

        Advanced:
          --no-modeswitch       Skip USB mode switch
          --no-virtual          Skip virtual device creation
          --debug               Print raw HID report byte changes
          --axes                Print live axis values each frame
          --help, -h            Show this help

        Examples:
          sudo ./ThrustmasterWheel --range 1080 --ets2
          sudo ./ThrustmasterWheel --crossover --range 900
          sudo ./ThrustmasterWheel --range 540 --spring 80 --damper 60
        """)
    }
}
