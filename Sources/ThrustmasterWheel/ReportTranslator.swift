import Foundation

/// Translates HID reports between the real T300RS device and the virtual joystick device.
///
/// The T300RS in different modes sends different report formats. This translator
/// handles both the generic FFB Wheel format (PID=0xB65D) and the mode-switched
/// T300RS format (PID=0xB66E).
final class ReportTranslator {

    /// Current wheel state extracted from HID reports
    struct WheelState {
        var steering: UInt16 = 0      // 0-65535 (16-bit) or 0-4095 (12-bit generic)
        var brake: UInt16 = 0         // 0-1023 (10-bit)
        var gas: UInt16 = 0           // 0-1023 (10-bit)
        var clutch: UInt16 = 0        // 0-1023 (10-bit)
        var buttons: UInt16 = 0       // 13 buttons bit-packed
        var hatSwitch: UInt8 = 0x0F   // 0-7 directions, 0x0F = centered/null
    }

    enum DeviceMode {
        case genericFFBWheel  // PID=0xB65D, before mode switch
        case t300rsNormal     // PID=0xB66E, PS3 normal mode (Report ID 0x07)
        case t300rsPS4        // PID=0xB66D, PS4 mode (Report ID 0x01)
    }

    var mode: DeviceMode = .genericFFBWheel
    private(set) var state = WheelState()
    var debugMode = false

    // Track previous state for change detection
    private var previousReport = [UInt8]()

    /// Process an incoming raw HID report and update the wheel state
    func processReport(_ report: UnsafeBufferPointer<UInt8>, reportID: UInt32) {
        let bytes = Array(report)
        reportCount += 1

        if debugMode {
            printReportDiff(bytes, reportID: reportID)
        }

        switch mode {
        case .genericFFBWheel:
            processGenericReport(bytes)
        case .t300rsNormal:
            processT300RSNormalReport(bytes, reportID: reportID)
        case .t300rsPS4:
            processT300RSPS4Report(bytes, reportID: reportID)
        }
    }

    /// Build an input report for the virtual joystick device from current state
    func buildVirtualReport() -> [UInt8] {
        var report = [UInt8](repeating: 0, count: VirtualHIDDevice.inputReportSize)

        // Steering (bytes 0-1, uint16 LE)
        report[0] = UInt8(state.steering & 0xFF)
        report[1] = UInt8(state.steering >> 8)

        // Brake (bytes 2-3, uint16 LE)
        report[2] = UInt8(state.brake & 0xFF)
        report[3] = UInt8(state.brake >> 8)

        // Gas (bytes 4-5, uint16 LE)
        report[4] = UInt8(state.gas & 0xFF)
        report[5] = UInt8(state.gas >> 8)

        // Clutch (bytes 6-7, uint16 LE)
        report[6] = UInt8(state.clutch & 0xFF)
        report[7] = UInt8(state.clutch >> 8)

        // Hat switch (byte 8, lower nibble) + padding (upper nibble)
        report[8] = state.hatSwitch & 0x0F

        // Buttons (bytes 9-10, 13 bits)
        report[9] = UInt8(state.buttons & 0xFF)
        report[10] = UInt8((state.buttons >> 8) & 0x1F)  // Upper 5 bits of 13

        return report
    }

    // MARK: - Generic FFB Wheel Report Processing (PID=0xB65D)

    /// Process the generic FFB Wheel report format (27 bytes, no report ID)
    ///
    /// Bit layout (verified via ioreg HID descriptor + debug output):
    /// - 13 buttons (1 bit each) + 3 padding = 2 bytes       [0-1]
    /// - Hat switch (4 bits) + X axis / steering (12 bits)    [2-3]
    /// - Y axis (8 bits)                                       [4]
    /// - Z axis (8 bits)                                       [5]
    /// - Rz axis (8 bits)                                      [6]
    /// - 12 vendor 8-bit values (Usage 0x20-0x2B, page 0xFF00) [7-18]
    ///     -> byte 17 = brake pedal (8-bit, 0-255)    (verified by debug)
    ///     -> byte 18 = gas pedal (8-bit, 0-255)      (verified by debug)
    /// - 4 vendor 16-bit values (Usage 0x2C-0x2F, 0-1023)    [19-26]
    ///
    /// Total: 2 + 2 + 3 + 12 + 8 = 27 bytes
    private func processGenericReport(_ bytes: [UInt8]) {
        guard bytes.count >= 19 else { return }

        // Bytes 0-1: 13 buttons + 3 padding
        let buttonBits = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        state.buttons = buttonBits & 0x1FFF  // Lower 13 bits

        // Byte 2 lower nibble: hat switch (4 bits)
        state.hatSwitch = bytes[2] & 0x0F

        // Bytes 2-3: hat (4 bits) + X axis (12 bits)
        // The X axis starts at bit 4 of byte 2 and extends through byte 3
        let xRaw = (UInt16(bytes[2]) >> 4) | (UInt16(bytes[3]) << 4)
        // Scale 12-bit (0-4095) to 16-bit (0-65535)
        state.steering = xRaw * 16  // 4095 * 16 = 65520 ≈ 65535

        // Byte 17: brake pedal (8-bit, 0-255) - confirmed by debug output
        // Byte 18: gas/throttle pedal (8-bit, 0-255) - confirmed by debug output
        // Scale 8-bit (0-255) to 10-bit range (0-1023) for our virtual device
        state.brake = UInt16(bytes[17]) * 4    // 255 * 4 = 1020 ≈ 1023
        state.gas = UInt16(bytes[18]) * 4

        // No clutch in generic mode (T300RS GT has 2-pedal set by default)
        state.clutch = 0

        // Also check the 16-bit vendor fields for potentially higher-res pedal data
        if bytes.count >= 27 {
            let vendor16_0 = UInt16(bytes[19]) | (UInt16(bytes[20]) << 8)
            let vendor16_1 = UInt16(bytes[21]) | (UInt16(bytes[22]) << 8)
            let vendor16_2 = UInt16(bytes[23]) | (UInt16(bytes[24]) << 8)
            let vendor16_3 = UInt16(bytes[25]) | (UInt16(bytes[26]) << 8)

            // Log these once for analysis (to see if they contain useful data)
            if debugMode && reportCount == 0 {
                print("[Report] Vendor 16-bit fields: \(vendor16_0) \(vendor16_1) \(vendor16_2) \(vendor16_3)")
            }
        }
    }

    /// Report counter for debug purposes
    private var reportCount: UInt64 = 0

    // MARK: - T300RS Normal Mode Report Processing (PID=0xB66E)

    /// Process the T300RS mode-switched PS3 normal mode report
    ///
    /// From actual HID descriptor (Report ID 0x07):
    ///   Usage(X)      = Steering, 16-bit (0-65535)
    ///   Usage(Y)      = Brake, 10-bit (0-1023) — INVERTED (1023=released, 0=pressed)
    ///   Usage(Rz)     = Gas, 10-bit — INVERTED
    ///   Usage(Slider) = Clutch, 10-bit — INVERTED
    ///   1 byte constant padding
    ///   13 buttons (13 bits)
    ///   11 bits padding
    ///   Hat switch (4 bits)
    ///   4 bits padding
    ///
    /// Verified byte layout:
    /// - Bytes 0-1: Steering (uint16 LE, 0-65535)
    /// - Bytes 2-3: Brake Y axis (uint16 LE, 10-bit range, inverted)
    /// - Bytes 4-5: Gas Rz axis (uint16 LE, 10-bit range, inverted)
    /// - Bytes 6-7: Clutch Slider (uint16 LE, 10-bit range, inverted)
    /// - Bytes 8-9: padding byte + constant
    /// - Debug confirmed: byte 3=brake, byte 5=gas, byte 7=clutch (high bytes change)
    private func processT300RSNormalReport(_ bytes: [UInt8], reportID: UInt32) {
        guard bytes.count >= 8 else { return }

        // Steering: bytes 0-1, uint16 LE (0-65535)
        state.steering = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)

        // Pedals: uint16 LE, 10-bit range, INVERTED (1023=released, 0=pressed)
        let brakeRaw = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        let gasRaw = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
        let clutchRaw = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)

        // Invert: 0 = released, 1023 = fully pressed
        state.brake = min(1023, 1023 &- min(brakeRaw, 1023))
        state.gas = min(1023, 1023 &- min(gasRaw, 1023))
        state.clutch = min(1023, 1023 &- min(clutchRaw, 1023))

        // After 8 bytes of axes + 2 bytes padding/constant = buttons at byte 10
        // Descriptor: 13 buttons + 11 padding + 4 hat + 4 padding
        if bytes.count >= 12 {
            state.buttons = UInt16(bytes[10]) | (UInt16(bytes[11]) << 8)
            state.buttons &= 0x1FFF
        }
        if bytes.count >= 14 {
            state.hatSwitch = bytes[13] & 0x0F
        }
    }

    // MARK: - T300RS PS4 Mode Report Processing (PID=0xB66D)

    private func processT300RSPS4Report(_ bytes: [UInt8], reportID: UInt32) {
        // PS4 mode report format (Report ID 0x01):
        // Based on Linux driver's t300rs_rdesc_ps4_fixed
        guard bytes.count >= 28 else { return }

        // Bytes 0-3: 4x 8-bit axes (standard gamepad mapping)
        // Byte 4: hat switch (lower nibble)
        state.hatSwitch = bytes[4] & 0x0F

        // Bytes 5-6: buttons (14 buttons)
        state.buttons = UInt16(bytes[5]) | (UInt16(bytes[6]) << 8)
        state.buttons &= 0x1FFF  // We only support 13

        // Bytes 20-21: Steering (16-bit)
        state.steering = UInt16(bytes[20]) | (UInt16(bytes[21]) << 8)

        // Bytes 22-23: Gas (16-bit)
        state.gas = UInt16(bytes[22]) | (UInt16(bytes[23]) << 8)

        // Bytes 24-25: Brake (16-bit)
        state.brake = UInt16(bytes[24]) | (UInt16(bytes[25]) << 8)

        // Bytes 26-27: Clutch (16-bit)
        state.clutch = UInt16(bytes[26]) | (UInt16(bytes[27]) << 8)
    }

    // MARK: - Debug

    private func printReportDiff(_ bytes: [UInt8], reportID: UInt32) {
        if previousReport.isEmpty || previousReport.count != bytes.count {
            print("[Report] ID=\(reportID) len=\(bytes.count): ", terminator: "")
            for b in bytes { print(String(format: "%02X ", b), terminator: "") }
            print()
            previousReport = bytes
            return
        }

        var changed = false
        for i in 0..<bytes.count where bytes[i] != previousReport[i] {
            if !changed {
                print("[Report] Changes: ", terminator: "")
                changed = true
            }
            print("[\(i)]=\(String(format: "%02X", previousReport[i]))->\(String(format: "%02X", bytes[i])) ", terminator: "")
        }
        if changed { print() }
        previousReport = bytes
    }

    /// Print current wheel state in human-readable format
    func printState() {
        let steerPercent = Double(state.steering) / 65535.0 * 100.0
        let brakePercent = Double(state.brake) / 1023.0 * 100.0
        let gasPercent = Double(state.gas) / 1023.0 * 100.0
        let clutchPercent = Double(state.clutch) / 1023.0 * 100.0

        print(String(format: "\rSteer: %5.1f%%  Brake: %5.1f%%  Gas: %5.1f%%  Clutch: %5.1f%%  Btns: %04X  Hat: %X",
                      steerPercent, brakePercent, gasPercent, clutchPercent, state.buttons, state.hatSwitch),
              terminator: "")
        fflush(stdout)
    }
}
