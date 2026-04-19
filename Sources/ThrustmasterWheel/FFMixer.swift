import Foundation
import CUSBModeSwitch
import ETS2FFCore

/// Turns ETS2 telemetry into Thrustmaster T300RS force-feedback effects.
///
/// Effect slot allocation:
///   slot 1 — static spring (centering), set once at startup
///   slot 2 — static damper (resistance to fast movement), set once at startup
///   slot 3 — constant force: self-centering × speed² + impulses (suspension,
///            collision, gearshift, vertical impact, sway correction, trailer
///            parking assist)
///   slot 4 — periodic sine: combined engine rumble + road surface texture +
///            ABS shiver (picks loudest of the three)
///
/// USB write rate limiting:
///   constant force:  updated at most ~30 Hz
///   periodic sine:   updated at most ~10 Hz (re-upload = replace)
final class FFMixer {

    struct Tuning {
        // Self-centering
        var selfCenterGain: Float = 22000
        var selfCenterRefSpeedMs: Float = 25
        var selfCenterMaxMs: Float = 35

        // Road bump (front suspension delta → constant force burst)
        var suspensionGain: Float = 18000
        var suspensionDecaySec: Float = 0.12

        // Collision (lateral |accel_x| spike → constant force burst)
        var collisionAccelThresh: Float = 8.0
        var collisionGain: Float = 1800
        var collisionDecaySec: Float = 0.25

        // Engine rumble
        var engineRumbleMin: Float = 2500
        var engineRumbleMax: Float = 7500
        var engineIdleRpm: Float = 600
        var engineRedlineRpm: Float = 2400

        // Road surface rumble
        var surfaceRefSpeedMs: Float = 25
        var surfaceAmpSmooth: Float = 0
        var surfaceAmpCoarse: Float = 3500
        var surfaceAmpDirt: Float = 8000
        var surfaceAmpGrass: Float = 11000
        var surfaceAmpSlippery: Float = 1500
        var surfaceAmpRumble: Float = 16000

        // v2: ABS / wheel-lockup shiver (periodic sine burst)
        var absShiverAmp: Float = 14000
        var absShiverPeriodMs: UInt16 = 18   // ~55 Hz, feels like ABS pulsing
        var absLockupRatio: Float = 0.35     // (actual_angvel / expected_angvel) below this = locked
        var absMinSpeedMs: Float = 3.0       // don't trigger below ~10 km/h

        // v2: Gearshift "thunk"
        var gearshiftGain: Float = 12000
        var gearshiftDecaySec: Float = 0.18

        // v2: Trailer sway correction
        var swayGain: Float = 14000
        var swayYawRateThresh: Float = 0.15  // rad/s — above this, feel the lateral swing
        var swayMinSpeedMs: Float = 8.0

        // v2: Vertical chassis impact (falling off a curb, big pothole)
        var verticalAccelThresh: Float = 6.0
        var verticalGain: Float = 2600
        var verticalDecaySec: Float = 0.15

        // v2: Heavy parking with trailer
        var parkingMaxSpeedMs: Float = 4.0   // <~14 km/h counts as parking
        var parkingMultiplier: Float = 1.8   // how much to amp the self-center feel
    }

    var tuning = Tuning()
    private let baseTuning = Tuning()

    /// Apply the UI-facing scalars from FFSettings to the mixer tuning.
    func applySettings(_ s: FFSettings) {
        func scale(_ v: Int) -> Float { Float(max(0, min(100, v))) / 100.0 }

        let sc = scale(s.selfCenterGain)
        let er = scale(s.engineRumble)
        let sr = scale(s.surfaceRumble)
        let si = scale(s.suspensionImpact)
        let ci = scale(s.collisionImpact)
        let abs_ = scale(s.absShiver)
        let gs = scale(s.gearshiftThunk)
        let sw = scale(s.trailerSway)
        let vi = scale(s.verticalImpact)
        let pk = scale(s.trailerParking)

        tuning.selfCenterGain     = baseTuning.selfCenterGain * sc * 2.0

        tuning.engineRumbleMin    = baseTuning.engineRumbleMin * er
        tuning.engineRumbleMax    = baseTuning.engineRumbleMax * er

        tuning.surfaceAmpCoarse   = baseTuning.surfaceAmpCoarse   * sr
        tuning.surfaceAmpDirt     = baseTuning.surfaceAmpDirt     * sr
        tuning.surfaceAmpGrass    = baseTuning.surfaceAmpGrass    * sr
        tuning.surfaceAmpSlippery = baseTuning.surfaceAmpSlippery * sr
        tuning.surfaceAmpRumble   = baseTuning.surfaceAmpRumble   * sr

        tuning.suspensionGain     = baseTuning.suspensionGain * si
        tuning.collisionGain      = baseTuning.collisionGain  * ci
        tuning.absShiverAmp       = baseTuning.absShiverAmp   * abs_
        tuning.gearshiftGain      = baseTuning.gearshiftGain  * gs
        tuning.swayGain           = baseTuning.swayGain       * sw
        tuning.verticalGain       = baseTuning.verticalGain   * vi

        // Parking multiplier: slider 0% → 1.0 (no extra effort), 100% → 1.8x
        tuning.parkingMultiplier  = 1.0 + (baseTuning.parkingMultiplier - 1.0) * pk
    }

    private let constantSlot: UInt8 = 3
    private let sineSlot: UInt8 = 4

    // Rate limiting
    private var lastConstantUpdateHostTime: UInt64 = 0
    private var lastSineUpdateHostTime: UInt64 = 0
    private let constantIntervalSec: Double = 1.0 / 30.0
    private let sineIntervalSec: Double = 1.0 / 10.0

    // Per-effect decaying impulses. Signed when direction matters.
    private var suspensionImpulse: Float = 0
    private var collisionImpulse: Float = 0
    private var gearshiftImpulse: Float = 0        // signed
    private var verticalImpulse: Float = 0
    private var absIntensity: Float = 0            // 0..1 — drives sine amp
    private var swayForce: Float = 0               // signed — drives constant force

    // Last-seen state for delta calculations
    private var lastSusp: [Float] = Array(repeating: 0, count: 8)
    private var lastTickHostTime: UInt64 = 0
    private var initialized = false

    // Last-sent sine state
    private var lastSineMag: UInt16 = .max
    private var lastSinePeriodMs: UInt16 = .max
    private var sineUploaded = false

    private var collisionCountBaseline: UInt32 = 0
    private var lastGear: Int32 = 0

    /// Call once after the shm header is valid, before the first update().
    func prime(state: TelemetryReader.State) {
        _ = thrustmaster_ff_constant(constantSlot, 0)
        collisionCountBaseline = state.collisionCount
        lastSusp = state.wheelSusp
        lastGear = state.engineGear
        lastTickHostTime = machNowNs()
        initialized = true
        // Mixer ready — no log needed, status printed by main.swift.
    }

    /// Called once per poll cycle (ideally 60 Hz).
    func update(state: TelemetryReader.State, live: Bool) {
        if !initialized { return }

        let now = machNowNs()
        let dt = max(0.001, Float(Double(now - lastTickHostTime) / 1_000_000_000.0))
        lastTickHostTime = now

        if !live {
            suspensionImpulse *= expDecay(0.3, dt: dt)
            collisionImpulse  *= expDecay(0.3, dt: dt)
            gearshiftImpulse  *= expDecay(0.3, dt: dt)
            verticalImpulse   *= expDecay(0.3, dt: dt)
            swayForce         *= expDecay(0.3, dt: dt)
            absIntensity      *= expDecay(0.2, dt: dt)
            emitConstant(0, now: now, force: true)
            emitSine(magnitude: 0, periodMs: 40, now: now, force: true)
            lastSusp = state.wheelSusp
            lastGear = state.engineGear
            return
        }

        // ── Suspension delta (front wheels only) ───────────────────────
        var bump: Float = 0
        for i in 0..<min(2, Int(state.wheelCount)) {
            if state.wheelOnGround[i] {
                let d = state.wheelSusp[i] - lastSusp[i]
                bump = max(bump, abs(d))
            }
        }
        lastSusp = state.wheelSusp
        let bumpImpulse = min(1.0, bump * 8.0) * tuning.suspensionGain
        suspensionImpulse = max(suspensionImpulse * expDecay(tuning.suspensionDecaySec, dt: dt),
                                bumpImpulse)

        // ── Collision impulse (lateral accel spike + game's own count) ─
        let lateral = abs(state.accelX)
        if lateral > tuning.collisionAccelThresh {
            let over = lateral - tuning.collisionAccelThresh
            collisionImpulse = max(collisionImpulse, min(32000, over * tuning.collisionGain))
        }
        if state.collisionCount != collisionCountBaseline {
            collisionCountBaseline = state.collisionCount
            collisionImpulse = max(collisionImpulse, 28000)
        }
        collisionImpulse *= expDecay(tuning.collisionDecaySec, dt: dt)

        // ── Vertical impact (falling off a curb, big pothole): |accel_y| spike ─
        let vertical = abs(state.accelY)
        if vertical > tuning.verticalAccelThresh {
            let over = vertical - tuning.verticalAccelThresh
            verticalImpulse = max(verticalImpulse, min(30000, over * tuning.verticalGain))
        }
        verticalImpulse *= expDecay(tuning.verticalDecaySec, dt: dt)

        // ── Gearshift thunk: engine_gear change ──────────────────────
        if state.engineGear != lastGear && lastGear != 0 && state.engineGear != 0 {
            // Gearshift detected. Sign: use current steering direction so the
            // thunk feels coupled to where the wheel is; if centered, bias right
            // (arbitrary but consistent).
            let steerSign: Float = state.effectiveSteering >= 0 ? 1 : -1
            // Higher gears get a slightly bigger thunk (big rigs "drop into gear")
            let gearFactor = min(1.0, 0.5 + Float(abs(state.engineGear)) * 0.1)
            gearshiftImpulse = steerSign * tuning.gearshiftGain * gearFactor
        }
        lastGear = state.engineGear
        gearshiftImpulse *= expDecay(tuning.gearshiftDecaySec, dt: dt)

        // ── Trailer sway: yaw rate "disagrees" with steering input ────
        // If the truck is yawing but the wheel is near-straight, that's sway
        // from the trailer pushing the cab around. Counter-force direction
        // matches the yaw (so the driver feels which way the truck is sliding).
        if state.trailerConnected && state.speed > tuning.swayMinSpeedMs &&
            abs(state.effectiveSteering) < 0.35 &&
            abs(state.yawRate) > tuning.swayYawRateThresh {
            let over = abs(state.yawRate) - tuning.swayYawRateThresh
            let mag = min(1.0, over * 2.5) * tuning.swayGain
            let sign: Float = state.yawRate >= 0 ? 1 : -1
            // Ease-in toward target so it doesn't chatter frame-to-frame.
            let target = sign * mag
            swayForce += (target - swayForce) * min(1.0, dt * 6.0)
        } else {
            // Decay toward 0 quickly when conditions aren't met.
            swayForce *= expDecay(0.2, dt: dt)
        }

        // ── ABS / wheel lockup: wheel angvel << expected for current speed ─
        // In SCS, wheel_angvel is rad/s. Expected rad/s ≈ speed_ms / radius.
        // Truck tire radius is ~0.5 m, so expected ≈ 2 × speed. Anything
        // dramatically below expected = locked.
        absIntensity *= expDecay(0.08, dt: dt)  // fast decay — ABS is staccato
        if state.speed > tuning.absMinSpeedMs {
            let expected = state.speed * 2.0 + 0.001
            var lockingCount: Int = 0
            for i in 0..<min(Int(state.wheelCount), 8) where state.wheelOnGround[i] {
                let ratio = abs(state.wheelAngVel[i]) / expected
                if ratio < tuning.absLockupRatio {
                    lockingCount += 1
                }
            }
            if lockingCount > 0 {
                let intensityTarget = min(1.0, Float(lockingCount) / 4.0)
                absIntensity = max(absIntensity, intensityTarget)
            }
        }

        // ── Self-centering ───────────────────────────────────────────
        let spd = min(state.speed, tuning.selfCenterMaxMs)
        let spdNorm = spd / tuning.selfCenterRefSpeedMs
        var selfCenter = -state.effectiveSteering * (spdNorm * spdNorm) * tuning.selfCenterGain

        // Heavy parking: at low speed with trailer, amplify the centering
        // effort (the driver must "push harder" to turn a loaded rig).
        if state.trailerConnected && state.speed < tuning.parkingMaxSpeedMs {
            let parkAmount = 1.0 - (state.speed / tuning.parkingMaxSpeedMs)  // 1..0 over speed range
            // Use effective steering × parking spring so force pulls back to center
            // hard; extra oomph only when turned significantly.
            let parkingPull = -state.effectiveSteering * parkAmount *
                              (tuning.parkingMultiplier - 1.0) * tuning.selfCenterGain
            selfCenter += parkingPull
        }

        // ── Combine all impulses into signed constant force ──────────
        // Suspension, collision, vertical use sign of selfCenter so they yank
        // in the direction the wheel is resisting. Gearshift and sway have
        // their own signs already.
        let sign: Float = selfCenter >= 0 ? 1 : -1
        var total = selfCenter
            + sign * suspensionImpulse
            + sign * collisionImpulse
            + sign * verticalImpulse
            + gearshiftImpulse
            + swayForce
        total = max(-32767, min(32767, total))
        emitConstant(Int16(total), now: now, force: false)

        // ── Sine effect: pick loudest of engine / surface / ABS ──────
        let engAmp  = engineAmplitude(rpm: state.engineRPM, gear: state.engineGear)
        let surfAmp = surfaceAmplitude(state: state)
        let absAmp  = absIntensity * tuning.absShiverAmp

        let (mag, periodMs): (UInt16, UInt16)
        if absAmp >= engAmp && absAmp >= surfAmp && absAmp > 500 {
            // ABS dominates
            mag = UInt16(min(32767, absAmp))
            periodMs = tuning.absShiverPeriodMs
        } else if engAmp >= surfAmp {
            mag = UInt16(min(32767, engAmp))
            periodMs = enginePeriodMs(rpm: state.engineRPM)
        } else {
            mag = UInt16(min(32767, surfAmp))
            periodMs = roadPeriodMs(state: state)
        }
        emitSine(magnitude: mag, periodMs: periodMs, now: now, force: false)
    }

    /// Stop all live effects. Static spring/damper are left as-is.
    func stop() {
        _ = thrustmaster_ff_stop(constantSlot)
        _ = thrustmaster_ff_stop(sineSlot)
    }

    // MARK: - Helpers

    private func emitConstant(_ magnitude: Int16, now: UInt64, force: Bool) {
        let sinceLast = Double(now - lastConstantUpdateHostTime) / 1_000_000_000.0
        if !force && sinceLast < constantIntervalSec { return }
        lastConstantUpdateHostTime = now
        _ = thrustmaster_ff_constant_update(constantSlot, magnitude)
    }

    private func emitSine(magnitude: UInt16, periodMs: UInt16, now: UInt64, force: Bool) {
        let sinceLast = Double(now - lastSineUpdateHostTime) / 1_000_000_000.0
        if !force && sinceLast < sineIntervalSec { return }

        if magnitude == 0 {
            if sineUploaded {
                _ = thrustmaster_ff_stop(sineSlot)
                sineUploaded = false
                lastSineMag = 0
            }
            lastSineUpdateHostTime = now
            return
        }

        if !force &&
            abs(Int(magnitude) - Int(lastSineMag)) < 500 &&
            abs(Int(periodMs) - Int(lastSinePeriodMs)) < 3 &&
            sineUploaded {
            lastSineUpdateHostTime = now
            return
        }

        lastSineUpdateHostTime = now
        lastSineMag = magnitude
        lastSinePeriodMs = periodMs
        _ = thrustmaster_ff_sine(sineSlot, magnitude, max(5, periodMs))
        sineUploaded = true
    }

    private func engineAmplitude(rpm: Float, gear: Int32) -> Float {
        if rpm < tuning.engineIdleRpm * 0.5 { return 0 }
        let span = max(1, tuning.engineRedlineRpm - tuning.engineIdleRpm)
        let t = min(1.0, max(0.0, (rpm - tuning.engineIdleRpm) / span))
        var amp = tuning.engineRumbleMin + t * (tuning.engineRumbleMax - tuning.engineRumbleMin)
        if gear == 0 { amp *= 0.6 }
        return amp
    }

    private func enginePeriodMs(rpm: Float) -> UInt16 {
        let clamped = max(400, min(3000, rpm))
        let periodSec = 60.0 / clamped
        let ms = periodSec * 1000.0 * 0.5
        return UInt16(max(8, min(60, Int(ms))))
    }

    private func surfaceAmplitude(state: TelemetryReader.State) -> Float {
        if state.wheelCount == 0 { return 0 }
        var worst: Float = 0
        for i in 0..<min(Int(state.wheelCount), 8) where state.wheelOnGround[i] {
            let cat = TelemetryReader.SurfaceCategory(rawValue: state.wheelSurface[i]) ?? .unknown
            let base: Float
            switch cat {
            case .unknown, .smooth: base = tuning.surfaceAmpSmooth
            case .coarse:           base = tuning.surfaceAmpCoarse
            case .dirt:             base = tuning.surfaceAmpDirt
            case .grass:            base = tuning.surfaceAmpGrass
            case .slippery:         base = tuning.surfaceAmpSlippery
            case .rumble:           base = tuning.surfaceAmpRumble
            }
            worst = max(worst, base)
        }
        if worst == 0 { return 0 }
        let spdNorm = min(1.0, state.speed / tuning.surfaceRefSpeedMs)
        return worst * spdNorm
    }

    private func roadPeriodMs(state: TelemetryReader.State) -> UInt16 {
        let spd = max(1.0, min(40.0, state.speed))
        let ms = 40.0 - (spd / 40.0) * 28.0
        return UInt16(max(10, min(50, Int(ms))))
    }

    private func expDecay(_ tau: Float, dt: Float) -> Float {
        return expf(-dt / max(0.01, tau))
    }

    private func machNowNs() -> UInt64 {
        return clock_gettime_nsec_np(CLOCK_MONOTONIC)
    }
}
