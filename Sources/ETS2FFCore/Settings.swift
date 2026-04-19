import Foundation

/// Shared between the daemon and the control app. The app sends these over the
/// control socket; the daemon persists the applied version to disk.
public struct FFSettings: Codable, Equatable, Sendable {
    // -- Wheel hardware --
    public var range: Int             // 40..1080
    public var gain: Int              // 0..65535 (Thrustmaster FF master gain)

    // -- Baseline static effects --
    public var spring: Int            // 0..100 (spring coefficient strength)
    public var damper: Int            // 0..100 (damper coefficient strength)

    // -- Live-mixer gains --
    /// Strength of self-centering force derived from telemetry (0..100).
    public var selfCenterGain: Int
    /// Engine rumble amplitude scale (0..100).
    public var engineRumble: Int
    /// Road-surface texture rumble scale (0..100).
    public var surfaceRumble: Int
    /// Suspension impact impulse scale (0..100).
    public var suspensionImpact: Int
    /// Collision impulse scale (0..100).
    public var collisionImpact: Int

    // -- Phase-3 live-mixer gains (v2) --
    /// ABS / wheel-lockup shiver amplitude (0..100).
    public var absShiver: Int
    /// Gearshift "thunk" impulse strength (0..100).
    public var gearshiftThunk: Int
    /// Trailer-sway corrective counter-force (0..100).
    public var trailerSway: Int
    /// Vertical-impact spike (big chassis hits, potholes) strength (0..100).
    public var verticalImpact: Int
    /// Heavy-parking-with-trailer effort multiplier (0..100).
    public var trailerParking: Int

    public init(range: Int = 1080,
                gain: Int = 42000,
                spring: Int = 70,
                damper: Int = 25,
                selfCenterGain: Int = 70,
                engineRumble: Int = 60,
                surfaceRumble: Int = 70,
                suspensionImpact: Int = 70,
                collisionImpact: Int = 80,
                absShiver: Int = 70,
                gearshiftThunk: Int = 60,
                trailerSway: Int = 70,
                verticalImpact: Int = 70,
                trailerParking: Int = 60) {
        self.range = range
        self.gain = gain
        self.spring = spring
        self.damper = damper
        self.selfCenterGain = selfCenterGain
        self.engineRumble = engineRumble
        self.surfaceRumble = surfaceRumble
        self.suspensionImpact = suspensionImpact
        self.collisionImpact = collisionImpact
        self.absShiver = absShiver
        self.gearshiftThunk = gearshiftThunk
        self.trailerSway = trailerSway
        self.verticalImpact = verticalImpact
        self.trailerParking = trailerParking
    }

    public static let `default` = FFSettings()

    // Backwards-compatible decoder — older settings.json files from before v2
    // don't carry the new knobs. Missing keys fall back to defaults so the UI
    // just shows sensible values.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FFSettings.default
        self.range            = try c.decodeIfPresent(Int.self, forKey: .range) ?? d.range
        self.gain             = try c.decodeIfPresent(Int.self, forKey: .gain) ?? d.gain
        self.spring           = try c.decodeIfPresent(Int.self, forKey: .spring) ?? d.spring
        self.damper           = try c.decodeIfPresent(Int.self, forKey: .damper) ?? d.damper
        self.selfCenterGain   = try c.decodeIfPresent(Int.self, forKey: .selfCenterGain) ?? d.selfCenterGain
        self.engineRumble     = try c.decodeIfPresent(Int.self, forKey: .engineRumble) ?? d.engineRumble
        self.surfaceRumble    = try c.decodeIfPresent(Int.self, forKey: .surfaceRumble) ?? d.surfaceRumble
        self.suspensionImpact = try c.decodeIfPresent(Int.self, forKey: .suspensionImpact) ?? d.suspensionImpact
        self.collisionImpact  = try c.decodeIfPresent(Int.self, forKey: .collisionImpact) ?? d.collisionImpact
        self.absShiver        = try c.decodeIfPresent(Int.self, forKey: .absShiver) ?? d.absShiver
        self.gearshiftThunk   = try c.decodeIfPresent(Int.self, forKey: .gearshiftThunk) ?? d.gearshiftThunk
        self.trailerSway      = try c.decodeIfPresent(Int.self, forKey: .trailerSway) ?? d.trailerSway
        self.verticalImpact   = try c.decodeIfPresent(Int.self, forKey: .verticalImpact) ?? d.verticalImpact
        self.trailerParking   = try c.decodeIfPresent(Int.self, forKey: .trailerParking) ?? d.trailerParking
    }

    private enum CodingKeys: String, CodingKey {
        case range, gain, spring, damper
        case selfCenterGain, engineRumble, surfaceRumble, suspensionImpact, collisionImpact
        case absShiver, gearshiftThunk, trailerSway, verticalImpact, trailerParking
    }
}

/// Control-socket message types.
public enum ControlMessage: Codable, Sendable {
    case apply(FFSettings)
    case query          // "send me your current state"
    case status(FFStatus)

    enum CodingKeys: String, CodingKey { case kind, payload }
    enum Kind: String, Codable { case apply, query, status }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .apply:  self = .apply(try c.decode(FFSettings.self, forKey: .payload))
        case .query:  self = .query
        case .status: self = .status(try c.decode(FFStatus.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .apply(let s):  try c.encode(Kind.apply, forKey: .kind); try c.encode(s, forKey: .payload)
        case .query:         try c.encode(Kind.query, forKey: .kind)
        case .status(let s): try c.encode(Kind.status, forKey: .kind); try c.encode(s, forKey: .payload)
        }
    }
}

public struct FFStatus: Codable, Equatable, Sendable {
    public var daemonVersion: String
    public var wheelConnected: Bool
    public var ets2Connected: Bool        // plugin alive
    public var ets2Live: Bool             // plugin alive AND not paused AND in-game
    public var currentSettings: FFSettings
    public var speedKmh: Int
    public var rpm: Int
    public var gear: Int

    public init(daemonVersion: String = "1.0",
                wheelConnected: Bool = false,
                ets2Connected: Bool = false,
                ets2Live: Bool = false,
                currentSettings: FFSettings = .default,
                speedKmh: Int = 0,
                rpm: Int = 0,
                gear: Int = 0) {
        self.daemonVersion = daemonVersion
        self.wheelConnected = wheelConnected
        self.ets2Connected = ets2Connected
        self.ets2Live = ets2Live
        self.currentSettings = currentSettings
        self.speedKmh = speedKmh
        self.rpm = rpm
        self.gear = gear
    }
}

public enum ControlPaths {
    /// Unix socket used by daemon↔app. /tmp works without any entitlement dance
    /// and is cleaned up across reboots.
    public static let socketPath = "/tmp/ets2_ff_ctrl.sock"

    /// Persisted settings lives in the daemon user's home (daemon runs as root
    /// when launched with sudo — so we use the SUDO_USER's home if set).
    public static func settingsFileURL() -> URL {
        let fm = FileManager.default
        var home: URL
        if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"] {
            home = URL(fileURLWithPath: "/Users/\(sudoUser)")
        } else {
            home = fm.homeDirectoryForCurrentUser
        }
        let dir = home
            .appendingPathComponent("Library/Application Support/ThrustmasterWheel",
                                    isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }
}

public enum SettingsStore {
    public static func load() -> FFSettings {
        let url = ControlPaths.settingsFileURL()
        guard let data = try? Data(contentsOf: url) else { return .default }
        return (try? JSONDecoder().decode(FFSettings.self, from: data)) ?? .default
    }

    public static func save(_ settings: FFSettings) {
        let url = ControlPaths.settingsFileURL()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(settings) else { return }
        try? data.write(to: url, options: .atomic)

        // If daemon (root) wrote it, make sure SUDO_USER can read/write it back.
        if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"] {
            let task = Process()
            task.launchPath = "/usr/sbin/chown"
            task.arguments = ["\(sudoUser):staff", url.path]
            try? task.run()
            task.waitUntilExit()
        }
    }
}
