import Foundation

// MARK: - USB Identifiers

enum ThrustmasterUSB {
    static let vendorID: UInt16 = 0x044F

    // Product IDs
    static let genericFFBWheel: UInt16 = 0xB65D   // Initial generic identity
    static let t300rsPS3Normal: UInt16 = 0xB66E    // T300RS PS3/PC normal mode
    static let t300rsPS3Advanced: UInt16 = 0xB66F  // T300RS PS3/PC advanced mode
    static let t300rsPS4Normal: UInt16 = 0xB66D    // T300RS PS4 mode

    // All product IDs we handle after mode switch
    static let modeSwitchedIDs: Set<UInt16> = [
        t300rsPS3Normal,
        t300rsPS3Advanced,
        t300rsPS4Normal,
    ]
}

// MARK: - USB Control Transfer Constants

enum USBControlTransfer {
    // Request types
    static let vendorDeviceIn: UInt8 = 0xC1   // Device-to-host, vendor, device
    static let vendorDeviceOut: UInt8 = 0x41  // Host-to-device, vendor, device

    // Request codes
    static let modelQuery: UInt8 = 0x49       // bRequest for model identification
    static let modeSwitch: UInt8 = 0x53       // bRequest for mode switching
    static let firmwareQuery: UInt8 = 0x56    // bRequest for firmware version

    // Mode switch wValue codes
    static let switchToT300RS: UInt16 = 0x0005
    static let switchToAdvanced: UInt16 = 0x0003
}

// MARK: - Initialization Sequences

enum T300RSInit {
    /// Pre-initialization interrupt packets sent to endpoint 1
    /// These MUST be sent before the mode switch to prevent crashes
    static let setupPackets: [[UInt8]] = [
        [0x42, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        [0x0a, 0x04, 0x90, 0x03, 0x00, 0x00, 0x00, 0x00],
        [0x0a, 0x04, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x00],
        [0x0a, 0x04, 0x12, 0x10, 0x00, 0x00, 0x00, 0x00],
        [0x0a, 0x04, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00],
    ]

    /// Model identification codes from query response
    enum Model: UInt16 {
        case t300rs = 0x0602
        case t300ferrari = 0x0402
        case t150 = 0x0603
        case tmx = 0x0704
        case t500rs = 0x0200
    }

    /// Attachment codes
    enum Attachment: UInt8 {
        case standard = 0x06
        case f1Wheel = 0x03
        case ferrariAlcantara = 0x04
        case openWheel = 0x09
        case missing = 0x00
    }
}

// MARK: - Force Feedback Protocol

enum FFProtocol {
    /// HID Report ID for force feedback output
    static let reportID: UInt8 = 0x60

    /// Buffer sizes
    static let ps3BufferSize = 63
    static let ps4BufferSize = 31

    /// Maximum simultaneous effects
    static let maxEffects = 16

    /// Command codes (byte 2 of effect header)
    enum Command: UInt8 {
        case playStop = 0x89
        case constant = 0x6A
        case rampPeriodic = 0x6B
        case condition = 0x64
        case conditionUpdate = 0x4C
        case rampPeriodicUpdate = 0x6E
    }

    /// Constant update uses the same command code as constant upload (0x6A)
    static let constantUpdateCode: UInt8 = 0x6A

    /// Setup command codes (byte 0)
    enum SetupCommand: UInt8 {
        case openClose = 0x01
        case gain = 0x02
        case rangeAutocenter = 0x08
    }

    /// Open device command
    static let openCommand: [UInt8] = {
        var cmd = [UInt8](repeating: 0, count: ps3BufferSize)
        cmd[0] = SetupCommand.openClose.rawValue
        cmd[1] = 0x05
        return cmd
    }()

    /// Close device command
    static let closeCommand: [UInt8] = {
        var cmd = [UInt8](repeating: 0, count: ps3BufferSize)
        cmd[0] = SetupCommand.openClose.rawValue
        return cmd
    }()

    /// Play effect sub-commands
    enum PlaySubCommand: UInt8 {
        case stop = 0x00
        case playSingle = 0x01
        case playCount = 0x41
    }

    /// Condition effect types
    enum ConditionType: UInt8 {
        case spring = 0x06
        case damperFrictionInertia = 0x07
    }

    /// Periodic waveform types (kernel ff_waveform value - 0x57)
    enum Waveform: UInt8 {
        case square = 0x01
        case triangle = 0x02
        case sine = 0x03
        case sawtoothUp = 0x04
        case sawtoothDown = 0x05
    }

    /// Saturation limits
    static let springMaxSaturation: UInt16 = 0x6AA6
    static let otherMaxSaturation: UInt16 = 0x7FFC

    /// Timing markers
    static let timingStartMarker: UInt8 = 0x4F
    static let timingEndMarker: UInt16 = 0xFFFF

    /// Create a gain command
    static func gainCommand(gain: UInt16) -> [UInt8] {
        var cmd = [UInt8](repeating: 0, count: ps3BufferSize)
        cmd[0] = SetupCommand.gain.rawValue
        cmd[1] = UInt8(gain >> 8)
        return cmd
    }

    /// Create a range command
    /// - Parameter degrees: Wheel rotation range in degrees (40-1080)
    static func rangeCommand(degrees: UInt16) -> [UInt8] {
        let clamped = min(max(degrees, 40), 1080)
        let scaled = UInt16(clamped) * 0x3C
        var cmd = [UInt8](repeating: 0, count: ps3BufferSize)
        cmd[0] = SetupCommand.rangeAutocenter.rawValue
        cmd[1] = 0x11
        cmd[2] = UInt8(scaled & 0xFF)
        cmd[3] = UInt8(scaled >> 8)
        return cmd
    }

    /// Create an autocenter enable command
    static func autocenterEnable() -> [UInt8] {
        var cmd = [UInt8](repeating: 0, count: ps3BufferSize)
        cmd[0] = SetupCommand.rangeAutocenter.rawValue
        cmd[1] = 0x04
        cmd[2] = 0x01
        return cmd
    }

    /// Create an autocenter strength command
    static func autocenterStrength(value: UInt16) -> [UInt8] {
        var cmd = [UInt8](repeating: 0, count: ps3BufferSize)
        cmd[0] = SetupCommand.rangeAutocenter.rawValue
        cmd[1] = 0x03
        cmd[2] = UInt8(value & 0xFF)
        cmd[3] = UInt8(value >> 8)
        return cmd
    }
}

// MARK: - HID Report Format (Generic FFB Wheel, PID=0xB65D)

/// Report format for the generic/pre-mode-switch device
enum GenericReportFormat {
    static let reportSize = 27  // MaxInputReportSize from ioreg

    // Standard HID axes (from report descriptor)
    static let steeringOffset = 2    // X axis, 12-bit (after 13 button bits + 3 padding + 4 hat)
    static let yAxisOffset = 4       // Y axis, 8-bit
    static let zAxisOffset = 5       // Z axis, 8-bit
    static let rzAxisOffset = 6      // Rz axis, 8-bit

    // Vendor-specific 10-bit pedal values (from descriptor, 16-bit fields at end)
    static let vendorPedal1Offset = 19  // 10-bit, usage 0x2C
    static let vendorPedal2Offset = 21  // 10-bit, usage 0x2D
    static let vendorPedal3Offset = 23  // 10-bit, usage 0x2E
    static let vendorPedal4Offset = 25  // 10-bit, usage 0x2F
}

// MARK: - HID Report Format (T300RS Mode-Switched, PID=0xB66E)

/// Report format for the mode-switched T300RS PS3 normal mode
/// Based on the Linux driver's fixed HID report descriptor (t300rs_rdesc_nrm_fixed)
enum T300RSReportFormat {
    // Report ID 0x07 for PS3 mode
    static let reportID: UInt8 = 0x07

    // The actual byte layout in the input report (after report ID byte):
    // This needs to be verified empirically after mode switch
    // Based on Linux HID descriptor analysis:
    static let steeringLow = 0    // Steering axis low byte
    static let steeringHigh = 1   // Steering axis high byte (16-bit total, 0-65535)
    static let brakeLow = 2       // Brake pedal low byte
    static let brakeHigh = 3      // Brake pedal high byte (10-bit, 0-1023)
    static let gasLow = 4         // Gas pedal low byte
    static let gasHigh = 5        // Gas pedal high byte (10-bit, 0-1023)
    static let clutchLow = 6      // Clutch pedal low byte
    static let clutchHigh = 7     // Clutch pedal high byte (10-bit, 0-1023)
    static let buttonsLow = 8     // Buttons low byte (buttons 1-8)
    static let buttonsHigh = 9    // Buttons high byte (buttons 9-13 + hat in upper nibble)

    static let maxSteering: UInt16 = 65535
    static let maxPedal: UInt16 = 1023
}
