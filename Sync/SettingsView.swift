import SwiftUI
import AppKit
import ServiceManagement

private let darkBg = Color(red: 0.12, green: 0.12, blue: 0.12)
private let sectionHeaderColor = Color(white: 0.45)
private let labelColor = Color(white: 0.55)
private let popoverWidth: CGFloat = 360

struct SettingsView: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var bonjourBrowser = BonjourBrowser.shared
    @ObservedObject private var advertiser  = BonjourAdvertiser.shared
    // Spec §5: callback to return to main dropdown view
    var onBack: () -> Void = {}

    private enum SSHConnectionState { case checking, connected, notConnected, failed }

    @State private var showRoleConfirm = false
    @State private var showResetConnectionConfirm = false
    @State private var sshConnectionState: SSHConnectionState = .checking
    @State private var launchAtLoginError: String?
    @State private var localDiscoveryMode = "automatic"

    private var isMain: Bool { store.config.role == "main" }
    private var switchLabel: String { isMain ? "Switch to BACKUP" : "Switch to MAIN" }
    private var switchRole: String  { isMain ? "backup" : "main" }
    private var isAutomatic: Bool   { localDiscoveryMode == "automatic" }

    // Section disclosure helpers for Main Settings
    private func toggleConnectionSection() {
        if store.config.mainSettingsShowConnection {
            store.config.mainSettingsShowConnection = false
        } else {
            store.config.mainSettingsShowConnection = true
            store.config.mainSettingsShowBehaviour = false
        }
    }

    private func toggleBehaviourSection() {
        if store.config.mainSettingsShowBehaviour {
            store.config.mainSettingsShowBehaviour = false
        } else {
            store.config.mainSettingsShowBehaviour = true
            store.config.mainSettingsShowConnection = false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Spec §5: back arrow returns to main dropdown view
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()
                // Phantom spacer so "Settings" is visually centred
                Color.clear.frame(width: 60, height: 1)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(darkBg)

            Divider()

            if showRoleConfirm {
                InlineConfirm(
                    title: isMain ? "Switch to BACKUP?" : "Switch to MAIN?",
                    message: "The app will restart in the new role.",
                    confirmLabel: "Switch",
                    confirmColor: .orange,
                    onCancel: { showRoleConfirm = false },
                    onConfirm: {
                        showRoleConfirm = false
                        let targetRole = switchRole
                        let currentRole = store.config.role

                        Task { @MainActor in
                            // Handle Bonjour services during role switch
                            if currentRole == "backup" && targetRole == "main" {
                                // Backup → Main: Stop advertising first
                                BonjourAdvertiser.shared.stop()
                                // Wait for advertiser to stop completely
                                while BonjourAdvertiser.shared.state != .idle {
                                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                                }
                            }
                            // Browser start/stop handled by rebuildPopover() → updateBonjourBrowser()

                            store.setRole(targetRole)

                            let delegate = NSApp.delegate as? AppDelegate
                            delegate?.rebuildPopover()
                            if targetRole == "backup" {
                                delegate?.checkRemoteLoginIfNeeded()
                                delegate?.ensureSyncFolder()
                            }
                        }
                    }
                )
            } else if showResetConnectionConfirm {
                InlineConfirm(
                    title: "Reset Secure Connection?",
                    message: "You will need to set up the connection again.",
                    confirmLabel: "Reset",
                    confirmColor: .red,
                    onCancel: { showResetConnectionConfirm = false },
                    onConfirm: {
                        showResetConnectionConfirm = false
                        resetSSHKeys()
                    }
                )
            } else {
            VStack(alignment: .leading, spacing: 0) {
                if isMain {
                    // Main Settings - Collapsible sections

                    // Section 1: Connection
                    Button {
                        toggleConnectionSection()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: store.config.mainSettingsShowConnection ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color(white: 0.4))
                                .frame(width: 12)
                            Text("Connection")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.45))
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)

                    if store.config.mainSettingsShowConnection {
                        connectionSectionContent
                    }

                    Divider()

                    // Section 2: Behaviour
                    Button {
                        toggleBehaviourSection()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: store.config.mainSettingsShowBehaviour ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color(white: 0.4))
                                .frame(width: 12)
                            Text("Behaviour")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.45))
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)

                    if store.config.mainSettingsShowBehaviour {
                        behaviourSectionContent
                    }

                    Divider()
                } else {
                    // Backup Settings - No scrolling
                    backupSettingsContent
                }

                // Always visible ABOUT footer
                sectionHeader("About")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Version")
                            .font(.system(size: 12))
                            .foregroundColor(labelColor)
                        Spacer()
                        Text(appVersion())
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("© RememberLive 2026")
                            .font(.system(size: 12))
                            .foregroundColor(labelColor)
                        Text("Designed and Programmed by Remember Chaitezvi")
                            .font(.system(size: 12))
                            .foregroundColor(labelColor)
                        Text("rememberlive.africa")
                            .font(.system(size: 12))
                            .foregroundColor(labelColor)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            } // end else
        }
        .frame(width: popoverWidth)
        .background(darkBg)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .onAppear {
            // Initialize local discovery mode from store — defer off layout pass
            DispatchQueue.main.async {
                localDiscoveryMode = store.config.discoveryMode
            }
            if !store.config.username.isEmpty && !store.config.destinationIP.isEmpty {
                runLiveSSHTest()
            }
        }
        // onAppear only fires when SettingsView enters the hierarchy (gear tap while popover open).
        // willShowNotification fires every time the popover opens, catching the return-from-wizard case
        // where the popover was closed by the wizard and then reopened by the user.
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in
            if !store.config.username.isEmpty && !store.config.destinationIP.isEmpty {
                runLiveSSHTest()
            }
        }
        .onChange(of: store.config.destinationIP) { _ in
            Task { @MainActor in
                sshConnectionState = .notConnected
            }
        }
        .onChange(of: store.config.username) { _ in
            Task { @MainActor in
                sshConnectionState = .notConnected
            }
        }
        .onChange(of: localDiscoveryMode) { _ in
            Task { @MainActor in
                store.config.discoveryMode = localDiscoveryMode
                AppDelegate.shared?.updateBonjourAdvertiser()
                AppDelegate.shared?.updateBonjourBrowser()
            }
        }
        .onChange(of: store.config.autoSyncEnabled) { enabled in
            if enabled {
                SyncEngine.shared.startAutoSync()
            } else {
                SyncEngine.shared.stopAutoSync()
            }
        }
        .onChange(of: store.config.autoSyncInterval) { _ in
            if store.config.autoSyncEnabled {
                let interval: TimeInterval = store.config.autoSyncInterval == 0 ? 30 : TimeInterval(store.config.autoSyncInterval * 60)
                SyncEngine.shared.startAutoSync(delay: interval)
            }
        }
        .onChange(of: store.config.pushSyncEnabled) { enabled in
            if enabled {
                if !store.config.sourceFolder.isEmpty {
                    FSEventsWatcher.shared.start(path: store.config.sourceFolder, debounceSeconds: store.config.pushSyncDebounce)
                }
            } else {
                FSEventsWatcher.shared.stop()
            }
        }
        .onChange(of: store.config.pushSyncDebounce) { _ in
            if store.config.pushSyncEnabled && !store.config.sourceFolder.isEmpty {
                FSEventsWatcher.shared.start(path: store.config.sourceFolder, debounceSeconds: store.config.pushSyncDebounce)
            }
        }
    }

    // MARK: - Discovered Backup Macs list (Main + Automatic)

    @ViewBuilder private var discoveredBackupsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .failed(let reason) = bonjourBrowser.state {
                Text("Bonjour error: \(reason)")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            } else if bonjourBrowser.services.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching for Backup Macs...")
                        .font(.system(size: 12))
                        .foregroundColor(labelColor)
                }
                .padding(.vertical, 2)
            } else {
                ForEach(bonjourBrowser.services) { service in
                    Button {
                        if store.config.destinationIP != service.resolvedIP
                            || store.config.backupHostname != service.hostname {
                            store.config.destinationIP   = service.resolvedIP
                            store.config.backupHostname  = service.hostname
                            store.config.sshKeysConfigured = false
                            // Save for auto-reconnect on subsequent discoveries
                            store.config.lastBackupDiscoveryName = service.id
                            store.config.lastBackupIP = service.resolvedIP
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: service.resolvedIP == store.config.destinationIP
                                  ? "largecircle.fill.circle"
                                  : "circle")
                                .font(.system(size: 12))
                                .foregroundColor(service.resolvedIP == store.config.destinationIP
                                                 ? .blue
                                                 : Color(white: 0.45))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(service.hostname)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                                Text(service.resolvedIP)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(labelColor)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Bonjour status (Backup + Automatic)

    private var bonjourDotColor: Color {
        switch advertiser.state {
        case .idle:        return Color(white: 0.55)
        case .advertising: return .green
        case .failed:      return .red
        }
    }

    private var bonjourLabel: String {
        switch advertiser.state {
        case .idle:                  return "Starting..."
        case .advertising(let name): return "Advertising as \"\(name)\""
        case .failed(let reason):    return "Bonjour error: \(reason)"
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(sectionHeaderColor)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 5)
    }

    private func pickFolder(forSource: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = forSource ? "Select Source" : "Select Destination"

        // Ensure panel appears on top
        NSApp.activate(ignoringOtherApps: true)
        panel.level = .floating
        panel.orderFrontRegardless()

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        if forSource {
            store.config.sourceFolder = url.path
        } else {
            store.config.destinationFolder = url.path
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
            Task { @MainActor in
                ConfigStore.shared.config.launchAtLogin = enabled
            }
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

    // MARK: - Main Settings Section Content

    @ViewBuilder private var connectionSectionContent: some View {
        Divider()

        sectionHeader("Role")
        VStack(spacing: 8) {
            HStack {
                Text("MAIN")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                Spacer()
                Button(switchLabel) { showRoleConfirm = true }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                    .tint(.blue)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)

        Divider()

        sectionHeader("Discovery")
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $localDiscoveryMode) {
                Text("Automatic").tag("automatic")
                Text("Manual").tag("manual")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accentColor(.blue)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)

        Divider()

        sectionHeader("Identity")
        VStack(spacing: 8) {
            HStack {
                Text("BACKUP Username")
                    .font(.system(size: 12))
                    .foregroundColor(labelColor)
                Spacer()
                TextField("Username", text: Binding(
                    get: { store.config.username },
                    set: {
                        store.config.username = $0
                        store.config.sshKeysConfigured = false
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)

        Divider()

        sectionHeader("Source")
        VStack(spacing: 8) {
            HStack {
                Text(store.config.sourceFolder.isEmpty
                     ? "No folder selected"
                     : shortenPath(store.config.sourceFolder))
                    .font(.system(size: 12))
                    .foregroundColor(store.config.sourceFolder.isEmpty ? labelColor : .white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { pickFolder(forSource: true) }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                    .tint(.blue)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)

        Divider()

        sectionHeader("Destination")
        if isAutomatic {
            discoveredBackupsList
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        } else {
            VStack(spacing: 8) {
                HStack {
                    Text("BACKUP IP")
                        .font(.system(size: 12))
                        .foregroundColor(labelColor)
                    Spacer()
                    TextField("e.g. 192.168.1.x", text: Binding(
                        get: { store.config.destinationIP },
                        set: {
                            store.config.destinationIP = $0
                            store.config.sshKeysConfigured = false
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .multilineTextAlignment(.trailing)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }

        if !store.config.username.isEmpty && !store.config.destinationIP.isEmpty {
            Divider()

            sectionHeader("Secure Connection")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(sshStatusDotColor)
                        .frame(width: 7, height: 7)
                    Text(sshStatusLabel)
                        .font(.system(size: 12))
                        .foregroundColor(sshStatusDotColor)
                }

                switch sshConnectionState {
                case .checking:
                    Button("Checking...") {}
                        .buttonStyle(.borderedProminent)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                        .disabled(true)
                case .connected:
                    Button("Reset Connection") {
                        showResetConnectionConfirm = true
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                case .notConnected, .failed:
                    Button("Set Up Secure Connection") {
                        NSApp.keyWindow?.close()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            AppDelegate.shared?.startSSHKeySetup()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder private var behaviourSectionContent: some View {
        Divider()

        sectionHeader("Auto Sync")
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Auto Sync", isOn: $store.config.autoSyncEnabled)
                .font(.system(size: 12))
                .foregroundColor(.white)
            if store.config.autoSyncEnabled {
                HStack {
                    Text("Check every")
                        .font(.system(size: 12))
                        .foregroundColor(labelColor)
                    Spacer()
                    Picker("", selection: $store.config.autoSyncInterval) {
                        Text("30s").tag(0)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("1 hour").tag(60)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 90)
                }
            }
            Toggle("Push Sync", isOn: $store.config.pushSyncEnabled)
                .font(.system(size: 12))
                .foregroundColor(.white)
            if store.config.pushSyncEnabled {
                HStack {
                    Text("Debounce")
                        .font(.system(size: 12))
                        .foregroundColor(labelColor)
                    Spacer()
                    Picker("", selection: $store.config.pushSyncDebounce) {
                        Text("5s").tag(5)
                        Text("10s").tag(10)
                        Text("30s").tag(30)
                        Text("1 min").tag(60)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 70)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)

        Divider()

        sectionHeader("Version History")
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Version History", isOn: $store.config.versionHistoryEnabled)
                .font(.system(size: 12))
                .foregroundColor(.white)
            if store.config.versionHistoryEnabled {
                HStack {
                    Text("Keep versions")
                        .font(.system(size: 12))
                        .foregroundColor(labelColor)
                    Spacer()
                    Picker("", selection: $store.config.maxVersionCount) {
                        Text("3").tag(3)
                        Text("5").tag(5)
                        Text("10").tag(10)
                        Text("20").tag(20)
                        Text("Unlimited").tag(0)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)

        Divider()

        sectionHeader("Options")
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Check files before sync", isOn: $store.config.dryRunEnabled)
                .font(.system(size: 12))
                .foregroundColor(.white)
            Toggle("Launch at Login", isOn: Binding(
                get: { store.config.launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            .font(.system(size: 12))
            .foregroundColor(.white)
            if let err = launchAtLoginError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var backupSettingsContent: some View {
        sectionHeader("Role")
        VStack(spacing: 8) {
            HStack {
                Text("BACKUP")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                Spacer()
                Button(switchLabel) { showRoleConfirm = true }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                    .tint(.blue)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)

        Divider()

        sectionHeader("Discovery")
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $localDiscoveryMode) {
                Text("Automatic").tag("automatic")
                Text("Manual").tag("manual")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accentColor(.blue)

            HStack {
                Text("Network Discovery Name")
                    .font(.system(size: 12))
                    .foregroundColor(labelColor)
                Spacer()
                TextField("Auto", text: Binding(
                    get: {
                        store.config.networkDiscoveryName.isEmpty ?
                        ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "") :
                        store.config.networkDiscoveryName
                    },
                    set: { newValue in
                        store.config.networkDiscoveryName = newValue
                        BonjourAdvertiser.shared.restart()
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .multilineTextAlignment(.trailing)
            }

            if isAutomatic {
                HStack(spacing: 6) {
                    Circle()
                        .fill(bonjourDotColor)
                        .frame(width: 6, height: 6)
                    Text(bonjourLabel)
                        .font(.system(size: 11))
                        .foregroundColor(bonjourDotColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)

        if !isAutomatic {
            Divider()

            sectionHeader("Connection")
            VStack(spacing: 8) {
                HStack {
                    Text("MAIN IP")
                        .font(.system(size: 12))
                        .foregroundColor(labelColor)
                    Spacer()
                    TextField("192.168.x.x", text: $store.config.mainIP)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }

        Divider()

        sectionHeader("Options")
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch at Login", isOn: Binding(
                get: { store.config.launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            .font(.system(size: 12))
            .foregroundColor(.white)
            if let err = launchAtLoginError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - SSH connection helpers

    private var sshStatusDotColor: Color {
        switch sshConnectionState {
        case .checking:     return Color(white: 0.55)
        case .connected:    return .green
        case .notConnected: return Color(white: 0.45)
        case .failed:       return .red
        }
    }

    private var sshStatusLabel: String {
        switch sshConnectionState {
        case .checking:     return "Checking..."
        case .connected:    return "Connected"
        case .notConnected: return "Not set"
        case .failed:       return "Connection check failed — try again"
        }
    }

    private func runLiveSSHTest() {
        let username = store.config.username
        let ip = store.config.destinationIP
        guard !username.isEmpty, !ip.isEmpty else { return }
        // Defer state change off layout pass to avoid recursion
        DispatchQueue.main.async { [self] in
            sshConnectionState = .checking
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=3",
            "-o", "StrictHostKeyChecking=no",
            "\(username)@\(ip)",
            "exit"
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        proc.terminationHandler = { p in
            let ok = p.terminationStatus == 0
            Task { @MainActor in
                if ok { store.config.sshKeysConfigured = true }
                sshConnectionState = ok ? .connected : .notConnected
            }
        }
        DispatchQueue.global(qos: .utility).async {
            do {
                try proc.run()
            } catch {
                NSLog("[Sync] live SSH test launch failed: %@", error.localizedDescription)
                Task { @MainActor in
                    sshConnectionState = .failed
                }
            }
        }
    }

    private func resetSSHKeys() {
        let home = NSHomeDirectory()
        let privKey = (home as NSString).appendingPathComponent(".ssh/id_ed25519")
        let pubKey  = (home as NSString).appendingPathComponent(".ssh/id_ed25519.pub")
        try? FileManager.default.removeItem(atPath: privKey)
        try? FileManager.default.removeItem(atPath: pubKey)
        store.config.sshKeysConfigured           = false
        store.config.sshKeyConfiguredForIP       = ""
        store.config.sshKeyConfiguredForUsername = ""
        runLiveSSHTest()
    }
}
