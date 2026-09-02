import SwiftUI
import ServiceManagement
import FanControlKit

struct PreferencesView: View {
    @EnvironmentObject var engine: FanEngine
    @EnvironmentObject var settings: AppSettings

    // Must NOT be initialised here. A @State default value is evaluated every
    // time the view is constructed, and SwiftUI constructs the Settings scene's
    // content on every App body re-evaluation — several times a second once the
    // engine is publishing. `SMAppService.status` is a synchronous XPC call to
    // smd, so doing it in the initialiser pegged the main thread at ~50% CPU and
    // made the whole app unresponsive. Read it on appear instead.
    @State private var loginStatus: SMAppService.Status?
    @State private var loginError: String?

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            menubar.tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            helper.tabItem  { Label("Helper", systemImage: "lock.shield") }
        }
        .frame(width: 480, height: 320)
    }

    private var general: some View {
        Form {
            Toggle("Show temperatures in Fahrenheit", isOn: bind(\.fahrenheit))
            Toggle("Show one decimal place", isOn: bind(\.preciseTemperature))
            Toggle("Show only sensors that are reporting", isOn: bind(\.showOnlyLiveSensors))
            // The reachability rule is applied here, at the point of user
            // intent, rather than inside the model setters — those are also
            // driven by SwiftUI's own scene updates.
            Toggle("Show icon in menu bar", isOn: Binding(
                get: { settings.showMenuBarIcon },
                set: { on in
                    settings.showMenuBarIcon = on
                    if !on && !settings.showDockIcon { settings.showDockIcon = true }
                    NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
                }))
            Toggle("Show icon in Dock", isOn: Binding(
                get: { settings.showDockIcon },
                set: { on in
                    settings.showDockIcon = on
                    if !on && !settings.showMenuBarIcon { settings.showMenuBarIcon = true }
                    NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
                }))
            Label("At least one of these stays on, so the app is always reachable.",
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                // The system's own record is the source of truth. A stored bool
                // drifts the moment the item is removed in System Settings.
                Toggle("Launch at login", isOn: Binding(
                    get: { loginStatus == .enabled },
                    set: setLaunchAtLogin))
                    .disabled(loginStatus == nil)
                if loginStatus == .requiresApproval {
                    Button("Approve in System Settings…") {
                        SMAppService.openSystemSettingsLoginItems()
                    }.font(.callout)
                }
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Picker("Update every", selection: bind(\.pollInterval)) {
                Text("1 second").tag(1.0)
                Text("2 seconds").tag(2.0)
                Text("5 seconds").tag(5.0)
            }
            .onChange(of: settings.pollInterval) { _ in engine.start() }
        }
        .formStyle(.grouped).padding()
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private var menubar: some View {
        Form {
            Picker("Temperature", selection: bind(\.menubarSensorID)) {
                Text("None").tag("")
                ForEach(AggregateSensor.all) { Text($0.label).tag($0.id) }
            }
            Picker("Fan speed", selection: bind(\.menubarFanIndex)) {
                Text("None").tag(-1)
                ForEach(engine.fans) { Text($0.name).tag($0.index) }
            }
            Toggle("Stack on two lines", isOn: bind(\.menubarTwoLines))
        }
        .formStyle(.grouped).padding()
    }

    private var helper: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch engine.helperStatus {
            case .ready:
                Label("Helper installed — fan control is available",
                      systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            case .notInstalled:
                Label("Helper not installed — sensors are read-only",
                      systemImage: "xmark.seal.fill").foregroundStyle(.orange)
            case .notPrivileged:
                Label("Helper is installed but not privileged",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text("""
            Reading sensors needs no special permission. Changing a fan speed \
            writes to the System Management Controller, which requires root, so \
            that one operation runs in a small separate helper binary.

            The helper only accepts a fan number and an RPM value, clamped to the \
            fan's own hardware limits. It cannot be used to write arbitrary SMC keys.
            """)
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Text("Install with:").font(.callout.weight(.medium))
            Text("sudo \(installScriptPath)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            Spacer()
        }
        .padding()
    }

    private var installScriptPath: String {
        Bundle.main.path(forResource: "install-helper", ofType: "sh") ?? "install-helper.sh"
    }

    private func bind<T>(_ kp: ReferenceWritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: kp] }, set: { settings[keyPath: kp] = $0 })
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            on ? try SMAppService.mainApp.register()
               : try SMAppService.mainApp.unregister()
            loginError = nil
        } catch {
            // Surfaced, not swallowed: the previous version logged this to
            // NSLog, so a failure left the toggle showing "on" with nothing
            // registered and no way for the user to tell.
            let ns = error as NSError
            loginError = "Couldn't \(on ? "enable" : "disable") launch at login: "
                       + "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
        }
        // Re-read unconditionally so the toggle can never disagree with the system.
        loginStatus = SMAppService.mainApp.status
    }
}
