import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var store: ConfigStore
    @State private var showRoleConfirm = false
    @State private var launchAtLoginError: String?

    private var isMain: Bool { store.config.role == "main" }
    private var switchLabel: String {
        isMain ? "Switch to Backup Mac" : "Switch to Main Mac"
    }
    private var switchRole: String { isMain ? "backup" : "main" }

    var body: some View {
        Form {
            Section("Role") {
                HStack {
                    Label(isMain ? "Main Mac (Sender)" : "Backup Mac (Receiver)",
                          systemImage: isMain ? "arrow.up.circle" : "arrow.down.circle")
                    Spacer()
                    Button(switchLabel) { showRoleConfirm = true }
                        .buttonStyle(.bordered)
                        .tint(isMain ? .orange : .blue)
                }
            }

            Section("Identity") {
                HStack {
                    Text("Username")
                    Spacer()
                    TextField("Username", text: Binding(
                        get: { store.config.username },
                        set: { store.config.username = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .multilineTextAlignment(.trailing)
                }
            }

            if isMain {
                Section("Source") {
                    HStack {
                        Text(store.config.sourceFolder.isEmpty
                             ? "No folder selected"
                             : shortenPath(store.config.sourceFolder))
                            .foregroundColor(store.config.sourceFolder.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { pickFolder(forSource: true) }
                            .buttonStyle(.bordered)
                    }
                }

                Section("Destination") {
                    HStack {
                        Text("IP Address")
                        Spacer()
                        TextField("e.g. 192.168.1.x", text: Binding(
                            get: { store.config.destinationIP },
                            set: { store.config.destinationIP = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text(store.config.destinationFolder.isEmpty
                             ? "No folder selected"
                             : shortenPath(store.config.destinationFolder))
                            .foregroundColor(store.config.destinationFolder.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { pickFolder(forSource: false) }
                            .buttonStyle(.bordered)
                    }
                }
            }

            Section("Options") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { store.config.launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let err = launchAtLoginError {
                    Text(err).font(.caption).foregroundColor(.red)
                }
                Toggle("Notify on Complete", isOn: Binding(
                    get: { store.config.notifyOnComplete },
                    set: { store.config.notifyOnComplete = $0 }
                ))
            }

            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion()).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .confirmationDialog(
            "Switch role to \(switchRole == "backup" ? "Backup Mac" : "Main Mac")?",
            isPresented: $showRoleConfirm,
            titleVisibility: .visible
        ) {
            Button("Switch to \(switchRole == "backup" ? "Backup Mac" : "Main Mac")", role: .destructive) {
                store.setRole(switchRole)
                // Rebuild the popover UI on the next run loop tick
                DispatchQueue.main.async {
                    (NSApp.delegate as? AppDelegate)?.rebuildPopover()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app will switch roles immediately. All settings are preserved.")
        }
    }

    private func pickFolder(forSource: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = forSource ? "Select Source" : "Select Destination"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if forSource {
                store.config.sourceFolder = url.path
            } else {
                store.config.destinationFolder = url.path
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            store.config.launchAtLogin = enabled
        } catch {
            launchAtLoginError = error.localizedDescription
        }
    }

    private func shortenPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
