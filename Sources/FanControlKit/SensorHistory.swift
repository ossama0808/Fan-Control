import Foundation
import Combine

/// Rolling history for the sparklines and charts in the menu-bar panel.
///
/// Deliberately a SEPARATE observable from `FanEngine`. The menu-bar *label* is
/// a permanent subscriber to whatever it observes, so publishing a series that
/// changes every second from `FanEngine` would re-render the label once a second
/// forever, whether or not anyone has the panel open. Only the panel observes
/// this object.
@MainActor
public final class SensorHistory: ObservableObject {

    /// Two minutes at 1 Hz. Long enough to answer "did my fan just spin up",
    /// short enough that the whole structure is ~11 KB.
    public static let capacity = 120

    @Published public private(set) var series: [String: [Double]] = [:]

    private var lastSample: Date?

    /// Sampled at a fixed 1 Hz regardless of the user's poll interval, so the
    /// x-axis always means the same two minutes.
    public func record(_ values: [String: Double], now: Date = Date()) {
        if let last = lastSample, now.timeIntervalSince(last) < 1.0 { return }
        lastSample = now
        for (k, v) in values {
            var a = series[k] ?? []
            a.append(v)
            if a.count > Self.capacity { a.removeFirst(a.count - Self.capacity) }
            series[k] = a
        }
    }

    public func values(_ key: String) -> [Double] { series[key] ?? [] }

    public func clear() { series.removeAll(); lastSample = nil }
}
