import SwiftUI
import FanControlKit

/// The thing that actually sits in the menu bar row.
struct MenuBarLabel: View {
    @EnvironmentObject var engine: FanEngine
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    private var temp: String? {
        guard let v = engine.temperature(forSensorID: settings.menubarSensorID) else { return nil }
        return settings.formatTemperature(v)
    }

    private var rpm: String? {
        let i = settings.menubarFanIndex
        guard i >= 0, let fan = engine.fans.first(where: { $0.index == i }) else { return nil }
        return String(format: "%.0f", fan.currentRPM)
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "fanblades.fill")
            if settings.menubarTwoLines, temp != nil, rpm != nil {
                VStack(alignment: .leading, spacing: -2) {
                    Text(temp!).font(.system(size: 9, weight: .medium))
                    Text("\(rpm!)").font(.system(size: 9, weight: .medium))
                }
            } else {
                let parts = [temp, rpm.map { "\($0) rpm" }].compactMap { $0 }
                if !parts.isEmpty {
                    Text(parts.joined(separator: "  "))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }
            }
        }
        .onAppear {
            // Show the main window the first time the app is ever run, the way
            // a menu-bar utility should announce itself. Afterwards it stays
            // quiet in the menu bar until asked for.
            guard !UserDefaults.standard.bool(forKey: "HasLaunchedBefore") else { return }
            UserDefaults.standard.set(true, forKey: "HasLaunchedBefore")
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
    }
}
