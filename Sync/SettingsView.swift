// Copyright © 2026 Remember Chaitezvi. All rights reserved.
// Part of ShowSync — Remember Live.

import SwiftUI
import AppKit
import ServiceManagement
import ShowNetwork

private let darkBg = Color(red: 0.12, green: 0.12, blue: 0.12)
private let sectionHeaderColor = Color(white: 0.45)
private let labelColor = Color(white: 0.55)
private let popoverWidth: CGFloat = 360

// MARK: - Update check (manual "Check for Updates" in Settings → About)

private let updateCheckURL = "https://raw.githubusercontent.com/rememberlive/showsync-updates/refs/heads/main/showsync-version.json"

// Tiny version manifest fetched from updateCheckURL.
private struct AppVersionInfo: Codable {
    let version: String
    let build: String
    let minMacOS: String?
    let url: String
    let notes: String?
}

private enum UpdateState {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String, url: String)
    case failed
}

// Transient UI state for License activation / trial fetch (Settings → License).
private enum ActivationUIState: Equatable {
    case idle
    case activating
    case success
    case failure(String)
    case trialUnavailable
}

struct SettingsView: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var bonjourBrowser = BonjourBrowser.shared
    @ObservedObject private var advertiser  = BonjourAdvertiser.shared
    @ObservedObject private var engine = SyncEngine.shared
    @ObservedObject private var interfaceManager = NetworkInterfaceManager.shared
    @ObservedObject private var pairingService = BonjourPairingService.shared
    @ObservedObject private var connectionStatus = ConnectionStatus.shared
    @ObservedObject private var license = LicenseController.shared
    // Spec §5: callback to return to main dropdown view
    var onBack: () -> Void = {}

    @State private var showRoleConfirm = false
    @State private var showForgetBackupConfirm = false   // Main role: forget paired Backup
    @State private var showForgetMainConfirm = false     // Backup role: forget paired Main
    @State private var showResetToDefaultsConfirm = false
    @State private var launchAtLoginError: String?
    @State private var localDiscoveryMode = "automatic"
    @State private var isEditingDiscoveryName = false
    @State private var editingDiscoveryName = ""
    @State private var isEditingUsername = false
    @State private var editingUsername = ""
    @State private var isEditingDeviceName = false
    @State private var editingDeviceName = ""
    @State private var updateState: UpdateState = .idle  // transient — manual update check (About)
    @State private var showLicense = false               // License section open/closed (not persisted)
    @State private var licenseKeyInput = ""
    @State private var activationState: ActivationUIState = .idle  // transient — activate/trial result
    @State private var isEditingIP = false
    @State private var editingIP = ""
    @State private var isEditingBackupName = false
    @State private var editingBackupName = ""
    @State private var renameState: RenameState = .idle
    @State private var renameGeneration: Int = 0
    @State private var pendingRenameNewName = ""  // The name we asked the Backup to take
    @State private var destinationCheckState: DestinationCheckState = .idle
    @State private var hasConfirmedDestinationThisConnection = false
    @State private var manualModeFreeSpace: Int64 = 0  // Free space read via SSH for manual mode
    // V1.1 Windows-target path — UNTESTED against live Windows Backup as of this commit (Windows sshd pending).
    @State private var isEditingWindowsPath = false
    @State private var editingWindowsPath = ""
    @State private var isPairingStarting = false

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
        case sent       // legacy: kept for the waiting-state checks; no longer set on success
        case renamed    // SSH write succeeded — name settled optimistically; brief "✓ Renamed"
        case failed
    }

    private var isMain: Bool { store.effectiveRole == "main" }
    private var switchLabel: String { isMain ? "Switch to Backup" : "Switch to Main" }
    private var switchRole: String  { isMain ? "backup" : "main" }
    private var isAutomatic: Bool   { localDiscoveryMode == "automatic" }

    // Section disclosure helpers for Main Settings
    private func toggleConnectionSection() {
        if store.config.mainSettingsShowConnection {
            store.config.mainSettingsShowConnection = false
        } else {
            store.config.mainSettingsShowConnection = true
            store.config.mainSettingsShowIdentity = false
            store.config.mainSettingsShowBehaviour = false
            store.config.mainSettingsShowAbout = false
        }
    }

    private func toggleIdentitySection() {
        if store.config.mainSettingsShowIdentity {
            store.config.mainSettingsShowIdentity = false
        } else {
            store.config.mainSettingsShowIdentity = true
            store.config.mainSettingsShowConnection = false
            store.config.mainSettingsShowBehaviour = false
            store.config.mainSettingsShowAbout = false
        }
    }

    private func toggleBehaviourSection() {
        if store.config.mainSettingsShowBehaviour {
            store.config.mainSettingsShowBehaviour = false
        } else {
            store.config.mainSettingsShowBehaviour = true
            store.config.mainSettingsShowConnection = false
            store.config.mainSettingsShowIdentity = false
            store.config.mainSettingsShowAbout = false
        }
    }

    private func toggleAboutSection() {
        if store.config.mainSettingsShowAbout {
            store.config.mainSettingsShowAbout = false
        } else {
            store.config.mainSettingsShowAbout = true
            store.config.mainSettingsShowConnection = false
            store.config.mainSettingsShowIdentity = false
            store.config.mainSettingsShowBehaviour = false
        }
    }

    private func toggleBackupConnectionSection() {
        if store.config.backupSettingsShowConnection {
            store.config.backupSettingsShowConnection = false
        } else {
            store.config.backupSettingsShowConnection = true
            store.config.backupSettingsShowIdentity = false
            store.config.backupSettingsShowBehaviour = false
            store.config.backupSettingsShowAbout = false
        }
    }

    private func toggleBackupIdentitySection() {
        if store.config.backupSettingsShowIdentity {
            store.config.backupSettingsShowIdentity = false
        } else {
            store.config.backupSettingsShowIdentity = true
            store.config.backupSettingsShowConnection = false
            store.config.backupSettingsShowBehaviour = false
            store.config.backupSettingsShowAbout = false
        }
    }

    private func toggleBackupBehaviourSection() {
        if store.config.backupSettingsShowBehaviour {
            store.config.backupSettingsShowBehaviour = false
        } else {
            store.config.backupSettingsShowBehaviour = true
            store.config.backupSettingsShowConnection = false
            store.config.backupSettingsShowIdentity = false
            store.config.backupSettingsShowAbout = false
        }
    }

    private func toggleBackupAboutSection() {
        if store.config.backupSettingsShowAbout {
            store.config.backupSettingsShowAbout = false
        } else {
            store.config.backupSettingsShowAbout = true
            store.config.backupSettingsShowConnection = false
            store.config.backupSettingsShowIdentity = false
            store.config.backupSettingsShowBehaviour = false
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
                    title: isMain ? "Switch to Backup?" : "Switch to Main?",
                    message: "The app will restart in the new role.",
                    confirmLabel: "Switch",
                    confirmColor: .orange,
                    onCancel: { showRoleConfirm = false },
                    onConfirm: {
                        showRoleConfirm = false
                        let targetRole = switchRole
                        let currentRole = store.effectiveRole

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
                                // Main → Backup: stop global hotkey. The advertiser is
                                // NOT started here — that used to bind it with the OLD
                                // role's config (pre-setRole); rebuildPopover →
                                // updateBonjourAdvertiser below starts it with the
                                // backup config.
                                GlobalHotkey.shared.unregister()
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
            } else if showForgetBackupConfirm {
                InlineConfirm(
                    title: "Forget This Backup?",
                    message: "Removes the pairing from this Mac and asks the Backup to forget it too. You'll need to pair again to sync.",
                    confirmLabel: "Forget",
                    confirmColor: .red,
                    onCancel: { showForgetBackupConfirm = false },
                    onConfirm: {
                        showForgetBackupConfirm = false
                        forgetBackup()
                    }
                )
            } else if showForgetMainConfirm {
                InlineConfirm(
                    title: "Forget Paired Main?",
                    message: "Removes the pairing from this Mac. The Main won't be able to back up here until you pair again.",
                    confirmLabel: "Forget",
                    confirmColor: .red,
                    onCancel: { showForgetMainConfirm = false },
                    onConfirm: {
                        showForgetMainConfirm = false
                        forgetPairedMain()
                    }
                )
            } else if showResetToDefaultsConfirm {
                InlineConfirm(
                    title: "Reset to Defaults?",
                    message: "This will erase all settings, the pairing, and sync history, and return Sync to its first-launch state. If the other Mac is reachable, it will forget this Mac too. Your synced files will NOT be deleted. This cannot be undone.",
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
                    groupHeader("Connection",
                                expanded: store.config.mainSettingsShowConnection) {
                        toggleConnectionSection()
                    }

                    if store.config.mainSettingsShowConnection {
                        connectionSectionContent
                    }

                    Divider()

                    // Section 2: Identity & Trust
                    groupHeader("Identity & Trust",
                                expanded: store.config.mainSettingsShowIdentity) {
                        toggleIdentitySection()
                    }

                    if store.config.mainSettingsShowIdentity {
                        identitySectionContent
                    }

                    Divider()

                    // Section 3: Behaviour
                    groupHeader("Behaviour",
                                expanded: store.config.mainSettingsShowBehaviour) {
                        toggleBehaviourSection()
                    }

                    if store.config.mainSettingsShowBehaviour {
                        behaviourSectionContent
                    }

                    Divider()

                    // Section 4: License
                    groupHeader("License", expanded: showLicense) {
                        showLicense.toggle()
                    }
                    if showLicense {
                        licenseSectionContent
                    }

                    Divider()

                    // Section 5: About
                    groupHeader("About",
                                expanded: store.config.mainSettingsShowAbout) {
                        toggleAboutSection()
                    }
                    if store.config.mainSettingsShowAbout {
                        aboutSectionContent
                    }

                    Divider()
                } else {
                    // Backup Settings — same four-group accordion as Main

                    // Section 1: Connection
                    groupHeader("Connection",
                                expanded: store.config.backupSettingsShowConnection) {
                        toggleBackupConnectionSection()
                    }
                    if store.config.backupSettingsShowConnection {
                        backupConnectionContent
                    }

                    Divider()

                    // Section 2: Identity & Trust
                    groupHeader("Identity & Trust",
                                expanded: store.config.backupSettingsShowIdentity) {
                        toggleBackupIdentitySection()
                    }
                    if store.config.backupSettingsShowIdentity {
                        backupIdentityContent
                    }

                    Divider()

                    // Section 3: Behaviour
                    groupHeader("Behaviour",
                                expanded: store.config.backupSettingsShowBehaviour) {
                        toggleBackupBehaviourSection()
                    }
                    if store.config.backupSettingsShowBehaviour {
                        backupBehaviourContent
                    }

                    Divider()

                    // Section 4: License
                    groupHeader("License", expanded: showLicense) {
                        showLicense.toggle()
                    }
                    if showLicense {
                        licenseSectionContent
                    }

                    Divider()

                    // Section 5: About
                    groupHeader("About",
                                expanded: store.config.backupSettingsShowAbout) {
                        toggleBackupAboutSection()
                    }
                    if store.config.backupSettingsShowAbout {
                        aboutSectionContent
                    }

                    Divider()
                }

                // Reset to Defaults
                VStack(alignment: .leading, spacing: 8) {
                    Button("Reset to Defaults") {
                        showResetToDefaultsConfirm = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
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
            // Catch-up: the fallback warning may be stale if no path event fired
            NetworkInterfaceManager.shared.refreshAvailability()
            connectionStatus.start("settings")
            // Manual mode: the shared checker may already be .reachable (started by
            // MainView), so the transition-based onChange below would never fire —
            // confirm the destination for this connection now.
            if connectionStatus.state == .reachable && !isAutomatic && !hasConfirmedDestinationThisConnection {
                hasConfirmedDestinationThisConnection = true
                confirmBackupDestination()
            }
        }
        .onDisappear {
            connectionStatus.stop("settings")
        }
        // onAppear only fires when SettingsView enters the hierarchy (gear tap while popover open).
        // willShowNotification fires every time the popover opens, catching the return-from-wizard case
        // where the popover was closed by the wizard and then reopened by the user.
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in
            connectionStatus.start("settings")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in
            connectionStatus.stop("settings")
        }
        .onChange(of: store.config.destinationIP) { _ in
            Task { @MainActor in
                hasConfirmedDestinationThisConnection = false
                destinationCheckState = .idle
                connectionStatus.recheck()
            }
        }
        .onChange(of: store.config.username) { _ in
            Task { @MainActor in
                hasConfirmedDestinationThisConnection = false
                destinationCheckState = .idle
                connectionStatus.recheck()
            }
        }
        .onChange(of: connectionStatus.state) { newState in
            // Manual mode: confirm destination on reconnect (transition INTO .reachable)
            if newState == .reachable && !isAutomatic && !hasConfirmedDestinationThisConnection {
                hasConfirmedDestinationThisConnection = true
                confirmBackupDestination()
            }
            // Reset flag when connection drops
            if newState == .unreachable {
                hasConfirmedDestinationThisConnection = false
                destinationCheckState = .idle
            }
        }
        .onChange(of: localDiscoveryMode) { _ in
            Task { @MainActor in
                store.config.discoveryMode = localDiscoveryMode
                // V1.1: entering manual mode applies the persisted Windows Backup
                // choice (both directions — a TXT-adopted "windows" must not leak
                // into manual mode with the toggle off). Automatic mode is left to
                // the TXT self-heal on the next resolve.
                if localDiscoveryMode == "manual" {
                    store.config.backupPlatform = store.config.manualWindowsBackup ? "windows" : ""
                }
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
        .onChange(of: store.config.preferredInterfaceMAC) { _ in
            // Recompute the availability flag now — path events alone leave it stale
            NetworkInterfaceManager.shared.refreshAvailability()
            if isMain && isAutomatic {
                BonjourBrowser.shared.restart()
            }
            if !isMain {
                BonjourAdvertiser.shared.restart()
                // The pairing listener must re-bind to the new interface too —
                // it's the one component nothing else restarts.
                BonjourPairingService.shared.restartListening()
            }
        }
        .onChange(of: store.config.appPresence) { _ in
            AppDelegate.shared?.applyAppPresence()
        }
        .onChange(of: bonjourBrowser.services) { services in
            // Detect remote rename confirmation: the REQUESTED name must appear at the
            // target IP. Never confirm by IP alone — the old advertisement can linger
            // (lost mDNS goodbye) and an IP-only match would re-install the old name.
            let isWaitingForRename = { () -> Bool in
                if case .pending = renameState { return true }
                if case .sent = renameState { return true }
                return false
            }()
            guard isWaitingForRename, !pendingRenameNewName.isEmpty else { return }
            let targetIP = store.config.destinationIP
            if let match = services.first(where: { $0.id == pendingRenameNewName && $0.resolvedIP == targetIP }) {
                handleRenameConfirmed(newName: match.id)
            }
        }
        .onChange(of: pairingService.state) { newState in
            switch newState {
            case .advertising, .browsing, .waitingForConfirm, .paired, .declined, .timeout, .failed:
                isPairingStarting = false
            case .idle:
                break
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
                        // Auto-username: adopt the Backup's broadcast account name
                        // ("" = older Backup → keep whatever is typed).
                        if !service.username.isEmpty && store.config.username != service.username {
                            store.config.username = service.username
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
                                    Text("\(service.resolvedIP) · \(service.freeSpaceBytes > 0 ? formatBytes(service.freeSpaceBytes) : "?") free")
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

    // Collapsible-group header row (chevron + title). One builder drives all
    // eight headers (4 per role); GroupHeaderRow adds the native hover highlight.
    @ViewBuilder
    private func groupHeader(_ title: String, expanded: Bool, action: @escaping () -> Void) -> some View {
        GroupHeaderRow(title: title, expanded: expanded, action: action)
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
            alert.messageText = "This Folder Can't Receive Files Over the Network"
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
            alert.messageText = "Can't Back Up to This Folder"
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
        // 0. Tear down the pairing first (one teardown truth — same path as Forget).
        // Without this, the wipe leaves the Backup still authorizing this Mac's key
        // and holding a trust record for a deviceId that's about to be erased.
        // The remote ask is a detached Process, so it survives the relaunch.
        if isMain {
            forgetBackup()
        } else {
            forgetPairedMain()
        }

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
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let syncDir = appSupport.appendingPathComponent("Sync", isDirectory: true)
            try? fm.removeItem(at: syncDir)
        }

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

    // MARK: - Remote rename helpers

    // Auto-username: true when the selected Backup broadcasts its account name in
    // automatic mode — the row is then read-only ("" = older Backup → editable).
    private var usernameIsBroadcast: Bool {
        guard isAutomatic else { return false }
        let broadcast = bonjourBrowser.services
            .first(where: { $0.resolvedIP == store.config.destinationIP })?.username ?? ""
        return !broadcast.isEmpty
    }

    private var isValidRenameInput: Bool {
        let t = editingBackupName.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.utf8.count <= 63 else { return false }
        for char in t.unicodeScalars { if char.value < 32 || char == "/" { return false } }
        return true
    }

    // Same rules as the Backup name: non-empty, ≤63 UTF-8 bytes, no control chars / "/".
    private var isValidDeviceNameInput: Bool {
        let t = editingDeviceName.trimmingCharacters(in: .whitespaces)
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
        pendingRenameNewName = newName

        let username = store.config.username
        let ip = store.config.destinationIP
        let remotePath = store.config.backupDestination.isEmpty ? "~/Sync" : store.config.backupDestination
        let escaped = newName.replacingOccurrences(of: "'", with: "'\\''")

        let destFile = "\(remotePath)/\(SignalFile.renameRequest)"
        let safeDestFile: String
        if destFile.hasPrefix("~/") {
            let remainder = String(destFile.dropFirst(2))
            let escapedRemainder = shellEscapeForDoubleQuotes(remainder)
            safeDestFile = "\"$HOME/\(escapedRemainder)\""
        } else {
            let escapedPath = shellEscapeForDoubleQuotes(destFile)
            safeDestFile = "\"\(escapedPath)\""
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "StrictHostKeyChecking=no",
                          "--", "\(username)@\(ip)", "echo -n '\(escaped)' > \(safeDestFile)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { p in
            Task { @MainActor in
                guard renameGeneration == thisGen else { return }
                if p.terminationStatus == 0 {
                    // SSH write succeeded — optimistic update: Main validated the name with
                    // the same rules the Backup applies, so show it immediately. Discovery
                    // reconciles if the Backup ends up advertising something else.
                    ConfigStore.shared.config.lastBackupDiscoveryName = newName
                    BonjourBrowser.shared.noteRenamePending(oldName: oldName, newName: newName)
                    // Row settles with the name: brief "✓ Renamed", then idle.
                    renameState = .renamed
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if renameState == .renamed && renameGeneration == thisGen { renameState = .idle }
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
            // Close the settling window: if the rename never materialized on the Backup,
            // discovery may now reconcile the stored name back to what's really advertised.
            BonjourBrowser.shared.clearRenameSettling()
        }
    }

    private func handleRenameConfirmed(newName: String) {
        renameGeneration += 1  // Cancel any pending timeouts
        store.config.lastBackupDiscoveryName = newName
        renameState = .idle
        pendingRenameNewName = ""
        BonjourBrowser.shared.clearRenameSettling()
    }

    // MARK: - Main Settings Section Content

    @ViewBuilder private var connectionSectionContent: some View {
        Divider()

        sectionHeader("Role")
        VStack(spacing: 8) {
            HStack {
                Text("Main")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                Spacer()
                Button(switchLabel) { showRoleConfirm = true }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
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
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)

        Divider()

        interfacePickerSection

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
                    Text("Folder")
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
                    Text("Backup IP")
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
                    }
                }
                // V1.1 Windows-target path — UNTESTED against live Windows Backup as of this commit (Windows sshd pending).
                // Explicit opt-in: a Windows Backup can't be auto-detected in manual mode (no TXT),
                // and no coupling to ShowSync-Win's config layout in V1.1 (approved §8.1).
                Toggle(isOn: Binding(
                    get: { store.config.backupPlatform == "windows" },
                    set: { on in
                        store.config.manualWindowsBackup = on  // persisted — survives relaunch
                        store.config.backupPlatform = on ? "windows" : ""
                        destinationCheckState = .idle
                        hasConfirmedDestinationThisConnection = false
                        isEditingWindowsPath = false
                        connectionStatus.recheck()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Windows Backup")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                        Text("Backup runs ShowSync for Windows (files sent over SFTP)")
                            .font(.system(size: 10))
                            .foregroundColor(labelColor)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                // Manual mode: Confirm Destination button + status
                if !store.config.destinationIP.isEmpty, store.config.backupPlatform != "windows" {  // V1.1: gated — Windows row below
                    HStack {
                        Text("Folder")
                            .font(.system(size: 11))
                            .foregroundColor(labelColor)
                        Spacer()
                        switch destinationCheckState {
                        case .idle:
                            Button("Confirm Destination") { confirmBackupDestination() }
                                .buttonStyle(.bordered)
                                .font(.system(size: 11))
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
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Button("Retry") { confirmBackupDestination() }
                                    .buttonStyle(.bordered)
                                    .font(.system(size: 10))
                            }
                        }
                    }
                }

                // V1.1 Windows-target path — UNTESTED against live Windows Backup as of this commit (Windows sshd pending).
                // Windows sibling of the Folder row above: the path is user-entered (forward
                // slashes, e.g. C:/Users/name/Sync; empty = "Sync" in the sshd home folder),
                // then write-tested over SFTP via the same Confirm Destination states.
                if !store.config.destinationIP.isEmpty, store.config.backupPlatform == "windows" {
                    HStack {
                        Text("Folder")
                            .font(.system(size: 11))
                            .foregroundColor(labelColor)
                        Spacer()
                        if isEditingWindowsPath {
                            TextField("C:/Users/name/Sync", text: $editingWindowsPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 170)
                                .multilineTextAlignment(.trailing)
                            Button("Save") {
                                store.config.backupDestination = WindowsTransport.normalizeRemotePath(editingWindowsPath)
                                isEditingWindowsPath = false
                                destinationCheckState = .idle
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(.blue)
                            Button("Cancel") { isEditingWindowsPath = false }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.5))
                        } else {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(store.config.backupDestination.isEmpty ? "Sync (home folder)" : store.config.backupDestination)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if engine.manualModeFreeSpace > 0 {
                                    Text("\(formatBytes(engine.manualModeFreeSpace)) free")
                                        .font(.system(size: 10))
                                        .foregroundColor(labelColor)
                                }
                            }
                            Button("Edit") {
                                editingWindowsPath = store.config.backupDestination
                                isEditingWindowsPath = true
                            }
                            .buttonStyle(.bordered)
                            .font(.system(size: 11))
                        }
                    }
                    HStack {
                        Spacer()
                        switch destinationCheckState {
                        case .idle:
                            Button("Confirm Destination") { confirmBackupDestination() }
                                .buttonStyle(.bordered)
                                .font(.system(size: 11))
                        case .checking:
                            Text("Checking...")
                                .font(.system(size: 11))
                                .foregroundColor(labelColor)
                        case .confirmed:
                            HStack(spacing: 6) {
                                Text("Folder is writable")
                                    .font(.system(size: 11))
                                    .foregroundColor(.green)
                                Button { confirmBackupDestination() } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.blue)
                            }
                        case .failed:
                            HStack(spacing: 6) {
                                Text("Couldn't write — check the path")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                                Button("Retry") { confirmBackupDestination() }
                                    .buttonStyle(.bordered)
                                    .font(.system(size: 10))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }

    }

    // Identity & Trust group: BACKUP Username · Change Backup Name ·
    // Secure Connection · Pairing (Forget). Blocks moved verbatim from the
    // old Connection group — layout regrouping only.
    @ViewBuilder private var identitySectionContent: some View {
        sectionHeader("Identity")
        VStack(spacing: 8) {
            HStack {
                Text("This Mac's Name")
                    .font(.system(size: 12))
                    .foregroundColor(labelColor)
                Spacer()
                if isEditingDeviceName {
                    TextField("Name", text: $editingDeviceName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                    Button("Save") {
                        guard isValidDeviceNameInput else { return }
                        let trimmed = editingDeviceName.trimmingCharacters(in: .whitespaces)
                        // Local-only: rename this Mac's identity. deviceId is immutable,
                        // so existing pairings (matched by ID) are unaffected; the next
                        // pairing broadcasts the new name (read fresh at startPairing).
                        store.identity.deviceName = trimmed
                        store.saveIdentity()
                        isEditingDeviceName = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(isValidDeviceNameInput ? .blue : Color(white: 0.4))
                    .disabled(!isValidDeviceNameInput)
                    Button("Cancel") {
                        isEditingDeviceName = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))
                } else {
                    Text(store.identity.deviceName.isEmpty ? "Not set" : store.identity.deviceName)
                        .font(.system(size: 12))
                        .foregroundColor(store.identity.deviceName.isEmpty ? labelColor : .white)
                        .lineLimit(1)
                    Button("Edit") {
                        editingDeviceName = store.identity.deviceName
                        isEditingDeviceName = true
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                }
            }

            HStack {
                Text("Backup Username")
                    .font(.system(size: 12))
                    .foregroundColor(labelColor)
                Spacer()
                if usernameIsBroadcast {
                    // Automatic mode + Backup broadcasts its account name: the
                    // broadcast is the truth — nothing to type, nothing to edit.
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(store.config.username)
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("Set by Backup")
                            .font(.system(size: 9))
                            .foregroundColor(Color(white: 0.45))
                    }
                } else if isEditingUsername {
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
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)

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
                        case .renamed:
                            Text("✓ Renamed")
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

        // Manual-mode setup hint: with only one of username/IP entered the Secure
        // Connection section (and its setup button) is hidden — say what's missing.
        if !isAutomatic && (store.config.username.isEmpty != store.config.destinationIP.isEmpty) {
            Text(store.config.username.isEmpty
                 ? "Enter the Backup's username to set up the connection"
                 : "Enter the Backup's IP to set up the connection")
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.45))
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

                // Layer 2b: Show this Mac's fingerprint for verification during pairing
                if let fp = getSSHFingerprint() {
                    // Display only — strip the technical "SHA256:" prefix; the raw
                    // value is broadcast/stored elsewhere and is untouched.
                    let codeDisplay = fp.hasPrefix("SHA256:") ? String(fp.dropFirst("SHA256:".count)) : fp
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This Mac's Verification Code")
                            .font(.system(size: 10))
                            .foregroundColor(sectionHeaderColor)
                        Text(codeDisplay)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(labelColor)
                            .textSelection(.enabled)
                    }
                }

                switch connectionStatus.state ?? .checking {
                case .checking:
                    Button("Checking...") {}
                        .buttonStyle(.borderedProminent)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                        .disabled(true)
                case .reachable:
                    // Connected — the status line + fingerprint above say it all;
                    // "Forget This Backup" (Pairing section below) is the one
                    // destructive action (Reset Connection removed — Forget supersedes).
                    EmptyView()
                case .unreachable:
                    // Layer 2b: Show pairing state if active
                    let isAdvertisingState: Bool = {
                        if case .advertising = pairingService.state { return true }
                        return false
                    }()
                    if isPairingStarting || isAdvertisingState {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(isPairingStarting && !isAdvertisingState ? "Starting..." : "Pairing...")
                                .font(.system(size: 12))
                                .foregroundColor(labelColor)
                        }
                        Button("Cancel") {
                            isPairingStarting = false
                            pairingService.cancelPairing()
                        }
                        .buttonStyle(.bordered)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                    } else if case .paired(let name) = pairingService.state {
                        Text("Paired with \(name)")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                    } else if case .declined = pairingService.state {
                        Text("Pairing declined by Backup")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                        pairingButtons
                    } else if case .timeout = pairingService.state {
                        Text("Pairing timed out")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                        pairingButtons
                    } else if case .failed(let reason) = pairingService.state {
                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                        pairingButtons
                    } else {
                        pairingButtons
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }

        // Layer 4: trust teardown — visible whenever a pairing OR a manual key
        // setup exists, even when the Backup is offline or the destination was
        // cleared (offline forget works).
        if store.trustedPeers.contains(where: { $0.role == .backup }) || store.config.sshKeysConfigured {
            Divider()
            sectionHeader("Pairing")
            VStack(spacing: 8) {
                Button("Forget This Backup") {
                    showForgetBackupConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    // Layer 2b: Pairing buttons (Pair Automatically + Set Up Manually)
    @ViewBuilder private var pairingButtons: some View {
        // Get selected Backup's deviceId from TXT record (if available)
        let selectedBackupId: String? = {
            guard !store.config.destinationIP.isEmpty else { return nil }
            // Find the backup service matching our destination IP
            if let backup = bonjourBrowser.services.first(where: { $0.resolvedIP == store.config.destinationIP }),
               !backup.backupDeviceId.isEmpty {
                return backup.backupDeviceId
            }
            return nil
        }()

        VStack(spacing: 8) {
            // Primary: Pair Automatically (only if we have a targetable Backup)
            if let _ = selectedBackupId {
                Button("Pair Automatically") {
                    isPairingStarting = true
                    guard let freshBackupId = bonjourBrowser.services
                            .first(where: { $0.resolvedIP == store.config.destinationIP })?
                            .backupDeviceId,
                          !freshBackupId.isEmpty else {
                        isPairingStarting = false
                        return
                    }
                    pairingService.startPairing(targetBackupId: freshBackupId) { success, error in
                        isPairingStarting = false
                        if success {
                            connectionStatus.recheck()
                        } else if let error {
                            NSLog("[Sync] Pairing failed: %@", error)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
            }

            // Secondary: Manual setup (password wizard)
            if selectedBackupId != nil {
                Button("Set Up Manually") {
                    NSApp.keyWindow?.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        AppDelegate.shared?.startSSHKeySetup()
                    }
                }
                .buttonStyle(.bordered)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
            } else {
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
    }

    @ViewBuilder private var interfacePickerSection: some View {
        sectionHeader("Network Interface")
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(
                get: { store.config.preferredInterfaceMAC },
                set: { store.config.preferredInterfaceMAC = $0 }
            )) {
                Text("Automatic (first available)").tag("")
                ForEach(interfaceManager.availableInterfaces) { iface in
                    let mac = macForInterface(name: iface.name)
                    Text(iface.displayLabel).tag(mac)
                }
                // If the chosen NIC is temporarily absent (unplugged), keep a tagged option
                // for its MAC so the selection stays valid (no "invalid selection" warning)
                // and the choice is preserved — it recovers when the interface returns.
                let savedMAC = store.config.preferredInterfaceMAC
                if !savedMAC.isEmpty &&
                   !interfaceManager.availableInterfaces.contains(where: { macForInterface(name: $0.name) == savedMAC }) {
                    Text("Chosen interface (not connected)").tag(savedMAC)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            if interfaceManager.usingFallback {
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                    Text("Selected network not found — reconnect it or switch to Automatic")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Locks ShowSync to one network connection: discovery, pairing, and backups all use only this interface. Automatic picks the first available.")
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func macForInterface(name: String) -> String {
        guard let interfaces = try? Interfaces.list() else { return "" }
        return interfaces.first { $0.name == name }?.mac ?? ""
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
                    Text("Check Every")
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
                    Text("Keep Versions")
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

        sectionHeader("Verify")
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $store.config.fastVerify) {
                Text("Fast").tag(true)
                Text("Deep").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(store.config.fastVerify
                 ? "Checks file size and date only. Quick for large files."
                 : "Checks every file's contents (checksum). Most thorough.")
                .font(.system(size: 11))
                .foregroundColor(labelColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                Text("Show ShowSync in")
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

    // Backup group 1 — Connection: Role · Discovery mode · Interface · Destination
    @ViewBuilder private var backupConnectionContent: some View {
        sectionHeader("Role")
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Backup")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                Spacer()
                // Lock: only offer the Main switch when the license gate is granted.
                if store.fullModeGranted {
                    Button(switchLabel) { showRoleConfirm = true }
                        .buttonStyle(.bordered)
                        .font(.system(size: 11))
                }
            }
            if !store.fullModeGranted {
                Text("Backup-only — activate a license to enable Main mode.")
                    .font(.system(size: 11))
                    .foregroundColor(labelColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            Text("Minimum Free Space")
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
    }

    // Backup group 2 — Identity & Trust: Network Discovery Name · Pairing
    @ViewBuilder private var backupIdentityContent: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)

        // Layer 4: trust teardown — visible whenever a Main is paired
        if store.trustedPeers.contains(where: { $0.role == .main }) {
            Divider()
            sectionHeader("Pairing")
            VStack(spacing: 8) {
                Button("Forget Paired Main") {
                    showForgetMainConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    // License group (shared, both roles): reads LicenseController.summary (status),
    // and triggers activation / trial fetch. Reads + triggers only — gates nothing.
    @ViewBuilder private var licenseSectionContent: some View {
        let summary = license.summary
        VStack(alignment: .leading, spacing: 8) {
            // Status line derived from the licensing brain.
            Text(licenseStatusText(summary))
                .font(.system(size: 12))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Start free trial — fetch a trial key, then activate it.
            Button("Start free trial") {
                activationState = .activating
                Task {
                    if let k = await LicenseManager.fetchTrialKey() {
                        activationState = mapActivationResult(await LicenseManager.activate(key: k))
                    } else {
                        activationState = .trialUnavailable
                    }
                }
            }
            .buttonStyle(.bordered)
            .font(.system(size: 12))
            .disabled(activationState == .activating)

            // Manual key entry + Activate.
            VStack(alignment: .leading, spacing: 6) {
                TextField("Enter license key", text: $licenseKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button("Activate") {
                    activationState = .activating
                    Task {
                        activationState = mapActivationResult(await LicenseManager.activate(key: licenseKeyInput))
                    }
                }
                .buttonStyle(.borderedProminent)
                .font(.system(size: 12))
                .disabled(licenseKeyInput.isEmpty || activationState == .activating)
            }

            // Transient feedback.
            switch activationState {
            case .idle:
                EmptyView()
            case .activating:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Activating…").font(.system(size: 11)).foregroundColor(labelColor)
                }
            case .success:
                Text("Activated — relaunch to enable Main mode.")
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .failure(let m):
                Text(m)
                    .font(.system(size: 11))
                    .foregroundColor(labelColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .trialUnavailable:
                Text("Couldn't reach the trial service. Enter a license key instead.")
                    .font(.system(size: 11))
                    .foregroundColor(labelColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // Human-readable license status from the read-only summary. Display only.
    private func licenseStatusText(_ s: LicenseSummary) -> String {
        switch s.kind {
        case .none:
            return "No license — start a trial or enter a key."
        case .trial:
            return s.isValid ? "Trial — \(s.daysRemaining ?? 0) days remaining" : "Trial expired"
        case .paid:
            return "Licensed"
        }
    }

    // Map an activation round-trip result to friendly UI feedback.
    private func mapActivationResult(_ r: ActivationResult) -> ActivationUIState {
        switch r {
        case .activated:
            return .success
        case .expired:
            return .failure("This license has expired.")
        case .machineLimit:
            return .failure("Already active on the maximum 2 Macs.")
        case .invalid(let c):
            return .failure("Invalid license key (\(c)).")
        case .networkError:
            return .failure("Couldn't reach the licensing server. Check your connection.")
        }
    }

    // About group (shared, both roles): version + credits. Moved verbatim from
    // the old always-visible footer; the group header supplies the "About" title.
    @ViewBuilder private var aboutSectionContent: some View {
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

            // Manual update check
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button("Check for Updates") { runUpdateCheck() }
                        .buttonStyle(.bordered)
                        .font(.system(size: 12))
                        .disabled({ if case .checking = updateState { return true }; return false }())
                    if case .checking = updateState {
                        ProgressView().controlSize(.small)
                    }
                }
                switch updateState {
                case .idle:
                    EmptyView()
                case .checking:
                    Text("Checking…")
                        .font(.system(size: 11))
                        .foregroundColor(labelColor)
                case .upToDate:
                    Text("You're up to date")
                        .font(.system(size: 11))
                        .foregroundColor(labelColor)
                case .updateAvailable(let v, let url):
                    HStack(spacing: 8) {
                        Text("Version \(v) available")
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                        Button("Download") {
                            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.system(size: 11))
                    }
                case .failed:
                    Text("Couldn't check for updates — try again later")
                        .font(.system(size: 11))
                        .foregroundColor(labelColor)
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // Manual update check: HTTPS GET the version manifest, compare build numbers.
    // up-to-date/available is reached ONLY on 200 + valid JSON; every failure
    // (offline, timeout, non-200, malformed, non-integer build) → .failed.
    private func runUpdateCheck() {
        updateState = .checking
        guard let url = URL(string: updateCheckURL) else { updateState = .failed; return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"

        let localBuild = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0

        URLSession.shared.dataTask(with: request) { data, response, error in
            // Compute the result off-main, publish on @MainActor.
            let result: UpdateState = {
                guard error == nil,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data,
                      let info = try? JSONDecoder().decode(AppVersionInfo.self, from: data),
                      let remoteBuild = Int(info.build) else {
                    return .failed
                }
                if remoteBuild > localBuild {
                    return .updateAvailable(version: info.version, url: info.url)
                }
                return .upToDate
            }()
            Task { @MainActor in updateState = result }
        }.resume()
    }

    // Backup group 3 — Behaviour: the former Options content, unchanged
    @ViewBuilder private var backupBehaviourContent: some View {
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
                Text("Show ShowSync in")
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
        switch connectionStatus.state ?? .checking {
        case .checking:    return Color(white: 0.55)
        case .reachable:   return .green
        case .unreachable: return .red
        }
    }

    private var sshStatusLabel: String {
        switch connectionStatus.state ?? .checking {
        case .checking:    return "Checking..."
        case .reachable:   return "Connected"
        case .unreachable: return "Not Connected"
        }
    }

    private func confirmBackupDestination() {
        let username = store.config.username
        let ip = store.config.destinationIP
        guard !username.isEmpty, !ip.isEmpty else { return }

        // V1.1 Windows-target path — UNTESTED against live Windows Backup as of this commit (Windows sshd pending).
        // No remote config read on Windows (approved §8.1) — the user-entered path is
        // write-tested over SFTP instead. Gated here so the auto-confirm-on-reachable
        // callers route correctly too. No-flag path falls through, untouched.
        if store.config.backupPlatform == "windows" {
            destinationCheckState = .checking
            WindowsTransport.shared.probeDestination(
                username: username,
                ip: ip,
                destination: store.config.backupDestination
            ) { writable in
                Task { @MainActor in
                    destinationCheckState = writable ? .confirmed : .failed
                }
            }
            return
        }

        destinationCheckState = .checking
        // Read config and free space in one SSH call
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=3",
            "-o", "StrictHostKeyChecking=no",
            "--", "\(username)@\(ip)",
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
        let escapedPath = shellEscapeForDoubleQuotes(remotePath)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=3",
            "-o", "StrictHostKeyChecking=no",
            "--", "\(username)@\(ip)",
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

    // MARK: - Layer 4: trust teardown

    // True clean slate: the keypair is part of the relationship being forgotten;
    // re-pairing regenerates it via ensureSSHKeyExists.
    private static func deleteLocalKeypair() {
        let home = NSHomeDirectory()
        try? FileManager.default.removeItem(atPath: (home as NSString).appendingPathComponent(".ssh/id_ed25519"))
        try? FileManager.default.removeItem(atPath: (home as NSString).appendingPathComponent(".ssh/id_ed25519.pub"))
    }

    // Main role: forget the paired Backup. Best-effort asks the Backup to forget
    // us too (signal file over SSH while still trusted), then always tears down
    // local trust + selection + keypair.
    private func forgetBackup() {
        // (a) Ask the Backup to forget us — only attempted while reachable; a
        // failure is logged, never queued (the Backup's own Forget is the remedy).
        let username = store.config.username
        let ip = store.config.destinationIP
        let hasPairedPeer = store.trustedPeers.contains(where: { $0.role == .backup })
        if !username.isEmpty && !ip.isEmpty && connectionStatus.state == .reachable && !hasPairedPeer {
            // Manual setup: no trust records exist on either side, so the signal/
            // unpairPeer route can't clean the Backup — remove this Mac's key from
            // its authorized_keys directly (mirror of the wizard's install),
            // while we're still authorized.
            let pubKeyPath = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/id_ed25519.pub")
            let pubKey = (try? String(contentsOfFile: pubKeyPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !pubKey.isEmpty {
                // Single-quote-escape the key (' -> '\'') as defense-in-depth before
                // embedding it in the single-quoted grep pattern.
                let escapedPubKey = pubKey.replacingOccurrences(of: "'", with: "'\\''")
                let remoteCmd = "if [ -f ~/.ssh/authorized_keys ]; then grep -vF '\(escapedPubKey)' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp; mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; fi"
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                proc.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "StrictHostKeyChecking=no",
                                  "--", "\(username)@\(ip)", remoteCmd]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                proc.terminationHandler = { p in
                    if p.terminationStatus != 0 {
                        NSLog("[Sync] Forget (manual): key removal not delivered (exit %d) — Backup keeps the key", p.terminationStatus)
                    }
                    // Keypair deletion AFTER the removal attempt — it authenticates
                    // with the key being deleted.
                    Self.deleteLocalKeypair()
                }
                DispatchQueue.global(qos: .utility).async { try? proc.run() }
            } else {
                Self.deleteLocalKeypair()
            }
        } else if !username.isEmpty && !ip.isEmpty && connectionStatus.state == .reachable {
            let myId = store.identity.deviceId
            let nonce = UUID().uuidString
            let remotePath = store.config.backupDestination.isEmpty ? "~/Sync" : store.config.backupDestination
            let destFile = "\(remotePath)/\(SignalFile.unpairRequest)"
            let safeDestFile: String
            if destFile.hasPrefix("~/") {
                let remainder = String(destFile.dropFirst(2))
                safeDestFile = "\"$HOME/\(shellEscapeForDoubleQuotes(remainder))\""
            } else {
                safeDestFile = "\"\(shellEscapeForDoubleQuotes(destFile))\""
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "StrictHostKeyChecking=no",
                              "--", "\(username)@\(ip)",
                              "echo '{\"mainId\":\"\(myId)\",\"nonce\":\"\(nonce)\"}' > \(safeDestFile)"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            proc.terminationHandler = { p in
                if p.terminationStatus != 0 {
                    NSLog("[Sync] Forget: unpair request not delivered (exit %d) — Backup keeps its record", p.terminationStatus)
                }
                // Keypair deletion AFTER the write attempt — the write authenticates
                // with this key; deleting first would race its own auth.
                Self.deleteLocalKeypair()
            }
            DispatchQueue.global(qos: .utility).async { try? proc.run() }
        } else {
            NSLog("[Sync] Forget: Backup unreachable — local teardown only")
            Self.deleteLocalKeypair()
        }

        // Reset transient pairing state — a stale .paired short-circuits the gate's
        // pairing UI into a button-less "Paired with …" dead end.
        BonjourPairingService.shared.cancelPairing()

        // (b) Local teardown — always.
        for peer in store.trustedPeers where peer.role == .backup {
            _ = store.unpairPeer(peerId: peer.id)
        }
        store.config.sshKeysConfigured           = false
        store.config.sshKeyConfiguredForIP       = ""
        store.config.sshKeyConfiguredForUsername = ""
        store.config.destinationIP               = ""
        store.config.backupHostname              = ""
        store.config.lastBackupDiscoveryName     = ""
        store.config.lastBackupIP                = ""
    }

    // Backup role: forget the paired Main — local only (unpairPeer also removes
    // the Main's key from authorized_keys and logs the unpaired event).
    private func forgetPairedMain() {
        for peer in store.trustedPeers where peer.role == .main {
            _ = store.unpairPeer(peerId: peer.id)
        }
        // Reset transient pairing state (stale .paired dead end; keeps listening)
        BonjourPairingService.shared.cancelPairing()
    }
}

// Collapsible-group header row with a subtle native hover highlight (light grey
// fill on hover — never blue, which is for selection). View-only; the tap action
// and expansion logic are unchanged.
private struct GroupHeaderRow: View {
    let title: String
    let expanded: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(white: 0.4))
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.45))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(hovering ? 0.06 : 0))
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}
