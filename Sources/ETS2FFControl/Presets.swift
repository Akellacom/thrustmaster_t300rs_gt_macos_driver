import Foundation
import ETS2FFCore

/// Named tuning profiles. "Custom" is the sentinel for any settings that don't
/// match a concrete preset — selected automatically the moment the user drags
/// any slider off a preset's values.
enum FFPreset: String, CaseIterable, Identifiable {
    case custom     = "Custom"
    case realistic  = "Realistic Truck"
    case arcade     = "Light Arcade"
    case heavyRig   = "Heavy Rig"
    case quiet      = "Quiet Night"

    var id: String { rawValue }

    /// Icon name (SF Symbols) for display in the picker.
    var symbolName: String {
        switch self {
        case .custom:    return "slider.horizontal.3"
        case .realistic: return "truck.box.fill"
        case .arcade:    return "gamecontroller.fill"
        case .heavyRig:  return "dumbbell.fill"
        case .quiet:     return "moon.fill"
        }
    }

    /// Concrete settings for this preset. `nil` for .custom.
    var settings: FFSettings? {
        switch self {
        case .custom:
            return nil
        case .realistic:
            return FFSettings(range: 1080, gain: 42000,
                              spring: 70, damper: 25,
                              selfCenterGain: 70, engineRumble: 60,
                              surfaceRumble: 70, suspensionImpact: 70,
                              collisionImpact: 80,
                              absShiver: 70, gearshiftThunk: 60,
                              trailerSway: 70, verticalImpact: 70,
                              trailerParking: 60)
        case .arcade:
            return FFSettings(range: 540, gain: 35000,
                              spring: 50, damper: 15,
                              selfCenterGain: 40, engineRumble: 80,
                              surfaceRumble: 60, suspensionImpact: 50,
                              collisionImpact: 60,
                              absShiver: 90, gearshiftThunk: 70,
                              trailerSway: 40, verticalImpact: 80,
                              trailerParking: 20)
        case .heavyRig:
            return FFSettings(range: 1080, gain: 55000,
                              spring: 80, damper: 40,
                              selfCenterGain: 90, engineRumble: 50,
                              surfaceRumble: 80, suspensionImpact: 80,
                              collisionImpact: 90,
                              absShiver: 80, gearshiftThunk: 80,
                              trailerSway: 90, verticalImpact: 90,
                              trailerParking: 90)
        case .quiet:
            return FFSettings(range: 900, gain: 25000,
                              spring: 60, damper: 20,
                              selfCenterGain: 50, engineRumble: 20,
                              surfaceRumble: 30, suspensionImpact: 30,
                              collisionImpact: 40,
                              absShiver: 40, gearshiftThunk: 30,
                              trailerSway: 50, verticalImpact: 40,
                              trailerParking: 40)
        }
    }

    /// Short description shown as a tooltip / subtitle.
    var tagline: String {
        switch self {
        case .custom:    return "Your own tuning"
        case .realistic: return "1080° truck, full telemetry mix"
        case .arcade:    return "540°, responsive, light feel"
        case .heavyRig:  return "1080°, strong FF for rigid stands"
        case .quiet:     return "Gentle FF for desk mounts / night"
        }
    }

    /// Detect which preset (if any) matches the given settings. Returns
    /// `.custom` when nothing matches — so the UI can show "Custom" the moment
    /// the user nudges a slider.
    static func detect(from settings: FFSettings) -> FFPreset {
        for preset in FFPreset.allCases {
            if let s = preset.settings, s == settings {
                return preset
            }
        }
        return .custom
    }
}
