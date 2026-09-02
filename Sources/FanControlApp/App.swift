import SwiftUI
import AppKit
import FanControlKit

@main
struct FanControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    // Deliberately NOT @StateObject. Observing the engine here makes every
    // published change re-evaluate the App body, which rebuilds the whole scene
    // graph — including the main menu — several times a second and pegs a core.
    // Child views observe it through @EnvironmentObject and re-render on their
    // own. Settings IS observed, because the menu-bar item's `isInserted` needs
    // it, and it only changes on user action.
    private let engine = AppEnvironment.shared.engine
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { settings.showMenuBarIcon },
            set: { settings.showMenuBarIcon = $0 })) {
            MenuBarPanel(history: engine.history)
                .environmentObject(engine)
                .environmentObject(settings)
        } label: {
            MenuBarLabel()
                .environmentObject(engine)
                .environmentObject(settings)
        }
        // `.window` is what allows real UI in the dropdown — gauges, charts,
        // buttons that do not tear the panel down on click. The default `.menu`
        // style can only render plain menu items.
        .menuBarExtraStyle(.window)

        Window("Fan Control", id: "main") {
            MainWindowView()
                .environmentObject(engine)
                .environmentObject(settings)
                .frame(minWidth: 780, minHeight: 460)
        }
        .defaultSize(width: 900, height: 560)

        Settings {
            PreferencesView()
                .environmentObject(engine)
                .environmentObject(settings)
        }
    }
}

/// Holds the engine outside SwiftUI so the delegate can reach it on quit.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()
    let engine: FanEngine

    private init() {
        do {
            engine = try FanEngine()
        } catch {
            // There is no meaningful degraded mode: without the SMC user client
            // the app can neither read a temperature nor move a fan. Say so and
            // exit rather than presenting an empty window that never populates.
            let a = NSAlert()
            a.messageText = "Cannot access the System Management Controller"
            a.informativeText = """
            \(error)

            Fan Control needs the AppleSMC device to read sensors and drive fans.
            """
            a.alertStyle = .critical
            a.runModal()
            exit(1)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        installSignalHandlers()
        Task { @MainActor in
            let s = AppSettings.shared
            s.ensureReachable()
            NSApp.setActivationPolicy(s.showDockIcon ? .regular : .accessory)
            AppEnvironment.shared.engine.start()
        }
    }

    /// Release the fans on signal-driven termination.
    ///
    /// `applicationWillTerminate` covers Quit, but not `pkill`, a logout that
    /// escalates, or anything else that arrives as a signal — AppKit does not
    /// run the delegate for those. Without this the app can die while fans are
    /// pinned and leave them there: the SMC's manual mode does not reliably
    /// lapse on its own (it does at mid-range targets, but has been observed
    /// holding indefinitely at maximum RPM on a hot machine).
    ///
    /// SIGKILL still cannot be caught. `FanEngine` compensates on the next
    /// launch by releasing any fan the hardware reports as manual while its
    /// configured mode is auto.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)      // stop the default terminate-immediately
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated {
                    AppEnvironment.shared.engine.restoreAutoOnExit()
                }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    /// A menu-bar app must outlive its windows.
    ///
    /// The dropdown panel is a real window, so when it closes the app can be
    /// left with zero windows. The default AppKit behaviour then quits the
    /// process — which for this app means silently dropping fan control and
    /// disappearing from the menu bar a few seconds after the panel is used.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ n: Notification) {
        // Never leave the machine with fans pinned by a process that has exited.
        MainActor.assumeIsolated {
            AppEnvironment.shared.engine.restoreAutoOnExit()
        }
    }
}
