import SwiftUI
import ETS2FFCore

struct ContentView: View {
    @EnvironmentObject var client: ControlClient

    // Draft = what the user is editing. Applied via "Accept".
    @State private var draft: FFSettings = SettingsStore.load()
    @State private var lastApplied: FFSettings = SettingsStore.load()
    @State private var showingApplied: Bool = false

    var hasPendingChanges: Bool { draft != lastApplied }
    var activePreset: FFPreset { FFPreset.detect(from: draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            presetPicker

            GroupBox(label: Label("Wheel", systemImage: "steeringwheel")) {
                VStack(alignment: .leading, spacing: 12) {
                    intSlider("Rotation range",
                              value: $draft.range,
                              range: 40...1080, step: 10, suffix: "°")
                    intSlider("Force feedback strength",
                              value: $draft.gain,
                              range: 0...65535, step: 500, suffix: "")
                }
                .padding(8)
            }

            GroupBox(label: Label("Baseline feel", systemImage: "waveform")) {
                VStack(alignment: .leading, spacing: 12) {
                    intSlider("Self-centering spring",
                              value: $draft.spring,
                              range: 0...100, step: 1, suffix: "%")
                    intSlider("Damper resistance",
                              value: $draft.damper,
                              range: 0...100, step: 1, suffix: "%")
                }
                .padding(8)
            }

            GroupBox(label: Label("ETS2 telemetry mix", systemImage: "car.side")) {
                VStack(alignment: .leading, spacing: 12) {
                    intSlider("Self-centering (speed-based)",
                              value: $draft.selfCenterGain,
                              range: 0...100, step: 1, suffix: "%")
                    intSlider("Engine rumble",
                              value: $draft.engineRumble,
                              range: 0...100, step: 1, suffix: "%")
                    intSlider("Road surface rumble",
                              value: $draft.surfaceRumble,
                              range: 0...100, step: 1, suffix: "%")
                    intSlider("Suspension bumps",
                              value: $draft.suspensionImpact,
                              range: 0...100, step: 1, suffix: "%")
                    intSlider("Collision impacts",
                              value: $draft.collisionImpact,
                              range: 0...100, step: 1, suffix: "%")
                }
                .padding(8)
            }

            GroupBox(label: Label("Pro tactile effects", systemImage: "waveform.badge.magnifyingglass")) {
                VStack(alignment: .leading, spacing: 12) {
                    intSlider("ABS / wheel-lockup shiver",
                              value: $draft.absShiver,
                              range: 0...100, step: 1, suffix: "%")
                    intSlider("Gearshift thunk",
                              value: $draft.gearshiftThunk,
                              range: 0...100, step: 1, suffix: "%")
                    intSlider("Trailer-sway correction",
                              value: $draft.trailerSway,
                              range: 0...100, step: 1, suffix: "%")
                    intSlider("Vertical-impact (potholes, curb drops)",
                              value: $draft.verticalImpact,
                              range: 0...100, step: 1, suffix: "%")
                    intSlider("Heavy parking with trailer",
                              value: $draft.trailerParking,
                              range: 0...100, step: 1, suffix: "%")
                }
                .padding(8)
            }

            Spacer(minLength: 0)

            buttonRow
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 960)
        .onAppear {
            client.query()
        }
        .onReceive(client.$latestStatus.compactMap { $0 }) { status in
            if !showingApplied {
                // First status from daemon wins — sync draft to its truth.
                draft = status.currentSettings
                lastApplied = status.currentSettings
                showingApplied = true
            } else {
                lastApplied = status.currentSettings
            }
        }
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Preset")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary).font(.caption)
                Text(activePreset.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(FFPreset.allCases) { preset in
                    presetButton(preset)
                }
            }
        }
    }

    @ViewBuilder
    private func presetButton(_ preset: FFPreset) -> some View {
        let isActive = activePreset == preset
        let isSelectable = preset != .custom  // "Custom" is an indicator, not a button

        Button {
            if let s = preset.settings { draft = s }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: preset.symbolName)
                Text(preset.rawValue)
                    .fontWeight(isActive ? .semibold : .regular)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isActive ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable && !isActive)
        .help(preset.tagline)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "steeringwheel")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Thrustmaster T300RS")
                    .font(.title2).bold()
                statusLine
            }
            Spacer()
            liveReadout
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(client.connected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(client.connected ? "Daemon connected" : "Waiting for daemon…")
                .foregroundStyle(.secondary)
                .font(.caption)
            if let s = client.latestStatus {
                Text("•").foregroundStyle(.secondary).font(.caption)
                Circle()
                    .fill(s.ets2Live ? Color.green : (s.ets2Connected ? Color.yellow : Color.gray))
                    .frame(width: 8, height: 8)
                Text(s.ets2Live ? "ETS2 live" : (s.ets2Connected ? "ETS2 paused" : "ETS2 not running"))
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var liveReadout: some View {
        if let s = client.latestStatus, s.ets2Connected {
            HStack(spacing: 14) {
                readoutItem(title: "Speed",  value: "\(s.speedKmh)", unit: "km/h")
                readoutItem(title: "RPM",    value: "\(s.rpm)", unit: "")
                readoutItem(title: "Gear",   value: gearLabel(s.gear), unit: "")
            }
            .monospacedDigit()
        }
    }

    private func gearLabel(_ gear: Int) -> String {
        if gear == 0 { return "N" }
        if gear < 0 { return "R\(-gear)" }
        return "\(gear)"
    }

    private func readoutItem(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3).bold()
                if !unit.isEmpty {
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var buttonRow: some View {
        HStack {
            Button("Reset to defaults") {
                draft = .default
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("Revert") {
                draft = lastApplied
            }
            .buttonStyle(.bordered)
            .disabled(!hasPendingChanges)

            Button("Accept") {
                client.apply(draft)
                lastApplied = draft
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!client.connected || !hasPendingChanges)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func intSlider(_ label: String,
                           value: Binding<Int>,
                           range: ClosedRange<Int>,
                           step: Int,
                           suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value.wrappedValue)\(suffix)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int(($0 / Double(step)).rounded()) * step }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
        }
    }
}
