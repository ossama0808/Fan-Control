import SwiftUI
import FanControlKit

struct FanEditorView: View {
    let fanIndex: Int
    @EnvironmentObject var engine: FanEngine
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private enum Kind: String, CaseIterable { case auto = "Auto", constant = "Constant", sensor = "Sensor-based" }
    @State private var kind: Kind = .auto
    @State private var constantRPM: Double = 2000
    @State private var sensorID: String = "agg.cpu"
    @State private var minTemp: Double = 50
    @State private var maxTemp: Double = 85
    @State private var minRPM: Double = 1350
    @State private var maxRPM: Double = 5000
    /// Set when this fan is currently driven by a multi-leg profile. Editing it
    /// here means taking it out of that profile, so say so rather than silently
    /// discarding the profile the user selected.
    @State private var wasProfileManaged = false

    private var fan: FanState? { engine.fans.first { $0.index == fanIndex } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(fan?.name ?? "Fan") control").font(.title3.weight(.semibold))

            if wasProfileManaged {
                Label("This fan is driven by a profile. Applying a mode here takes it out of that profile.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("", selection: $kind) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            switch kind {
            case .auto:
                Text("The system's own thermal management drives this fan.")
                    .foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)

            case .constant:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Speed").frame(width: 60, alignment: .leading)
                        Slider(value: $constantRPM, in: rpmRange)
                        Text("\(Int(constantRPM)) rpm").monospacedDigit().frame(width: 90, alignment: .trailing)
                    }
                    Text("Range \(Int(rpmRange.lowerBound))–\(Int(rpmRange.upperBound)) rpm")
                        .font(.caption).foregroundStyle(.tertiary)
                }

            case .sensor:
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Sensor", selection: $sensorID) {
                        Section("Aggregates") {
                            ForEach(AggregateSensor.all) { Text($0.label).tag($0.id) }
                        }
                        Section("Individual sensors") {
                            ForEach(engine.readings.filter(\.isLive)) { r in
                                Text("\(r.sensor.label)  (\(r.sensor.key))").tag(r.sensor.key)
                            }
                        }
                    }

                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Text("From").frame(width: 44, alignment: .leading)
                            Slider(value: $minTemp, in: 20...110)
                            Text(settings.formatTemperature(minTemp))
                                .monospacedDigit().frame(width: 60, alignment: .trailing)
                            Text("→ \(Int(minRPM)) rpm").font(.caption).frame(width: 80, alignment: .trailing)
                        }
                        GridRow {
                            Text("To").frame(width: 44, alignment: .leading)
                            Slider(value: $maxTemp, in: 20...110)
                            Text(settings.formatTemperature(maxTemp))
                                .monospacedDigit().frame(width: 60, alignment: .trailing)
                            Text("→ \(Int(maxRPM)) rpm").font(.caption).frame(width: 80, alignment: .trailing)
                        }
                        GridRow {
                            Text("Min rpm").frame(width: 44, alignment: .leading)
                            Slider(value: $minRPM, in: rpmRange)
                            Text("\(Int(minRPM))").monospacedDigit().frame(width: 60, alignment: .trailing)
                            Color.clear.frame(width: 80, height: 1)
                        }
                        GridRow {
                            Text("Max rpm").frame(width: 44, alignment: .leading)
                            Slider(value: $maxRPM, in: rpmRange)
                            Text("\(Int(maxRPM))").monospacedDigit().frame(width: 60, alignment: .trailing)
                            Color.clear.frame(width: 80, height: 1)
                        }
                    }

                    livePreview
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: kind == .sensor ? 430 : 260)
        .onAppear(perform: load)
    }

    private var rpmRange: ClosedRange<Double> {
        guard let f = fan, f.maxRPM > f.minRPM else { return 1000...5000 }
        return f.minRPM...f.maxRPM
    }

    @ViewBuilder private var livePreview: some View {
        let current = engine.temperature(forSensorID: sensorID)
        let mode = FanMode.sensorBased(sensorID: sensorID, minTemp: minTemp, maxTemp: maxTemp,
                                       minRPM: minRPM, maxRPM: maxRPM)
        HStack {
            Image(systemName: "eye").foregroundStyle(.secondary)
            if let c = current, let r = mode.targetRPM(temperature: c) {
                Text("Now \(settings.formatTemperature(c)) → **\(Int(r)) rpm**")
            } else {
                Text("Sensor is not reporting — fan would run at maximum")
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.callout)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func load() {
        if let f = fan { minRPM = f.minRPM; maxRPM = f.maxRPM; constantRPM = max(f.minRPM, min(2000, f.maxRPM)) }
        switch engine.modes[fanIndex] ?? .auto {
        case .auto: kind = .auto
        case .constant(let r): kind = .constant; constantRPM = r
        case .sensorBased(let id, let t0, let t1, let r0, let r1):
            kind = .sensor; sensorID = id; minTemp = t0; maxTemp = t1; minRPM = r0; maxRPM = r1
        case .multi:
            kind = .auto
            wasProfileManaged = true
        }
    }

    private func apply() {
        let mode: FanMode = switch kind {
        case .auto: .auto
        case .constant: .constant(rpm: constantRPM)
        case .sensor: .sensorBased(sensorID: sensorID,
                                   minTemp: min(minTemp, maxTemp), maxTemp: max(minTemp, maxTemp),
                                   minRPM: min(minRPM, maxRPM), maxRPM: max(minRPM, maxRPM))
        }
        engine.setMode(mode, for: fanIndex)
        settings.activePresetID = nil
    }
}
