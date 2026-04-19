import Foundation
import IOKit.hid
import CUSBModeSwitch

/// Creates a virtual HID joystick device that games can see
final class VirtualHIDDevice {

    typealias OutputReportCallback = (_ reportType: IOHIDReportType, _ reportID: UInt32, _ data: [UInt8]) -> Void

    /// Identity presented to macOS (VID/PID/name).
    struct Identity {
        var vendorID: UInt16
        var productID: UInt16
        var version: UInt16
        var manufacturer: String?
        var productName: String

        static let t300rs = Identity(
            vendorID: 0,                // 0 = not set
            productID: 0,
            version: 0,
            manufacturer: nil,
            productName: "Thrustmaster T300RS Wheel"
        )
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case creationFailed
        case reportFailed(Int32)

        var description: String {
            switch self {
            case .creationFailed: return "Failed to create virtual HID device"
            case .reportFailed(let ret): return "Failed to send report: \(String(format: "0x%08X", ret))"
            }
        }
    }

    /// Which HID report descriptor style to use.
    /// - `.joystick` — Generic Desktop / Joystick (X/Y/Z/Rz). Default.
    /// - `.wheel` — Simulation Controls (Steering/Brake/Accelerator/Clutch).
    /// - `.xboxGamepad` — Generic Desktop / Gamepad with axis usage codes chosen
    ///   so macOS GameController.framework maps them cleanly onto the standard
    ///   Xbox controller profile: wheel→LeftStick.x, brake→LT, gas→RT, clutch→RS.x.
    ///   Designed for cloud gaming (GeForce Now) where the server expects an
    ///   Xbox gamepad and the game (ETS2) wants wheel-as-LS + pedals-as-triggers.
    ///
    /// Byte layout of input reports is IDENTICAL across all three styles —
    /// only the semantic usage codes change. No translator changes needed.
    enum DescriptorStyle {
        case joystick
        case wheel
        case xboxGamepad
    }

    /// HID Report Descriptor — generic joystick (Usage=Joystick, X/Y/Z/Rz axes)
    static let reportDescriptor: [UInt8] = [
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x04,       // Usage (Joystick)
        0xA1, 0x01,       // Collection (Application)

        // Steering wheel axis - 16-bit
        0x09, 0x30,       //   Usage (X)
        0x15, 0x00,       //   Logical Minimum (0)
        0x27, 0xFF, 0xFF, 0x00, 0x00, // Logical Maximum (65535)
        0x75, 0x10,       //   Report Size (16)
        0x95, 0x01,       //   Report Count (1)
        0x81, 0x02,       //   Input (Data, Variable, Absolute)

        // Pedal axes (16-bit fields, values 0-1023)
        0x09, 0x31,       //   Usage (Y) - Brake
        0x09, 0x32,       //   Usage (Z) - Throttle
        0x09, 0x35,       //   Usage (Rz) - Clutch
        0x26, 0xFF, 0x03, //   Logical Maximum (1023)
        0x75, 0x10,       //   Report Size (16)
        0x95, 0x03,       //   Report Count (3)
        0x81, 0x02,       //   Input (Data, Variable, Absolute)

        // Hat switch
        0x09, 0x39,       //   Usage (Hat Switch)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x07,       //   Logical Maximum (7)
        0x35, 0x00,       //   Physical Minimum (0)
        0x46, 0x3B, 0x01, //   Physical Maximum (315)
        0x65, 0x14,       //   Unit (Degrees)
        0x75, 0x04,       //   Report Size (4)
        0x95, 0x01,       //   Report Count (1)
        0x81, 0x42,       //   Input (Data, Var, Abs, Null State)

        // Padding (4 bits)
        0x75, 0x04,       //   Report Size (4)
        0x95, 0x01,       //   Report Count (1)
        0x81, 0x01,       //   Input (Constant)

        // 13 Buttons
        0x05, 0x09,       //   Usage Page (Button)
        0x19, 0x01,       //   Usage Minimum (1)
        0x29, 0x0D,       //   Usage Maximum (13)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x01,       //   Logical Maximum (1)
        0x35, 0x00,       //   Physical Minimum (0)
        0x45, 0x01,       //   Physical Maximum (1)
        0x65, 0x00,       //   Unit (None)
        0x75, 0x01,       //   Report Size (1)
        0x95, 0x0D,       //   Report Count (13)
        0x81, 0x02,       //   Input (Data, Variable, Absolute)

        // Button padding (3 bits)
        0x75, 0x03,       //   Report Size (3)
        0x95, 0x01,       //   Report Count (1)
        0x81, 0x01,       //   Input (Constant)

        0xC0,             // End Collection
    ]

    /// HID Report Descriptor — racing wheel via Simulation Controls usage page (0x02).
    /// Byte layout of input reports is identical to `reportDescriptor` — only
    /// the semantic usages differ (Steering/Brake/Accelerator/Clutch instead
    /// of X/Y/Z/Rz). This is how real Logitech/Thrustmaster wheels advertise
    /// themselves in their HID descriptors; it's the standard HID-spec way
    /// to signal "this is a wheel, not a joystick" independent of VID/PID.
    static let reportDescriptorWheel: [UInt8] = [
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x04,       // Usage (Joystick)
        0xA1, 0x01,       // Collection (Application)

        // --- Switch to Simulation Controls usage page for axes ---
        0x05, 0x02,       //   Usage Page (Simulation Controls)

        // Steering wheel - 16-bit unsigned, Usage(Steering) 0xC8
        0x09, 0xC8,       //   Usage (Steering)
        0x15, 0x00,       //   Logical Minimum (0)
        0x27, 0xFF, 0xFF, 0x00, 0x00, // Logical Maximum (65535)
        0x75, 0x10,       //   Report Size (16)
        0x95, 0x01,       //   Report Count (1)
        0x81, 0x02,       //   Input (Data, Variable, Absolute)

        // Pedals: Brake, Accelerator, Clutch — 16-bit fields, 0-1023
        // Order matches the input report byte layout: [brake][gas][clutch]
        0x09, 0xC5,       //   Usage (Brake)
        0x09, 0xC4,       //   Usage (Accelerator)
        0x09, 0xC6,       //   Usage (Clutch)
        0x26, 0xFF, 0x03, //   Logical Maximum (1023)
        0x75, 0x10,       //   Report Size (16)
        0x95, 0x03,       //   Report Count (3)
        0x81, 0x02,       //   Input (Data, Variable, Absolute)

        // --- Back to Generic Desktop for hat ---
        0x05, 0x01,       //   Usage Page (Generic Desktop)
        0x09, 0x39,       //   Usage (Hat Switch)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x07,       //   Logical Maximum (7)
        0x35, 0x00,       //   Physical Minimum (0)
        0x46, 0x3B, 0x01, //   Physical Maximum (315)
        0x65, 0x14,       //   Unit (Degrees)
        0x75, 0x04,       //   Report Size (4)
        0x95, 0x01,       //   Report Count (1)
        0x81, 0x42,       //   Input (Data, Var, Abs, Null State)

        // Padding (4 bits)
        0x75, 0x04,       //   Report Size (4)
        0x95, 0x01,       //   Report Count (1)
        0x81, 0x01,       //   Input (Constant)

        // 13 Buttons
        0x05, 0x09,       //   Usage Page (Button)
        0x19, 0x01,       //   Usage Minimum (1)
        0x29, 0x0D,       //   Usage Maximum (13)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x01,       //   Logical Maximum (1)
        0x35, 0x00,       //   Physical Minimum (0)
        0x45, 0x01,       //   Physical Maximum (1)
        0x65, 0x00,       //   Unit (None)
        0x75, 0x01,       //   Report Size (1)
        0x95, 0x0D,       //   Report Count (13)
        0x81, 0x02,       //   Input (Data, Variable, Absolute)

        // Button padding (3 bits)
        0x75, 0x03,       //   Report Size (3)
        0x95, 0x01,       //   Report Count (1)
        0x81, 0x01,       //   Input (Constant)

        0xC0,             // End Collection
    ]

    /// HID Report Descriptor — Xbox-style Gamepad with axes chosen to match
    /// macOS GameController.framework's Xbox controller profile:
    ///   X   → LeftStick.x    (steering)
    ///   Z   → LeftTrigger    (brake)
    ///   Rz  → RightTrigger   (gas/accelerator)
    ///   Rx  → RightStick.x   (clutch — unusual mapping, but unused by most games)
    ///
    /// Top-level Usage is Gamepad (0x05) instead of Joystick (0x04) so that
    /// GameController.framework applies the Extended Gamepad / Xbox Controller
    /// mapping rather than the generic joystick one. This is what GFN needs
    /// on the server side — games expect an Xbox gamepad layout there.
    ///
    /// Byte layout of input reports is unchanged from the joystick descriptor:
    ///   [0-1] steering, [2-3] brake, [4-5] gas, [6-7] clutch,
    ///   [8] hat+padding, [9-10] buttons.
    static let reportDescriptorXbox: [UInt8] = [
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x05,       // Usage (Gamepad)
        0xA1, 0x01,       // Collection (Application)

        // Steering → X axis → LeftStick.x (16-bit unsigned 0-65535)
        0x09, 0x30,       //   Usage (X)
        0x15, 0x00,       //   Logical Minimum (0)
        0x27, 0xFF, 0xFF, 0x00, 0x00, // Logical Maximum (65535)
        0x75, 0x10,       //   Report Size (16)
        0x95, 0x01,       //   Report Count (1)
        0x81, 0x02,       //   Input (Data, Variable, Absolute)

        // Brake → Z axis → LeftTrigger
        // Gas   → Rz axis → RightTrigger
        // Clutch → Rx axis → RightStick.x
        //
        // Byte order in report: [brake][gas][clutch] — must match byte layout.
        // Usage declaration order here: Z, Rz, Rx (matches byte positions 2-3, 4-5, 6-7).
        0x09, 0x32,       //   Usage (Z)   → brake
        0x09, 0x35,       //   Usage (Rz)  → gas
        0x09, 0x33,       //   Usage (Rx)  → clutch
        0x26, 0xFF, 0x03, //   Logical Maximum (1023)
        0x75, 0x10,       //   Report Size (16)
        0x95, 0x03,       //   Report Count (3)
        0x81, 0x02,       //   Input (Data, Variable, Absolute)

        // Hat switch → D-pad
        0x09, 0x39,       //   Usage (Hat Switch)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x07,       //   Logical Maximum (7)
        0x35, 0x00,       //   Physical Minimum (0)
        0x46, 0x3B, 0x01, //   Physical Maximum (315)
        0x65, 0x14,       //   Unit (Degrees)
        0x75, 0x04,       //   Report Size (4)
        0x95, 0x01,       //   Report Count (1)
        0x81, 0x42,       //   Input (Data, Var, Abs, Null State)

        // Padding (4 bits)
        0x75, 0x04,       //   Report Size (4)
        0x95, 0x01,       //   Report Count (1)
        0x81, 0x01,       //   Input (Constant)

        // 13 Buttons → A, B, X, Y, LB, RB, Back, Start, Xbox, LS, RS, + 2 extras
        0x05, 0x09,       //   Usage Page (Button)
        0x19, 0x01,       //   Usage Minimum (1)
        0x29, 0x0D,       //   Usage Maximum (13)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x01,       //   Logical Maximum (1)
        0x35, 0x00,       //   Physical Minimum (0)
        0x45, 0x01,       //   Physical Maximum (1)
        0x65, 0x00,       //   Unit (None)
        0x75, 0x01,       //   Report Size (1)
        0x95, 0x0D,       //   Report Count (13)
        0x81, 0x02,       //   Input (Data, Variable, Absolute)

        // Button padding (3 bits)
        0x75, 0x03,       //   Report Size (3)
        0x95, 0x01,       //   Report Count (1)
        0x81, 0x01,       //   Input (Constant)

        0xC0,             // End Collection
    ]

    /// Input report size: 2 (steer) + 6 (3 pedals x 2) + 1 (hat+pad) + 2 (13 btns + 3 pad) = 11 bytes
    /// Same for all descriptor styles — only usage semantics differ.
    static let inputReportSize = 11

    private var handle: VirtualDeviceHandle?
    var onOutputReport: OutputReportCallback?

    deinit {
        destroy()
    }

    func create(identity: Identity = .t300rs, style: DescriptorStyle = .joystick) throws {
        let desc: [UInt8]
        switch style {
        case .joystick:    desc = Self.reportDescriptor
        case .wheel:       desc = Self.reportDescriptorWheel
        case .xboxGamepad: desc = Self.reportDescriptorXbox
        }
        handle = desc.withUnsafeBufferPointer { buf in
            identity.productName.withCString { productC in
                if let manufacturer = identity.manufacturer {
                    return manufacturer.withCString { mfgC in
                        virtual_device_create_ex(
                            buf.baseAddress, buf.count,
                            identity.vendorID, identity.productID, identity.version,
                            mfgC, productC
                        )
                    }
                } else {
                    return virtual_device_create_ex(
                        buf.baseAddress, buf.count,
                        identity.vendorID, identity.productID, identity.version,
                        nil, productC
                    )
                }
            }
        }

        guard handle != nil else {
            throw Error.creationFailed
        }

        // Schedule on current run loop
        virtual_device_schedule(handle, CFRunLoopGetCurrent())

        let vidStr = identity.vendorID == 0 ? "—" : String(format: "%04X", identity.vendorID)
        let pidStr = identity.productID == 0 ? "—" : String(format: "%04X", identity.productID)
        let styleStr: String
        switch style {
        case .joystick:    styleStr = "joystick"
        case .wheel:       styleStr = "wheel"
        case .xboxGamepad: styleStr = "xbox-gamepad"
        }
        _ = (vidStr, pidStr, styleStr)  // kept for future verbose logging
    }

    func sendInputReport(_ report: [UInt8]) throws {
        guard let h = handle else { return }

        let result = report.withUnsafeBufferPointer { buf in
            virtual_device_send_report(h, buf.baseAddress, buf.count)
        }

        if result != 0 {
            throw Error.reportFailed(Int32(result))
        }
    }

    func destroy() {
        if let h = handle {
            virtual_device_destroy(h)
            handle = nil
        }
    }
}
