import SwiftUI
import FanControlKit

struct MainWindowView: View {
    @EnvironmentObject var engine: FanEngine
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HSplitView {
            SensorListView()
                .frame(minWidth: 340, idealWidth: 420)
            FanPanelView()
                .frame(minWidth: 360)
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                if let err = engine.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                } else if engine.helperStatus != .ready {
                    Label("Helper not installed — read-only",
                          systemImage: "lock.fill")
                        .foregroundStyle(.secondary).font(.caption)
                }
            }
        }
    }
}

// MARK: - Sensors

struct SensorListView: View {
    @EnvironmentObject var engine: FanEngine
    @EnvironmentObject var settings: AppSettings

    private var grouped: [(SensorGroup, [SensorReading])] {
        let visible = settings.showOnlyLiveSensors
            ? engine.readings.filter(\.isLive)
            : engine.readings
        return Dictionary(grouping: visible, by: \.sensor.group)
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { ($0.key, $0.value.sorted { $0.celsius > $1.celsius }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sensors").font(.headline)
                Spacer()
                Toggle("Live only", isOn: Binding(
                    get: { settings.showOnlyLiveSensors },
                    set: { settings.showOnlyLiveSensors = $0 }))
                    .toggleStyle(.checkbox).font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            List {
                ForEach(AggregateSensor.all) { agg in
                    if let v = engine.aggregates[agg.id] {
                        HStack {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .foregroundStyle(.tint).font(.caption)
                            Text(agg.label).fontWeight(.medium)
                            Spacer()
                            Text(settings.formatTemperature(v))
                                .monospacedDigit().foregroundStyle(.primary)
                        }
                    }
                }

                ForEach(grouped, id: \.0) { group, rows in
                    Section(header: Text("\(group.rawValue)  (\(rows.count))")) {
                        ForEach(rows) { r in
                            HStack {
                                Text(r.sensor.label)
                                Text(r.sensor.key)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Text(settings.formatTemperature(r.celsius))
                                    .monospacedDigit()
                                    .foregroundStyle(r.isLive ? .primary : .tertiary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - Fans

struct FanPanelView: View {
    @EnvironmentObject var engine: FanEngine
    @EnvironmentObject var settings: AppSettings
    @State private var editing: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Fans").font(.headline)
                Spacer()
                PresetControls()
                Button("All to Auto") { engine.applyPreset(.auto) }
                    .disabled(engine.helperStatus != .ready)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(engine.fans) { fan in
                        FanCardView(fan: fan, onEdit: { editing = fan.index })
                    }
                }
                .padding(12)
            }
        }
        .sheet(item: Binding(get: { editing.map(EditTarget.init) },
                             set: { editing = $0?.index })) { t in
            FanEditorView(fanIndex: t.index)
                .environmentObject(engine)
                .environmentObject(settings)
        }
    }

    struct EditTarget: Identifiable { let index: Int; var id: Int { index } }
}

struct FanCardView: View {
    let fan: FanState
    let onEdit: () -> Void
    @EnvironmentObject var engine: FanEngine
    @EnvironmentObject var settings: AppSettings

    private var mode: FanMode { engine.modes[fan.index] ?? .auto }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "fanblades.fill")
                    .foregroundStyle(fan.hardwareIsManual ? .orange : .secondary)
                Text(fan.name).font(.headline)
                Spacer()
                Text("\(Int(fan.currentRPM)) rpm")
                    .font(.title3.monospacedDigit().weight(.semibold))
            }

            ProgressView(value: fan.loadFraction)
                .tint(fan.loadFraction > 0.8 ? .orange : .accentColor)

            HStack {
                Text("\(Int(fan.minRPM))").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("target \(Int(fan.targetRPM))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(fan.maxRPM))").font(.caption2).foregroundStyle(.tertiary)
            }

            HStack {
                Label(mode.shortDescription,
                      systemImage: mode.isAuto ? "gearshape" : "slider.horizontal.3")
                    .font(.callout)
                if case .sensorBased(let id, _, _, _, _) = mode {
                    Text("· \(engine.label(forSensorID: id))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Change…", action: onEdit)
                    .disabled(engine.helperStatus != .ready)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}


/// Save / apply / delete named fan configurations.
struct PresetControls: View {
    @EnvironmentObject var engine: FanEngine
    @EnvironmentObject var settings: AppSettings
    @State private var showingSave = false
    @State private var newName = ""

    private var activeName: String {
        engine.allPresets.first { $0.id == settings.activePresetID }?.name ?? "Custom"
    }

    var body: some View {
        Menu {
            Section("Presets") {
                ForEach(engine.allPresets) { p in
                    Button {
                        engine.applyPreset(p)
                    } label: {
                        Label(p.name, systemImage: settings.activePresetID == p.id
                              ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
            Divider()
            Button("Save current as…") { newName = ""; showingSave = true }
            if let active = engine.customPresets.first(where: { $0.id == settings.activePresetID }) {
                Button("Delete “\(active.name)”", role: .destructive) {
                    engine.deletePreset(active)
                }
            }
        } label: {
            Label(activeName, systemImage: "square.stack.3d.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(engine.helperStatus != .ready)
        .alert("Save preset", isPresented: $showingSave) {
            TextField("Preset name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !n.isEmpty else { return }
                engine.saveCurrentAsPreset(named: n)
            }
        } message: {
            Text("Stores how every fan is currently configured.")
        }
    }
}
