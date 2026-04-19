import Foundation
import Darwin
import CUSBModeSwitch

/// Reads the ETS2 SCS plugin's live telemetry from POSIX shared memory.
///
/// The plugin (ff_telemetry.so) writes a single `ets2_ff_state` struct and
/// updates a seqlock each game frame. We mmap it read-only here.
final class TelemetryReader {

    /// Must match the C layout defined in ets2_plugin/ets2_ff_shm.h.
    struct State {
        var renderTsUs: UInt64 = 0
        var simTsUs: UInt64 = 0

        var pluginAlive: Bool = false
        var paused: Bool = false
        var connected: Bool = false

        var speed: Float = 0                // m/s
        var engineRPM: Float = 0
        var engineGear: Int32 = 0
        var effectiveSteering: Float = 0    // -1..+1
        var inputSteering: Float = 0

        var accelX: Float = 0               // lateral m/s^2
        var accelY: Float = 0               // vertical
        var accelZ: Float = 0               // longitudinal

        var wheelCount: UInt32 = 0
        var wheelOnGround: [Bool] = Array(repeating: false, count: 8)
        var wheelSurface: [UInt8] = Array(repeating: 0, count: 8)
        var wheelSusp: [Float] = Array(repeating: 0, count: 8)
        var wheelAngVel: [Float] = Array(repeating: 0, count: 8)

        var collisionCount: UInt32 = 0
        var gearshiftCount: UInt32 = 0

        // v2 additions
        var trailerConnected: Bool = false
        var yawRate: Float = 0              // rad/s around truck up-axis (positive = left turn)
    }

    enum SurfaceCategory: UInt8 {
        case unknown = 0
        case smooth = 1
        case coarse = 2
        case dirt = 3
        case grass = 4
        case slippery = 5
        case rumble = 6
    }

    private static let shmName = "/ets2_ff_v1"
    private static let expectedMagic: UInt32 = 0x46464632 // 'FFE2'
    private static let expectedVersion: UInt32 = 2

    // Real struct is 184 bytes (verified by static_assert in ets2_ff_shm.h).
    // Map a bit extra for safety.
    private static let shmSize = 256

    private var fd: Int32 = -1
    private var mapping: UnsafeMutableRawPointer?

    // Parsed snapshot (updated by poll())
    private(set) var state = State()
    private(set) var isConnected: Bool = false

    /// Open and mmap the shm segment. Returns true if the plugin's shm exists.
    func open() -> Bool {
        fd = ets2_shm_open_ro(Self.shmName)
        if fd < 0 {
            return false
        }
        let ptr = mmap(nil, Self.shmSize, PROT_READ, MAP_SHARED, fd, 0)
        if ptr == MAP_FAILED {
            Darwin.close(fd); fd = -1
            return false
        }
        mapping = ptr

        // Validate header (magic at offset 24, version at 28 in the new layout).
        let magic = mapping!.load(fromByteOffset: 24, as: UInt32.self)
        let version = mapping!.load(fromByteOffset: 28, as: UInt32.self)
        if magic != Self.expectedMagic || version != Self.expectedVersion {
            // Fatal mismatch — plugin version out of sync with daemon.
            // Always surface this so user sees a rebuild is needed.
            print(String(format: "ETS2 plugin version mismatch (magic=0x%08X, ver=%u) — rebuild and reinstall ff_telemetry.so", magic, version))
            close()
            return false
        }
        return true
    }

    func close() {
        if let m = mapping {
            munmap(m, Self.shmSize)
            mapping = nil
        }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    /// Read the current shm snapshot under seqlock. Populates `state`.
    /// Returns true on a clean read, false on retry exhaustion.
    @discardableResult
    func poll() -> Bool {
        guard let base = mapping else { return false }

        for _ in 0..<8 {
            let s1 = base.load(fromByteOffset: 0, as: UInt64.self)
            if s1 & 1 != 0 { continue } // writer in progress
            readBody(base: base)
            let s2 = base.load(fromByteOffset: 0, as: UInt64.self)
            if s1 == s2 {
                isConnected = state.connected && !state.paused && state.pluginAlive
                return true
            }
        }
        return false
    }

    /// Offsets mirror ets2_ff_shm.h exactly — verified by static_assert on the
    /// C side.
    private func readBody(base: UnsafeMutableRawPointer) {
        // seq u64   @0
        // render_ts @8
        // sim_ts    @16
        state.renderTsUs = base.load(fromByteOffset: 8,  as: UInt64.self)
        state.simTsUs    = base.load(fromByteOffset: 16, as: UInt64.self)

        // magic/version at 24/28 — skipped (already validated)

        state.speed             = base.load(fromByteOffset: 32, as: Float.self)
        state.engineRPM         = base.load(fromByteOffset: 36, as: Float.self)
        state.engineGear        = base.load(fromByteOffset: 40, as: Int32.self)
        state.effectiveSteering = base.load(fromByteOffset: 44, as: Float.self)
        state.inputSteering     = base.load(fromByteOffset: 48, as: Float.self)

        state.accelX = base.load(fromByteOffset: 52, as: Float.self)
        state.accelY = base.load(fromByteOffset: 56, as: Float.self)
        state.accelZ = base.load(fromByteOffset: 60, as: Float.self)

        state.wheelCount     = base.load(fromByteOffset: 64, as: UInt32.self)
        state.collisionCount = base.load(fromByteOffset: 68, as: UInt32.self)
        state.gearshiftCount = base.load(fromByteOffset: 72, as: UInt32.self)
        // 76: _flags_pad

        for i in 0..<8 {
            state.wheelSusp[i]   = base.load(fromByteOffset: 80 + i * 4, as: Float.self)
            state.wheelAngVel[i] = base.load(fromByteOffset: 112 + i * 4, as: Float.self)
        }

        state.pluginAlive      = base.load(fromByteOffset: 144, as: UInt8.self) != 0
        state.paused           = base.load(fromByteOffset: 145, as: UInt8.self) != 0
        state.connected        = base.load(fromByteOffset: 146, as: UInt8.self) != 0
        state.trailerConnected = base.load(fromByteOffset: 147, as: UInt8.self) != 0

        for i in 0..<8 {
            state.wheelOnGround[i] = base.load(fromByteOffset: 148 + i, as: UInt8.self) != 0
            state.wheelSurface[i]  = base.load(fromByteOffset: 156 + i, as: UInt8.self)
        }

        state.yawRate = base.load(fromByteOffset: 164, as: Float.self)
    }
}
