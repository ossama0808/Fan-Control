import SwiftUI
import Charts
import FanControlKit

/// Shared heat ramp. One function so a colour means the same thing everywhere.
func heatColor(_ celsius: Double) -> Color {
    switch celsius {
    case ..<55: .green
    case ..<70: .yellow
    case ..<85: .orange
    default:    .red
    }
}

/// The dropdown panel. Rendered with `.menuBarExtraStyle(.window)`, which allows
/// arbitrary SwiftUI instead of plain menu rows.
///
/// Two measured constraints shape the whole layout:
///  - The panel sizes to the MINIMUM, not the ideal, and never clamps to the
///    screen. An unbounded list of the ~290 live sensors produced a 3263pt-tall
///    panel whose lower half was physically unreachable. Every variable-length
///    region here is inside a fixed-height ScrollView.
///  - The panel takes key focus without the app becoming frontmost, so any
///    action that opens a window must dismiss() first, then activate.
struct MenuBarPanel: View {
    @EnvironmentObject var engine: FanEngine
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var history: SensorHistory
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var sensorsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let note = statusNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(engine.lastError != nil || engine.backstopReason != nil
                                     ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            fans
            Divider()
            thermal
            Divider()
            powerStrip
            Divider()
            sensorRollup
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
    }

    // MARK: Header

    private var hottest: (String, Double)? {
        ["agg.cpu", "agg.gpu", "agg.soc"]
            .compactMap { id in engine.aggregates[id].map { (id, $0) } }
            .max { $0.1 < $1.1 }
    }

    private var activePresetName: String {
        engine.allPresets.first { $0.id == settings.activePresetID }?.name ?? "Custom"
    }

    private var statusColor: Color {
        if engine.helperStatus != .ready { return .red }
        if engine.backstopReason != nil { return .red }
        if engine.lastError != nil { return .orange }
        if engine.controlUnavailable != nil { return .secondary }
        return .green
    }

    /// A short line explaining anything the dot alone cannot. A coloured dot with
    /// no text leaves the user guessing why their fans are not moving.
    private var statusNote: String? {
        if engine.helperStatus != .ready { return "Helper not installed — sensors are read-only" }
        if let b = engine.backstopReason { return "Thermal backstop: \(engine.label(forSensorID: b))" }
        if let e = engine.lastError { return e }
        return engine.controlUnavailable
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "fanblades.fill").foregroundStyle(.tint)
            Text(activePresetName).font(.headline)
            Circle().fill(statusColor).frame(width: 6, height: 6)
                .help(engine.lastError ?? engine.helperStatus.description)
            Spacer()
            if let (_, v) = hottest {
                Text(settings.formatTemperature(v))
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(heatColor(v))
            }
        }
    }

    // MARK: Fans

    private var fans: some View {
        HStack(spacing: 10) {
            ForEach(engine.fans) { fan in
                FanTile(fan: fan, samples: downsample(history.values("fan\(fan.index)")),
                        reason: engine.explanation(forFan: fan.index))
            }
        }
    }

    // MARK: Thermal

    private var thermal: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThermalChart(cpu: downsample(history.values("agg.cpu")),
                         gpu: downsample(history.values("agg.gpu")),
                         soc: downsample(history.values("agg.soc")))
                .equatable()
                .frame(height: 52)

            HStack(spacing: 4) {
                ForEach(chipIDs, id: \.0) { id, label in
                    if let v = engine.aggregates[id] { TempChip(label: label, celsius: v, settings: settings) }
                }
            }
        }
    }

    private var chipIDs: [(String, String)] {
        [("agg.cpu", "CPU"), ("agg.gpu", "GPU"), ("agg.soc", "SoC"),
         ("agg.storage", "SSD"), ("agg.skinUpper", "Top"), ("agg.skinLower", "Base")]
    }

    // MARK: Power

    private var powerStrip: some View {
        HStack(spacing: 0) {
            PowerCell(title: "SYSTEM", value: engine.extra("PSTR").map { String(format: "%.0f W", $0) })
            Divider().frame(height: 22)
            PowerCell(title: "ADAPTER", value: engine.extra("PDTR").map { String(format: "%.0f W", $0) })
            Divider().frame(height: 22)
            PowerCell(title: "BATTERY", value: engine.extra("BRSC").map { String(format: "%.0f%%", $0) })
            Divider().frame(height: 22)
            PowerCell(title: "POWER", value: engine.onACPower ? "AC" : "Battery")
        }
    }

    // MARK: Sensors

    /// Rolls ~290 live sensors up to one row per group. Listing them all is what
    /// produced an unreachable panel; the rollup keeps the "what is hot" signal
    /// while staying scannable.
    private var groupRows: [(SensorGroup, Double, Int)] {
        Dictionary(grouping: engine.readings.filter(\.isLive), by: \.sensor.group)
            .compactMap { g, rows in
                guard let hottest = rows.map(\.celsius).max() else { return nil }
                return (g, hottest, rows.count)
            }
            .sorted { $0.1 > $1.1 }
    }

    private var sensorRollup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { sensorsExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: sensorsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Text("All sensors").font(.callout)
                    Spacer()
                    Text("\(engine.liveSensorCount) live")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if sensorsExpanded {
                // Fixed height is mandatory: a ScrollView has no intrinsic height,
                // and maxHeight alone collapses the whole panel to its header.
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(groupRows, id: \.0) { group, hottest, count in
                            HStack(spacing: 6) {
                                Text(group.rawValue).font(.caption)
                                    .frame(width: 118, alignment: .leading).lineLimit(1)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.quaternary)
                                        Capsule().fill(heatColor(hottest))
                                            .frame(width: geo.size.width *
                                                   ((hottest - 20) / 85).clamped(to: 0.02...1))
                                    }
                                }
                                .frame(height: 5)
                                Text(settings.formatTemperature(hottest))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 42, alignment: .trailing)
                                Text("×\(count)").font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 26, alignment: .trailing)
                            }
                        }
                    }
                }
                .frame(height: 150)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            ForEach(Preset.builtIns) { p in
                Button(p.name) { engine.applyPreset(p) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(engine.helperStatus != .ready)
            }
            Spacer()
            Menu {
                Button("Open Fan Control…") {
                    // Order matters: the panel holds key focus while the app is
                    // NOT frontmost, so activating before dismissing leaves the
                    // window behind the panel and the app in the background.
                    dismiss()
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                SettingsLink { Text("Preferences…") }
                Divider()
                Button("Quit Fan Control") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

// MARK: - Pieces

private struct FanTile: View {
    let fan: FanState
    let samples: [Double]
    let reason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "fanblades.fill").font(.system(size: 10))
                    .foregroundStyle(fan.hardwareIsManual ? .orange : .secondary)
                Text(fan.name).font(.caption.weight(.medium))
                Spacer()
                Text(fan.hardwareIsManual ? "MANUAL" : "AUTO")
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(fan.hardwareIsManual ? Color.orange.opacity(0.25) : Color.gray.opacity(0.2),
                                in: Capsule())
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(fan.currentRPM))")
                    .font(.system(size: 21, weight: .semibold).monospacedDigit())
                Text("rpm").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(fan.loadFraction * 100))%")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(fan.loadFraction > 0.8 ? Color.orange : .accentColor)
                        .frame(width: max(2, geo.size.width * fan.loadFraction))
                }
            }
            .frame(height: 5)

            Sparkline(values: samples, low: fan.minRPM, high: fan.maxRPM)
                .equatable()
                .frame(height: 22)

            HStack {
                Text("→ \(Int(fan.targetRPM))").font(.system(size: 9).monospacedDigit())
                Spacer()
                Text("\(Int(fan.minRPM))–\(Int(fan.maxRPM))")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            if let reason {
                Text(reason).font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct TempChip: View {
    let label: String
    let celsius: Double
    let settings: AppSettings

    var body: some View {
        VStack(spacing: 2) {
            Text(settings.formatTemperature(celsius).replacingOccurrences(of: "°C", with: "")
                    .replacingOccurrences(of: "°F", with: ""))
                .font(.system(size: 12, weight: .bold).monospacedDigit())
            Capsule().fill(heatColor(celsius)).frame(height: 2.5)
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PowerCell: View {
    let title: String
    let value: String?

    var body: some View {
        VStack(spacing: 1) {
            Text(value ?? "—").font(.system(size: 11, weight: .medium).monospacedDigit())
            Text(title).font(.system(size: 7)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

extension HelperClient.Status {
    var description: String {
        switch self {
        case .ready: "Helper installed"
        case .notInstalled: "Helper not installed — sensors are read-only"
        case .notPrivileged: "Helper installed but not privileged"
        }
    }
}


// MARK: - Charts
//
// Both chart views are isolated, take plain arrays, and are Equatable.
//
// This matters more than it looks. Swift Charts re-lays-out on every evaluation,
// and the panel's body runs whenever the engine or the history publishes. An
// earlier version built the thermal chart as a nested ForEach emitting one
// LineMark per sample with a per-mark `.foregroundStyle(by:)` — 360 marks, each
// carrying a style closure, rebuilt several times a second. That alone pegged a
// core at 100% and froze the app while the panel was open. Marking these
// Equatable lets SwiftUI skip the rebuild entirely when the samples have not
// changed, and downsampling caps the mark count regardless of buffer length.

/// Reduce a series to at most `limit` points. The chart is ~300pt wide, so
/// drawing 120 samples per series buys nothing a reader can see.
func downsample(_ values: [Double], limit: Int = 40) -> [Double] {
    guard values.count > limit else { return values }
    let stride = Double(values.count) / Double(limit)
    return (0..<limit).map { values[min(values.count - 1, Int(Double($0) * stride))] }
}

struct ThermalChart: View, Equatable {
    let cpu: [Double]
    let gpu: [Double]
    let soc: [Double]

    static func == (a: Self, b: Self) -> Bool {
        a.cpu == b.cpu && a.gpu == b.gpu && a.soc == b.soc
    }

    private struct Sample: Identifiable {
        let id: Int
        let t: Int
        let series: String
        let value: Double
    }

    private var samples: [Sample] {
        var out: [Sample] = []
        out.reserveCapacity(cpu.count + gpu.count + soc.count)
        var id = 0
        for (name, values) in [("CPU", cpu), ("GPU", gpu), ("SoC", soc)] {
            for (t, v) in values.enumerated() {
                out.append(Sample(id: id, t: t, series: name, value: v)); id += 1
            }
        }
        return out
    }

    var body: some View {
        if cpu.count < 2 {
            Text("Collecting history…")
                .font(.caption).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            Chart(samples) { s in
                LineMark(x: .value("t", s.t), y: .value("°C", s.value))
                    .foregroundStyle(by: .value("series", s.series))
            }
            .chartYScale(domain: 20...105)
            .chartForegroundStyleScale(["CPU": Color.orange, "GPU": .purple, "SoC": .teal])
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [40, 70, 100]) { AxisValueLabel().font(.system(size: 8)) }
            }
            .chartOverlay { _ in
                // A static rule rather than a RuleMark, so it is not re-solved
                // as part of the mark set on every update.
                GeometryReader { geo in
                    let y = geo.size.height * (1 - (85 - 20) / 85)
                    Path { $0.move(to: .init(x: 0, y: y)); $0.addLine(to: .init(x: geo.size.width, y: y)) }
                        .stroke(.red.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
    }
}

struct Sparkline: View, Equatable {
    let values: [Double]
    let low: Double
    let high: Double

    static func == (a: Self, b: Self) -> Bool {
        a.values == b.values && a.low == b.low && a.high == b.high
    }

    var body: some View {
        if values.count > 1 {
            Chart(Array(values.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("t", i), y: .value("rpm", v))
                    .foregroundStyle(.linearGradient(
                        colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("t", i), y: .value("rpm", v))
                    .foregroundStyle(Color.accentColor)
            }
            .chartYScale(domain: low...high)
            .chartXAxis(.hidden).chartYAxis(.hidden)
        } else {
            Color.clear
        }
    }
}
