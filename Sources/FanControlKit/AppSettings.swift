import Foundation
import Combine

/// UserDefaults-backed preferences.
@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private let d = UserDefaults.standard
    private enum K {
        static let fahrenheit = "Fahrenheit"
        static let preciseTemp = "PreciseTemperature"
        static let pollInterval = "PollInterval"
        static let showDockIcon = "DockIcon"
        static let menubarSensorID = "MenubarSensorID"
        static let menubarFanIndex = "MenubarFanIndex"
        static let menubarTwoLines = "MenubarTwoLines"
        static let modes = "FanModes"
        static let presets = "CustomPresets"
        static let activePreset = "ActivePreset"
        static let showOnlyLive = "ShowOnlyLiveSensors"
        static let showMenuBarIcon = "ShowMenuBarIcon"
    }

    private init() {
        d.register(defaults: [
            K.fahrenheit: false, K.preciseTemp: false, K.pollInterval: 2.0,
            K.showDockIcon: false, K.menubarTwoLines: false,
            K.menubarFanIndex: -1, K.menubarSensorID: "agg.cpu",
            K.showOnlyLive: true,
            K.showMenuBarIcon: true,
        ])
    }

    /// Publishing an unchanged value still re-renders every observer, and when
    /// the observer writes the value back — as SwiftUI does for a scene binding
    /// — that is an infinite loop. Always no-op on an unchanged write.
    private func publishedSet<T: Equatable>(_ v: T, _ key: String) {
        guard d.object(forKey: key) as? T != v else { return }
        objectWillChange.send()
        d.set(v, forKey: key)
    }

    public var fahrenheit: Bool {
        get { d.bool(forKey: K.fahrenheit) } set { publishedSet(newValue, K.fahrenheit) }
    }
    public var preciseTemperature: Bool {
        get { d.bool(forKey: K.preciseTemp) } set { publishedSet(newValue, K.preciseTemp) }
    }
    public var pollInterval: TimeInterval {
        get { max(0.5, d.double(forKey: K.pollInterval)) }
        set { publishedSet(newValue, K.pollInterval) }
    }
    public var showDockIcon: Bool {
        get { d.bool(forKey: K.showDockIcon) }
        set { publishedSet(newValue, K.showDockIcon) }
    }
    public var menubarSensorID: String {
        get { d.string(forKey: K.menubarSensorID) ?? "agg.cpu" }
        set { publishedSet(newValue, K.menubarSensorID) }
    }
    public var menubarFanIndex: Int {
        get { d.integer(forKey: K.menubarFanIndex) }
        set { publishedSet(newValue, K.menubarFanIndex) }
    }
    public var menubarTwoLines: Bool {
        get { d.bool(forKey: K.menubarTwoLines) } set { publishedSet(newValue, K.menubarTwoLines) }
    }
    public var showOnlyLiveSensors: Bool {
        get { d.bool(forKey: K.showOnlyLive) } set { publishedSet(newValue, K.showOnlyLive) }
    }
    /// Whether the status item appears in the menu bar.
    ///
    /// A plain stored value with no cross-checks. This is bound directly to
    /// `MenuBarExtra(isInserted:)`, and SwiftUI writes back through that binding
    /// during scene updates — so anything this setter does beyond storing the
    /// value runs on SwiftUI's schedule, not the user's. An earlier version
    /// forced the Dock icon on from here and published unconditionally, which
    /// turned a scene update into an unbounded render loop that pinned a core
    /// whenever the panel was open.
    ///
    /// The "app must stay reachable" rule is enforced in `ensureReachable()`,
    /// called from the preferences UI where the user actually makes the choice.
    public var showMenuBarIcon: Bool {
        get { d.bool(forKey: K.showMenuBarIcon) }
        set { publishedSet(newValue, K.showMenuBarIcon) }
    }

    /// With `LSUIElement` and no menu-bar item there is no way to reach or quit
    /// the app, while it keeps controlling the fans. Never allow both to be off.
    /// Returns true if it had to intervene, so the UI can explain itself.
    @discardableResult
    public func ensureReachable() -> Bool {
        guard !showMenuBarIcon && !showDockIcon else { return false }
        showMenuBarIcon = true
        return true
    }

    /// Not routed through `publishedSet`: casting a stored value back to an
    /// Optional generic makes the "did it change" comparison unreliable, and a
    /// missed publish here would leave the panel showing a stale profile name.
    public var activePresetID: String? {
        get { d.string(forKey: K.activePreset) }
        set {
            guard d.string(forKey: K.activePreset) != newValue else { return }
            objectWillChange.send()
            d.set(newValue, forKey: K.activePreset)
        }
    }

    // MARK: Temperature formatting

    public func formatTemperature(_ celsius: Double) -> String {
        let v = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        let unit = fahrenheit ? "°F" : "°C"
        return String(format: preciseTemperature ? "%.1f%@" : "%.0f%@", v, unit)
    }

    // MARK: Persistence of modes and presets

    public func saveModes(_ modes: [Int: FanMode]) {
        let byString = Dictionary(uniqueKeysWithValues: modes.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(byString) { d.set(data, forKey: K.modes) }
    }

    public func loadModes() -> [Int: FanMode] {
        guard let data = d.data(forKey: K.modes),
              let byString = try? JSONDecoder().decode([String: FanMode].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: byString.compactMap { k, v in
            Int(k).map { ($0, v) }
        })
    }

    public func saveCustomPresets(_ presets: [Preset]) {
        objectWillChange.send()
        if let data = try? JSONEncoder().encode(presets) { d.set(data, forKey: K.presets) }
    }

    public func loadCustomPresets() -> [Preset] {
        guard let data = d.data(forKey: K.presets),
              let p = try? JSONDecoder().decode([Preset].self, from: data) else { return [] }
        return p
    }
}
