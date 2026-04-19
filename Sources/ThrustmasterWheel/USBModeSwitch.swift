import Foundation
import CUSBModeSwitch

/// Handles USB mode switching for Thrustmaster wheels.
/// Uses C implementation for direct access to IOKit USB macros.
final class USBModeSwitch {

    enum Error: Swift.Error, CustomStringConvertible {
        case deviceNotFound
        case pluginFailed
        case interfaceFailed
        case openFailed
        case transferFailed
        case unknown(Int32)

        var description: String {
            switch self {
            case .deviceNotFound: return "Thrustmaster FFB Wheel not found"
            case .pluginFailed: return "Failed to create USB plugin"
            case .interfaceFailed: return "Failed to get USB device interface"
            case .openFailed: return "Failed to open USB device"
            case .transferFailed: return "USB control transfer failed"
            case .unknown(let code): return "Mode switch failed with code \(code)"
            }
        }
    }

    /// Check if a mode-switched T300RS device is present
    func isModeSwitchedDevicePresent() -> Bool {
        for pid in ThrustmasterUSB.modeSwitchedIDs {
            if thrustmaster_device_present(ThrustmasterUSB.vendorID, pid) != 0 {
                return true
            }
        }
        return false
    }

    /// Perform the full mode switch sequence via C implementation
    func performModeSwitch() throws {
        let result = thrustmaster_mode_switch(
            ThrustmasterUSB.vendorID,
            ThrustmasterUSB.genericFFBWheel,
            USBControlTransfer.switchToT300RS
        )

        switch result {
        case 0:
            break  // success — main.swift prints the status line
        case -1: throw Error.deviceNotFound
        case -2: throw Error.pluginFailed
        case -3: throw Error.interfaceFailed
        case -4: throw Error.openFailed
        case -5: throw Error.transferFailed
        case -6: throw Error.transferFailed
        default: throw Error.unknown(result)
        }
    }
}
