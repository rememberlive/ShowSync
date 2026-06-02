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
    @ObservedObject private var engine = SyncEngine.shared
    @ObservedObject private var interfaceManager = NetworkInterfaceManager.shared
    // Spec §5: callback to return to main dropdown view
    var onBack: () -> Void = {}

    private enum SSHConnectionState { case checking, connected, notConnected, failed }

    @State private var showRoleConfirm = false
    @State private var showResetConnectionConfirm = false
    @State private var showResetToDefaultsConfirm = false
    @State private var sshConnectionState: SSHConnectionState = .checking
    @State private var launchAtLoginError: String?
    @State private var localDiscoveryMode = "automatic"
    @State private var isEditingDiscoveryName = false
    @State private var editingDiscoveryName = ""
    @State private var isEditingUsername = false
    @State private var editingUsername = ""
    @State private var isEditingIP = false
    @State private var editingIP = ""
    @State private var isEditingBackupName = false
    @State private var editingBackupName = ""
    @State private var renameState: RenameState = .idle
    @State private var renameGeneration: Int = 0
    @State private var destinationCheckState: DestinationCheckState = .idle
    @State private var hasConfirmedDestinationThisConnection = false
    @State private var manualModeFreeSpace: Int64 = 0  // Free space read via SSH for manual mode

    // Custom timing option editing state
    @State private var isEditingAutoInterval = false
    @State private var editingAutoInterval = ""
    @State private var isEditingPushDebounce = false
    @State private var editingPushDebounce = ""

    private enum DestinationCheckState: Equatable {
        case idle
        case checking
        case confirmed
        case failed
    }

    private enum RenameState: Equatable {
        case idle
        case pending(oldName: String)
        case sent       // SSH write succeeded, waiting for Bonjour re-advertise
        case failed
    }

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
                                // Backup → Main: Stop advertising and monitoring, clear stale name
                                BonjourAdvertiser.shared.stopAndClearState()
                                ReceiveMonitor.shared.stopMonitoring()  // Also removes volume observers
                                // Wait for advertiser to stop completely
                                while BonjourAdvertiser.shared.state != .idle {
                                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                                }
                                // Register global hotkey for Main role
                                GlobalHotkey.shared.register()
                            } else if currentRole == "main" && targetRole == "backup" {
                                // Main → Backup: Stop global hotkey, start advertising
                                GlobalHotkey.shared.unregister()
                                BonjourAdvertiser.shared.start()
                            }

                            // Reset transient fallback state on any role switch
                            SyncEngine.shared.usingFallback = false

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
            } else if showResetToDefaultsConfirm {
                InlineConfirm(
                    title: "Reset to Defaults?",
                    message: "This will erase all settings, the backup pairing, and sync history, and return Sync to its first-launch state. Your synced files will NOT be deleted. This cannot be undone.",
                    confirmLabel: "Reset",
                    confirmColor: .red,
                    onCancel: { showResetToDefaultsConfirm = false },
                    onConfirm: {
                        showResetToDefaultsConfirm = false
                        performResetToDefaults()
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

                Divider()

                // Reset to Defaults
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        showResetToDefaultsConfirm = true
                    } label: {
                        Text("Reset to Defaults")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
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
                hasConfirmedDestinationThisConnection = false
                destinationCheckState = .idle
            }
        }
        .onChange(of: store.config.username) { _ in
            Task { @MainActor in
                sshConnectionState = .notConnected
                hasConfirmedDestinationThisConnection = false
                destinationCheckState = .idle
            }
        }
        .onChange(of: sshConnectionState) { newState in
            // Manual mode: confirm destination on reconnect (transition INTO .connected)
            if newState == .connected && !isAutomatic && !hasConfirmedDestinationThisConnection {
                hasConfirmedDestinationThisConnection = true
                confirmBackupDestination()
            }
            // Reset flag when connection drops
            if newState == .notConnected || newState == .failed {
                hasConfirmedDestinationThisConnection = false
                destinationCheckState = .idle
            }
        }
        .onChange(of: localDiscoveryMode) { _ in
            Task { @MainActor in
                store.config.discoveryMode = localDiscoveryMode
                // Reset transient display state for fresh start in new mode
                SyncEngine.shared.usingFallback = false
                manualModeFreeSpace = 0
                destinationCheckState = .idle
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
        .onChange(of: store.config.preferredInterface) { _ in
            if isMain && isAutomatic {
                BonjourBrowser.shared.restart()
            }
        }
        .onChange(of: store.config.appPresence) { _ in
            AppDelegate.shared?.applyAppPresence()
        }
        .onChange(of: bonjourBrowser.services) { services in
            // Detect remote rename confirmation: same IP, new name
            let isWaitingForRename = { () -> Bool in
                if case .pending = renameState { return true }
                if case .sent = renameState { return true }
                return false
            }()
            guard isWaitingForRename else { return }
            let targetIP = store.config.destinationIP
            if let match = services.first(where: { $0.resolvedIP == targetIP }) {
                handleRenameConfirmed(newName: match.id)
            }
        }
    }

    // MARK: - Discovered Backup Macs list (Main + Automatic)

    @ViewBuilder private var discoveredBackupsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .failed = bonjourBrowser.state {
                Text("Network discovery unavailable")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            } else if bonjourBrowser.services.isEmpty && store.config.destinationIP.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching for Backup Macs...")
                        .font(.system(size: 12))
                        .foregroundColor(labelColor)
                }
                .padding(.vertical, 2)
            } else if bonjourBrowser.services.isEmpty {
                // Fallback: live discovery empty but a saved connection exists — show it
                let savedName = store.config.lastBackupDiscoveryName.isEmpty
                    ? store.config.backupHostname
                    : store.config.lastBackupDiscoveryName
                HStack(spacing: 8) {
                    Image(systemName: "largecircle.fill.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(savedName.isEmpty ? "Saved Backup" : savedName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                        Text(store.config.destinationIP)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(labelColor)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            } else {
                ForEach(bonjourBrowser.services) { service in
                    Button {
                        // Guard: only allow selection if reachable on selected interface
                        guard service.isReachableOnSelectedInterface else { return }
                        if store.config.destinationIP != service.resolvedIP
                            || store.config.backupHostname != service.hostname {
                            store.config.destinationIP   = service.resolvedIP
                            store.config.backupHostname  = service.hostname
                            store.config.backupDestination = service.destinationPath  // Intended path for display
                            store.config.sshKeysConfigured = false
                            // Save for auto-reconnect on subsequent discoveries
                            store.config.lastBackupDiscoveryName = service.id
                            store.config.lastBackupIP = service.resolvedIP
                        }
                        // Set fallback state from discovered service
                        SyncEngine.shared.usingFallback = service.isUsingFallback
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
                                Text(service.id)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(service.isReachableOnSelectedInterface ? .white : .red)
                                if service.isReachableOnSelectedInterface {
                                    Text("\(service.resolvedIP) · \(formatBytes(service.freeSpaceBytes)) free")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(labelColor)
                                } else {
                                    Text("On another network – wrong port?")
                                        .font(.system(size: 10))
                                        .foregroundColor(.red)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!service.isReachableOnSelectedInterface)
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
        case .failed:                return "Network discovery unavailable"
        }
    }

    private var displayedDiscoveryName: String {
        if !advertiser.confirmedName.isEmpty { return advertiser.confirmedName }
        let customName = store.config.networkDiscoveryName
        if !customName.isEmpty { return customName }
        return ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
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

    private func pickDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Select Destination"
        NSApp.activate(ignoringOtherApps: true)
        panel.level = .floating
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        // Block TCC-protected folders: rsync-over-SSH can't write to these even though
        // the local GUI app can (NSOpenPanel grants TCC access that SSH won't have)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tccProtected = ["Documents", "Desktop", "Downloads"].map { "\(home)/\($0)" }
        let chosenPath = url.path
        if tccProtected.contains(where: { chosenPath == $0 || chosenPath.hasPrefix("\($0)/") }) {
            let alert = NSAlert()
            alert.messageText = "This folder can't receive files over the network"
            alert.informativeText = "Documents, Desktop, and Downloads are protected by macOS. Please choose another folder, like a folder in your home directory or an external drive."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Write-test: verify folder is writable before accepting
        let testFile = url.appendingPathComponent(".sync_writetest")
        do {
            try Data().write(to: testFile)
            try FileManager.default.removeItem(at: testFile)
            store.config.destinationFolder = url.path
            ReceiveMonitor.shared.validateDestination()  // Updates usingFallback state
            BonjourAdvertiser.shared.updateTXTRecord()   // Fast TXT update (no restart)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Can't back up to this folder"
            alert.informativeText = "It may be protected by macOS, read-only, or disconnected. Choose a folder in your home folder or a writable drive."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
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

    private func setGlobalHotkeyEnabled(_ enabled: Bool) {
        store.config.globalHotkeyEnabled = enabled
        if enabled {
            GlobalHotkey.shared.register()
        } else {
            GlobalHotkey.shared.unregister()
        }
    }

    private func performResetToDefaults() {
        // 1. Unregister Launch at Login if enabled (must happen before wipe)
        if store.config.launchAtLogin {
            try? SMAppService.mainApp.unregister()
        }

        // 2. Stop Bonjour services
        BonjourAdvertiser.shared.stopAndClearState()
        BonjourBrowser.shared.stop()

        // 3. Cancel pending config save (prevents writing after wipe)
        ConfigStore.shared.cancelPendingSave()

        // 4. Delete entire App Support/Sync directory
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let syncDir = appSupport.appendingPathComponent("Sync", isDirectory: true)
        try? fm.removeItem(at: syncDir)

        // 5. Clear UserDefaults key
        UserDefaults.standard.removeObject(forKey: "syncRole")

        // 6. Relaunch app
        relaunchApp()
    }

    private func relaunchApp() {
        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true

        // Launch new instance, then terminate this one
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "?" }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 100 { return String(format: "%.0f GB", gb) }
        if gb >= 10  { return String(format: "%.1f GB", gb) }
        return String(format: "%.2f GB", gb)
    }

    // MARK: - Remote rename helpers

    private var isValidRenameInput: Bool {
        let t = editingBackupName.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.utf8.count <= 63 else { return false }
        for char in t.unicodeScalars { if char.value < 32 || char == "/" { return false } }
        return true
    }

    private func sendRemoteRename() {
        let newName = editingBackupName.trimmingCharacters(in: .whitespaces)
        guard isValidRenameInput else { return }
        let oldName = store.config.lastBackupDiscoveryName
        isEditingBackupName = false
        renameGeneration += 1
        let thisGen = renameGeneration
        renameState = .pending(oldName: oldName)

        let username = store.config.username
        let ip = store.config.destinationIP
        let remotePath = store.config.backupDestination.isEmpty ? "~/Sync" : store.config.backupDestination
        let escaped = newName.replacingOccurrences(of: "'", with: "'\\''")

        let destFile = "\(remotePath)/.sync_rename_request"
        let safeDestFile: String
        if destFile.hasPrefix("~/") {
            let remainder = String(destFile.dropFirst(2))
            let escapedRemainder = remainder
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "`", with: "\\`")
            safeDestFile = "\"$HOME/\(escapedRemainder)\""
        } else {
            let escapedPath = destFile
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "`", with: "\\`")
            safeDestFile = "\"\(escapedPath)\""
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3",
                          "\(username)@\(ip)", "echo -n '\(escaped)' > \(safeDestFile)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { p in
            Task { @MainActor in
                guard renameGeneration == thisGen else { return }
                if p.terminationStatus == 0 {
                    // SSH write succeeded — wait for Bonjour re-advertise
                    renameState = .sent
                } else {
                    // SSH write failed — show error
                    renameState = .failed
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if renameState == .failed && renameGeneration == thisGen { renameState = .idle }
                }
            }
        }
        DispatchQueue.global(qos: .utility).async { try? proc.run() }

        // 30s fallback timeout (Bonjour re-advertise can take ~18s)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard renameGeneration == thisGen else { return }
            // Only fail if still in pending/sent state after 30s
            if case .pending = renameState {
                renameState = .failed
            } else if case .sent = renameState {
                renameState = .idle  // Soft timeout: just clear, name may have updated via onChange
            }
        }
    }

    private func handleRenameConfirmed(newName: String) {
        renameGeneration += 1  // Cancel any pending timeouts
        store.config.lastBackupDiscoveryName = newName
        renameState = .idle
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

        interfacePickerSection

        Divider()

        sectionHeader("Identity")
        VStack(spacing: 8) {
            HStack {
                Text("BACKUP Username")
                    .font(.system(size: 12))
                    .foregroundColor(labelColor)
                Spacer()
                if isEditingUsername {
                    TextField("Username", text: $editingUsername)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                    Button("Save") {
                        let trimmed = editingUsername.trimmingCharacters(in: .whitespaces)
                        store.config.username = trimmed
                        store.config.sshKeysConfigured = false
                        isEditingUsername = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(editingUsername.trimmingCharacters(in: .whitespaces).isEmpty || editingUsername.trimmingCharacters(in: .whitespaces).contains(" ") ? Color(white: 0.4) : .blue)
                    .disabled(editingUsername.trimmingCharacters(in: .whitespaces).isEmpty || editingUsername.trimmingCharacters(in: .whitespaces).contains(" "))
                    Button("Cancel") {
                        isEditingUsername = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))
                } else {
                    Text(store.config.username.isEmpty ? "Not set" : store.config.username)
                        .font(.system(size: 12))
                        .foregroundColor(store.config.username.isEmpty ? labelColor : .white)
                        .lineLimit(1)
                    Button("Edit") {
                        editingUsername = store.config.username
                        isEditingUsername = true
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                    .tint(.blue)
                }
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
                .padding(.bottom, 4)
            // Auto mode: show live destination from TXT record (non-editable)
            if !store.config.destinationIP.isEmpty {
                HStack {
                    Text("FOLDER")
                        .font(.system(size: 11))
                        .foregroundColor(labelColor)
                    Spacer()
                    if engine.usingFallback {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(store.config.backupDestination) (drive unavailable)")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("Syncing to ~/Sync")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                        }
                    } else {
                        Text(store.config.backupDestination.isEmpty ? "~/Sync" : store.config.backupDestination)
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            } else {
                Spacer().frame(height: 8)
            }
        } else {
            VStack(spacing: 8) {
                HStack {
                    Text("BACKUP IP")
                        .font(.system(size: 12))
                        .foregroundColor(labelColor)
                    Spacer()
                    if isEditingIP {
                        TextField("e.g. 192.168.1.x", text: $editingIP)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .multilineTextAlignment(.trailing)
                        Button("Save") {
                            let trimmed = editingIP.trimmingCharacters(in: .whitespaces)
                            store.config.destinationIP = trimmed
                            store.config.sshKeysConfigured = false
                            isEditingIP = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(editingIP.trimmingCharacters(in: .whitespaces).isEmpty ? Color(white: 0.4) : .blue)
                        .disabled(editingIP.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") {
                            isEditingIP = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.5))
                    } else {
                        Text(store.config.destinationIP.isEmpty ? "Not set" : store.config.destinationIP)
                            .font(.system(size: 12))
                            .foregroundColor(store.config.destinationIP.isEmpty ? labelColor : .white)
                            .lineLimit(1)
                        Button("Edit") {
                            editingIP = store.config.destinationIP
                            isEditingIP = true
                        }
                        .buttonStyle(.bordered)
                        .font(.system(size: 11))
                        .tint(.blue)
                    }
                }
                // Manual mode: Confirm Destination button + status
                if !store.config.destinationIP.isEmpty {
                    HStack {
                        Text("FOLDER")
                            .font(.system(size: 11))
                            .foregroundColor(labelColor)
                        Spacer()
                        switch destinationCheckState {
                        case .idle:
                            Button("Confirm Destination") { confirmBackupDestination() }
                                .buttonStyle(.bordered)
                                .font(.system(size: 11))
                                .tint(.blue)
                        case .checking:
                            Text("Checking...")
                                .font(.system(size: 11))
                                .foregroundColor(labelColor)
                        case .confirmed:
                            HStack(spacing: 6) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    if engine.usingFallback {
                                        Text("\(store.config.backupDestination) (drive unavailable)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.orange)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text("Syncing to ~/Sync")
                                            .font(.system(size: 10))
                                            .foregroundColor(.orange)
                                    } else {
                                        Text(store.config.backupDestination.isEmpty ? "~/Sync" : store.config.backupDestination)
                                            .font(.system(size: 11))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        if manualModeFreeSpace > 0 {
                                            Text("\(formatBytes(manualModeFreeSpace)) free")
                                                .font(.system(size: 10))
                                                .foregroundColor(labelColor)
                                        }
                                    }
                                }
                                Button { confirmBackupDestination() } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.blue)
                            }
                        case .failed:
                            HStack(spacing: 6) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    if engine.usingFallback {
                                        Text("\(store.config.backupDestination) (drive unavailable)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.orange)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text("Syncing to ~/Sync")
                                            .font(.system(size: 10))
                                            .foregroundColor(.orange)
                                    } else {
                                        Text(store.config.backupDestination.isEmpty ? "~/Sync" : store.config.backupDestination)
                                            .font(.system(size: 11))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        Text("Couldn't confirm — using last known")
                                            .font(.system(size: 10))
                                            .foregroundColor(labelColor)
                                    }
                                }
                                Button("Retry") { confirmBackupDestination() }
                                    .buttonStyle(.bordered)
                                    .font(.system(size: 10))
                                    .tint(.blue)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }

        // Remote rename section (automatic mode + Backup selected)
        if isAutomatic && !store.config.destinationIP.isEmpty {
            Divider()
            sectionHeader("CHANGE BACKUP NAME")
            VStack(spacing: 8) {
                HStack {
                    if isEditingBackupName {
                        TextField("Name", text: $editingBackupName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .multilineTextAlignment(.trailing)
                        Button("Save") { sendRemoteRename() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(isValidRenameInput ? .blue : Color(white: 0.4))
                            .disabled(!isValidRenameInput)
                        Button("Cancel") { isEditingBackupName = false }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.5))
                    } else {
                        switch renameState {
                        case .idle:
                            Text(store.config.lastBackupDiscoveryName.isEmpty ? "Not set" : store.config.lastBackupDiscoveryName)
                                .font(.system(size: 12))
                                .foregroundColor(store.config.lastBackupDiscoveryName.isEmpty ? labelColor : .white)
                                .lineLimit(1)
                            Spacer()
                            Button("Rename") {
                                editingBackupName = store.config.lastBackupDiscoveryName
                                isEditingBackupName = true
                            }
                            .buttonStyle(.bordered)
                            .font(.system(size: 11))
                            .tint(.blue)
                        case .pending:
                            Text("\(editingBackupName)...")
                                .font(.system(size: 12))
                                .foregroundColor(.yellow)
                                .lineLimit(1)
                            Spacer()
                        case .sent:
                            Text("Rename sent — updating...")
                                .font(.system(size: 12))
                                .foregroundColor(.green)
                                .lineLimit(1)
                            Spacer()
                        case .failed:
                            Text(store.config.lastBackupDiscoveryName.isEmpty ? "Not set" : store.config.lastBackupDiscoveryName)
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Spacer()
                            Text("Rename failed, try again")
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                        }
                    }
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

    @ViewBuilder private var interfacePickerSection: some View {
        sectionHeader("Network Interface")
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(
                get: { store.config.preferredInterface },
                set: { store.config.preferredInterface = $0 }
            )) {
                Text("Automatic").tag("")
                ForEach(interfaceManager.availableInterfaces) { iface in
                    Text(iface.displayLabel).tag(iface.name)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            if interfaceManager.usingFallback {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                    Text("Preferred network unavailable — using automatic")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }

            Text("Controls which network Sync connects over. Does not restrict Bonjour advertising.")
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // Preset sets for timing options
    private static let autoIntervalPresets: Set<Int> = [0, 5, 10, 15, 30, 60]
    private static let pushDebouncePresets: Set<Int> = [5, 10, 30, 60]

    private var isAutoIntervalCustom: Bool {
        !Self.autoIntervalPresets.contains(store.config.autoSyncInterval)
    }

    private var isPushDebounceCustom: Bool {
        !Self.pushDebouncePresets.contains(store.config.pushSyncDebounce)
    }

    private func autoIntervalDisplayText(_ value: Int) -> String {
        if value == 0 { return "30s" }
        if value == 60 { return "1 hour" }
        return "\(value) min"
    }

    private func pushDebounceDisplayText(_ value: Int) -> String {
        if value == 60 { return "1 min" }
        return "\(value)s"
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
                    Picker("", selection: Binding<Int?>(
                        get: { Self.autoIntervalPresets.contains(store.config.autoSyncInterval)
                               ? store.config.autoSyncInterval : nil },
                        set: { if let v = $0 { store.config.autoSyncInterval = v } }
                    )) {
                        Text("").tag(nil as Int?)
                        Text("30s").tag(0 as Int?)
                        Text("5 min").tag(5 as Int?)
                        Text("10 min").tag(10 as Int?)
                        Text("15 min").tag(15 as Int?)
                        Text("30 min").tag(30 as Int?)
                        Text("1 hour").tag(60 as Int?)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }
                HStack {
                    Text("Custom")
                        .font(.system(size: 12))
                        .foregroundColor(labelColor)
                    Spacer()
                    if isAutoIntervalCustom {
                        Text("\(store.config.autoSyncInterval) min")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                        Text("(active)")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.5))
                    }
                    TextField(isAutoIntervalCustom ? "\(store.config.autoSyncInterval)" : "1-360",
                              text: $editingAutoInterval)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                        .multilineTextAlignment(.trailing)
                    Text("min")
                        .font(.system(size: 11))
                        .foregroundColor(labelColor)
                    Button("Apply") {
                        if let val = Int(editingAutoInterval.trimmingCharacters(in: .whitespaces)),
                           val >= 1 && val <= 360 {
                            store.config.autoSyncInterval = val
                            editingAutoInterval = ""
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                    .tint(.blue)
                    .disabled(editingAutoInterval.trimmingCharacters(in: .whitespaces).isEmpty)
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
                    Picker("", selection: Binding<Int?>(
                        get: { Self.pushDebouncePresets.contains(store.config.pushSyncDebounce)
                               ? store.config.pushSyncDebounce : nil },
                        set: { if let v = $0 { store.config.pushSyncDebounce = v } }
                    )) {
                        Text("").tag(nil as Int?)
                        Text("5s").tag(5 as Int?)
                        Text("10s").tag(10 as Int?)
                        Text("30s").tag(30 as Int?)
                        Text("1 min").tag(60 as Int?)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 80)
                }
                HStack {
                    Text("Custom")
                        .font(.system(size: 12))
                        .foregroundColor(labelColor)
                    Spacer()
                    if isPushDebounceCustom {
                        Text("\(store.config.pushSyncDebounce)s")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                        Text("(active)")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.5))
                    }
                    TextField(isPushDebounceCustom ? "\(store.config.pushSyncDebounce)" : "5-300",
                              text: $editingPushDebounce)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                        .multilineTextAlignment(.trailing)
                    Text("sec")
                        .font(.system(size: 11))
                        .foregroundColor(labelColor)
                    Button("Apply") {
                        if let val = Int(editingPushDebounce.trimmingCharacters(in: .whitespaces)),
                           val >= 5 && val <= 300 {
                            store.config.pushSyncDebounce = val
                            editingPushDebounce = ""
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                    .tint(.blue)
                    .disabled(editingPushDebounce.trimmingCharacters(in: .whitespaces).isEmpty)
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
                        Text("15").tag(15)
                        Text("20").tag(20)
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
            Toggle("Global shortcut ⌃⌥⌘S", isOn: Binding(
                get: { store.config.globalHotkeyEnabled },
                set: { setGlobalHotkeyEnabled($0) }
            ))
            .font(.system(size: 12))
            .foregroundColor(.white)
            Text("Triggers Sync Now from anywhere")
                .font(.system(size: 10))
                .foregroundColor(labelColor)
            HStack {
                Text("Show Sync in")
                    .font(.system(size: 12))
                    .foregroundColor(labelColor)
                Spacer()
                Picker("", selection: $store.config.appPresence) {
                    Text("Menu Bar").tag("menubar")
                    Text("Menu Bar & Dock").tag("both")
                }
                .pickerStyle(.menu)
                .frame(width: 140)
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
                if isEditingDiscoveryName {
                    TextField("Name", text: $editingDiscoveryName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                    Button("Save") {
                        let trimmed = editingDiscoveryName.trimmingCharacters(in: .whitespaces)
                        store.config.networkDiscoveryName = trimmed
                        BonjourAdvertiser.shared.restart()
                        isEditingDiscoveryName = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(editingDiscoveryName.trimmingCharacters(in: .whitespaces).isEmpty || editingDiscoveryName.utf8.count > 63 ? Color(white: 0.4) : .blue)
                    .disabled(editingDiscoveryName.trimmingCharacters(in: .whitespaces).isEmpty || editingDiscoveryName.utf8.count > 63)
                    Button("Cancel") {
                        isEditingDiscoveryName = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))
                } else {
                    Text(displayedDiscoveryName)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Button("Edit") {
                        editingDiscoveryName = advertiser.confirmedName.isEmpty
                            ? ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
                            : advertiser.confirmedName
                        isEditingDiscoveryName = true
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                    .tint(.blue)
                }
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

        Divider()

        interfacePickerSection

        Divider()

        sectionHeader("Destination")
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if ReceiveMonitor.shared.usingFallback {
                    Text("\(shortenPath(store.config.destinationFolder)) (drive unavailable)")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(shortenPath(store.config.destinationFolder))
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Change") { pickDestinationFolder() }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                    .tint(.blue)
            }
            if ReceiveMonitor.shared.usingFallback {
                Text("Syncing to ~/Sync until drive returns")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)

        HStack {
            Text("Minimum free space")
                .font(.system(size: 12))
                .foregroundColor(labelColor)
            Spacer()
            Stepper(value: Binding(
                get: { store.config.minFreeSpaceGB },
                set: { store.config.minFreeSpaceGB = max(1, $0) }
            ), in: 1...99) {
                Text("\(store.config.minFreeSpaceGB) GB")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
            }
            .labelsHidden()
            Text("\(store.config.minFreeSpaceGB) GB")
                .font(.system(size: 12))
                .foregroundColor(.white)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        Text("Sync is refused if the drive has less than this free")
            .font(.system(size: 10))
            .foregroundColor(labelColor)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

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
            HStack {
                Text("Show Sync in")
                    .font(.system(size: 12))
                    .foregroundColor(labelColor)
                Spacer()
                Picker("", selection: $store.config.appPresence) {
                    Text("Menu Bar").tag("menubar")
                    Text("Menu Bar & Dock").tag("both")
                }
                .pickerStyle(.menu)
                .frame(width: 140)
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

    private func confirmBackupDestination() {
        let username = store.config.username
        let ip = store.config.destinationIP
        guard !username.isEmpty, !ip.isEmpty else { return }
        destinationCheckState = .checking
        // Read config and free space in one SSH call
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=3",
            "-o", "StrictHostKeyChecking=no",
            "\(username)@\(ip)",
            "cat \"$HOME/Library/Application Support/Sync/config_backup.json\" 2>/dev/null || echo '{}'"
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak store] p in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                guard let store else { return }
                if p.terminationStatus == 0,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dest = json["destinationFolder"] as? String, !dest.isEmpty {
                    // destinationFolder = user's chosen intent (for display)
                    store.config.backupDestination = dest

                    // effectivePath = where files actually go (for sync + free space)
                    let effectivePath = (json["effectivePath"] as? String) ?? dest
                    let isFallback = !effectivePath.isEmpty && effectivePath != dest
                    SyncEngine.shared.usingFallback = isFallback

                    destinationCheckState = .confirmed
                    // Read free space for EFFECTIVE destination (reality, not intent)
                    readManualModeFreeSpace(username: username, ip: ip, remotePath: effectivePath)
                } else {
                    destinationCheckState = .failed
                }
            }
        }
        DispatchQueue.global(qos: .utility).async {
            do {
                try proc.run()
            } catch {
                NSLog("[Sync] destination confirm SSH failed: %@", error.localizedDescription)
                Task { @MainActor in
                    destinationCheckState = .failed
                }
            }
        }
    }

    private func readManualModeFreeSpace(username: String, ip: String, remotePath: String) {
        let escapedPath = remotePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=3",
            "-o", "StrictHostKeyChecking=no",
            "\(username)@\(ip)",
            "df -k \"\(escapedPath)\" 2>/dev/null | awk 'NR==2 {print $4}'"
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { p in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in
                if p.terminationStatus == 0, let kb = Int64(output) {
                    manualModeFreeSpace = kb * 1024  // Convert KB to bytes
                }
            }
        }
        DispatchQueue.global(qos: .utility).async {
            do {
                try proc.run()
            } catch {
                NSLog("[Sync] free space read failed: %@", error.localizedDescription)
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
