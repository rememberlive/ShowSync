import Foundation
import ShowNetwork

// MARK: - Transfer Log Entry

struct TransferLogEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let trigger: String      // "manual" | "auto" | "push"
    let result: String       // "success" | "failed" | "refused" | "cancelled" | "fallback"
    let fileCount: Int
    let totalBytes: Int64
    let durationSeconds: Int
    let destination: String
    let usedFallback: Bool
}

// Single source of truth for the menu bar icon colour.
// AppDelegate observes this via Combine and updates the status item image.
enum SyncIconState: Equatable {
    case idle           // grey — ready/listening
    case notConfigured  // grey dimmed — folders or IP not set
    case syncing        // yellow — rsync running (Main only)
    case receiving      // yellow — transfer in progress (Backup only)
    case success        // green — completed, stays until dropdown opens
    case warning        // amber — attention needed (fallback active, folder unwritable)
    case error          // red — rsync failure or network lost
}

// MARK: - Runtime config (never stored directly; see ConfigStore for persistence)

struct Config {
    var role: String = "main"

    // Main-role fields
    var sourceFolder: String = ""
    var destinationIP: String = ""
    var username: String = ""
    var launchAtLogin: Bool = false
    var dryRunEnabled: Bool = false
    var mainShowConnectionInfo: Bool = false
    var mainSettingsShowConnection: Bool = false
    var mainSettingsShowBehaviour: Bool = false
    var mainSettingsShowIdentity: Bool = false
    var mainSettingsShowAbout: Bool = false
    var backupSettingsShowConnection: Bool = false
    var backupSettingsShowIdentity: Bool = false
    var backupSettingsShowBehaviour: Bool = false
    var backupSettingsShowAbout: Bool = false
    var sshKeysConfigured: Bool = false
    var sshKeyConfiguredForIP: String = ""
    var sshKeyConfiguredForUsername: String = ""
    var autoSyncEnabled: Bool = false
    var autoSyncInterval: Int = 10
    var nextAutoSyncDate: Date? = nil
    var nextAutoSyncScheduledInterval: Int = 10
    var pushSyncEnabled: Bool = false
    var pushSyncDebounce: Int = 10
    var versionHistoryEnabled: Bool = false
    var maxVersionCount: Int = 3
    var fastVerify: Bool = false   // false = Deep (rsync -avc, checksum); true = Fast (-av, size+modtime)

    // Discovery (per-role on disk; one runtime field reflects the active role)
    var discoveryMode: String = "automatic"   // "automatic" | "manual"
    var backupHostname: String = ""           // Main role only — Bonjour name of the selected Backup
    var lastBackupDiscoveryName: String = ""  // Auto-reconnect: remembered Backup Mac's name
    var lastBackupIP: String = ""             // Auto-reconnect: remembered Backup Mac's IP
    var backupDestination: String = "~/Sync"  // Main role — Backup's receive folder (from TXT)

    // Backup-role fields
    var mainIP: String = ""
    var destinationFolder: String = (NSHomeDirectory() as NSString).appendingPathComponent("Sync")
    var lastReceivedTime: Date? = nil
    var networkDiscoveryName: String = ""
    var minFreeSpaceGB: Int = 2  // Minimum free space threshold (floor 1GB)

    // Network interface selection (both roles)
    var preferredInterface: String = ""  // Legacy BSD name — kept for migration only
    var preferredInterfaceMAC: String = ""  // Empty = "Automatic", otherwise MAC address

    // Global hotkey (Main role only)
    var globalHotkeyEnabled: Bool = true  // ⌃⌥⌘S triggers Sync Now from anywhere

    // App presence (shared, not role-specific)
    var appPresence: String = "menubar"  // "menubar" | "both"

    var isReadyToSync: Bool {
        !sourceFolder.isEmpty && !destinationIP.isEmpty && !username.isEmpty && sshKeysConfigured
    }
}

// MARK: - Per-role on-disk schemas

private struct RoleFile: Codable {
    var role: String = "main"
}

private struct MainConfig: Codable {
    var sourceFolder: String = ""
    var destinationIP: String = ""
    var username: String = ""
    var launchAtLogin: Bool = false
    var dryRunEnabled: Bool = false
    var mainShowConnectionInfo: Bool = false
    var mainSettingsShowConnection: Bool = false
    var mainSettingsShowBehaviour: Bool = false
    // Optional: added later — old config files lack the key (decode must not fail)
    var mainSettingsShowIdentity: Bool? = nil
    var mainSettingsShowAbout: Bool? = nil
    var sshKeysConfigured: Bool = false
    var sshKeyConfiguredForIP: String = ""
    var sshKeyConfiguredForUsername: String = ""
    var autoSyncEnabled: Bool = false
    var autoSyncInterval: Int = 10
    var nextAutoSyncDate: Date? = nil
    var nextAutoSyncScheduledInterval: Int = 10
    var pushSyncEnabled: Bool = false
    var pushSyncDebounce: Int = 10
    var versionHistoryEnabled: Bool = false
    var maxVersionCount: Int = 3
    var fastVerify: Bool = false
    var discoveryMode: String = "automatic"
    var backupHostname: String = ""
    var lastBackupDiscoveryName: String = ""
    var lastBackupIP: String = ""
    var preferredInterface: String = ""
    var preferredInterfaceMAC: String = ""
    var globalHotkeyEnabled: Bool = true
}

private struct BackupConfig: Codable {
    var mainIP: String = ""
    var destinationFolder: String = (NSHomeDirectory() as NSString).appendingPathComponent("Sync")
    var effectivePath: String = ""  // Actual path being used (~/Sync when drive unavailable)
    var launchAtLogin: Bool = false
    var lastReceivedTime: Date? = nil
    var discoveryMode: String = "automatic"
    var networkDiscoveryName: String = ""
    var minFreeSpaceGB: Int = 2
    var preferredInterface: String = ""
    var preferredInterfaceMAC: String = ""
    // Optional: added later — old config files lack the keys (decode must not fail)
    var backupSettingsShowConnection: Bool? = nil
    var backupSettingsShowIdentity: Bool? = nil
    var backupSettingsShowBehaviour: Bool? = nil
    var backupSettingsShowAbout: Bool? = nil
}

private struct SharedConfig: Codable {
    var appPresence: String = "menubar"  // "menubar" | "both"
}

// All fields optional — used only during one-time migration from the legacy config.json.
private struct LegacyConfig: Codable {
    var role: String?
    var sourceFolder: String?
    var destinationFolder: String?
    var destinationIP: String?
    var username: String?
    var mainIP: String?
    var launchAtLogin: Bool?
    var dryRunEnabled: Bool?
    var mainShowConnectionInfo: Bool?
    var sshKeysConfigured: Bool?
    var sshKeyConfiguredForIP: String?
    var sshKeyConfiguredForUsername: String?
    var pushSyncEnabled: Bool?
    var pushSyncDebounce: Int?
    var discoveryMode: String?
    var backupHostname: String?
    var networkDiscoveryName: String?
}

// MARK: - ConfigStore

final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: Config {
        didSet { scheduleSave() }
    }

    /// Launch-time license-gate snapshot. Defaults true (fail-open) until evaluated.
    /// Captured ONCE at launch (evaluateLicenseGate) so the effective role is stable for
    /// the whole session — activating a license takes effect on the next launch, not live
    /// (avoids a half-started role swap mid-session). Never persisted.
    private(set) var fullModeGranted: Bool = true

    /// Evaluate the gate once at launch (call on the main actor, after loadFromStore).
    @MainActor func evaluateLicenseGate() {
        fullModeGranted = LicenseController.shared.grantsFullMode
    }

    /// The role the app should ACT as for this launch. When full mode isn't granted,
    /// the app behaves as "backup" WITHOUT ever writing role.json (saved role untouched,
    /// so reactivation restores it). Read by service-start + UI decisions; NEVER by
    /// save()/writeRole/setRole (those keep the REAL config.role so the override can't persist).
    var effectiveRole: String {
        fullModeGranted ? config.role : "backup"
    }

    // Transient — not persisted. Set by SyncEngine during active rsync.
    @Published var isSyncing: Bool = false

    // Transient — not persisted. Observed by AppDelegate to tint the status item icon.
    @Published var iconState: SyncIconState = .idle

    // Transient — not persisted. Set true when the last config save failed (disk full,
    // perms, etc.). UI may surface a warning; the app never freezes on save failure.
    @Published var lastConfigSaveFailed: Bool = false

    // Transient — not persisted. Set true to request the inline Quit confirmation view
    // (used by AppDelegate.applicationShouldTerminate when Cmd+Q hit mid-sync).
    @Published var pendingQuitConfirm: Bool = false

    // Transfer log — persisted to transfer_log.json, capped at 100 entries
    @Published var transferLog: [TransferLogEntry] = []

    // Trust foundation (Layer 1) — persisted separately from debounced config save
    @Published var identity: DeviceIdentity = DeviceIdentity(deviceId: "", deviceName: "", createdAt: Date())
    @Published var trustedPeers: [TrustedPeer] = []
    @Published var trustLog: [TrustEvent] = []

    private let roleURL: URL
    private let mainConfigURL: URL
    private let backupConfigURL: URL
    private let sharedConfigURL: URL
    private let transferLogURL: URL
    private let identityURL: URL
    private let trustedPeersURL: URL
    private let trustLogURL: URL

    private var saveWorkItem: DispatchWorkItem?
    private let saveDebounceInterval: TimeInterval = 0.1

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: item)
    }

    func flushPendingSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save()
    }

    func cancelPendingSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        roleURL         = dir.appendingPathComponent("role.json")
        mainConfigURL   = dir.appendingPathComponent("config_main.json")
        backupConfigURL = dir.appendingPathComponent("config_backup.json")
        sharedConfigURL = dir.appendingPathComponent("config_shared.json")
        transferLogURL  = dir.appendingPathComponent("transfer_log.json")
        identityURL     = dir.appendingPathComponent("identity.json")
        trustedPeersURL = dir.appendingPathComponent("trusted_peers.json")
        trustLogURL     = dir.appendingPathComponent("trust_log.json")

        // One-time migration from the legacy monolithic config.json
        Self.migrateIfNeeded(dir: dir, roleURL: roleURL,
                             mainConfigURL: mainConfigURL, backupConfigURL: backupConfigURL)

        let role = Self.readRole(from: roleURL)
        var loaded = role == "backup"
            ? Self.readBackupConfig(from: backupConfigURL)
            : Self.readMainConfig(from: mainConfigURL)
        loaded.role = role
        if role == "backup" && loaded.username.isEmpty {
            loaded.username = NSUserName()
        }
        // Load shared config (applies to both roles)
        let shared = Self.readSharedConfig(from: sharedConfigURL)
        loaded.appPresence = shared.appPresence
        config = loaded
        UserDefaults.standard.set(role, forKey: "syncRole")

        // Load transfer log (corruption-safe: bad/missing file -> empty array)
        transferLog = Self.loadTransferLog(from: transferLogURL)

        // Load trust foundation (Layer 1) — corruption-safe
        identity = Self.loadOrCreateIdentity(from: identityURL)
        trustedPeers = Self.loadTrustedPeers(from: trustedPeersURL)
        trustLog = Self.loadTrustLog(from: trustLogURL)
    }

    // Saves the current role's settings, then loads the new role's settings.
    // Callers must not set config.role directly — always go through this method.
    func setRole(_ role: String) {
        // Lock: cannot switch INTO Main while the license gate isn't granted. Switching
        // to Backup is always allowed. Uses the launch-time snapshot so it matches
        // effectiveRole (a freshly activated license enables Main on the next launch).
        if role == "main" && !fullModeGranted {
            NSLog("[Sync] setRole(main) blocked — license gate not granted (backup-only)")
            return
        }
        flushPendingSave()   // flush current role before switching

        var newConfig = role == "backup"
            ? Self.readBackupConfig(from: backupConfigURL)
            : Self.readMainConfig(from: mainConfigURL)
        newConfig.role = role
        // Auto-fill backup username from the system account only when not previously saved.
        if role == "backup" && newConfig.username.isEmpty {
            newConfig.username = NSUserName()
        }
        // Preserve shared config (role-independent settings)
        let shared = Self.readSharedConfig(from: sharedConfigURL)
        newConfig.appPresence = shared.appPresence

        config = newConfig   // triggers didSet → save() which writes to the new role's file
        writeRole(role)
        UserDefaults.standard.set(role, forKey: "syncRole")
    }

    // MARK: - Persistence

    /// Force a save of the current config (e.g., when effectivePath changes but config fields don't).
    func forceSave() {
        flushPendingSave()
    }

    private func save() {
        if config.role == "main" {
            let m = MainConfig(
                sourceFolder:               config.sourceFolder,
                destinationIP:              config.destinationIP,
                username:                   config.username,
                launchAtLogin:              config.launchAtLogin,
                dryRunEnabled:              config.dryRunEnabled,
                mainShowConnectionInfo:     config.mainShowConnectionInfo,
                mainSettingsShowConnection: config.mainSettingsShowConnection,
                mainSettingsShowBehaviour:  config.mainSettingsShowBehaviour,
                mainSettingsShowIdentity:   config.mainSettingsShowIdentity,
                mainSettingsShowAbout:      config.mainSettingsShowAbout,
                sshKeysConfigured:          config.sshKeysConfigured,
                sshKeyConfiguredForIP:      config.sshKeyConfiguredForIP,
                sshKeyConfiguredForUsername: config.sshKeyConfiguredForUsername,
                autoSyncEnabled:               config.autoSyncEnabled,
                autoSyncInterval:              config.autoSyncInterval,
                nextAutoSyncDate:              config.nextAutoSyncDate,
                nextAutoSyncScheduledInterval: config.nextAutoSyncScheduledInterval,
                pushSyncEnabled:               config.pushSyncEnabled,
                pushSyncDebounce:              config.pushSyncDebounce,
                versionHistoryEnabled:         config.versionHistoryEnabled,
                maxVersionCount:               config.maxVersionCount,
                fastVerify:                    config.fastVerify,
                discoveryMode:                 config.discoveryMode,
                backupHostname:                config.backupHostname,
                lastBackupDiscoveryName:       config.lastBackupDiscoveryName,
                lastBackupIP:                  config.lastBackupIP,
                preferredInterface:            config.preferredInterface,
                preferredInterfaceMAC:         config.preferredInterfaceMAC,
                globalHotkeyEnabled:           config.globalHotkeyEnabled
            )
            do {
                let data = try JSONEncoder().encode(m)
                try data.write(to: mainConfigURL, options: .atomic)
                if lastConfigSaveFailed { lastConfigSaveFailed = false }
            } catch {
                NSLog("[Sync] config_main.json save failed: %@", error.localizedDescription)
                if !lastConfigSaveFailed { lastConfigSaveFailed = true }
            }
        } else {
            let b = BackupConfig(
                mainIP:            config.mainIP,
                destinationFolder: config.destinationFolder,
                effectivePath:     ReceiveMonitor.shared.effectiveDestination,
                launchAtLogin:     config.launchAtLogin,
                lastReceivedTime:  config.lastReceivedTime,
                discoveryMode:     config.discoveryMode,
                networkDiscoveryName: config.networkDiscoveryName,
                minFreeSpaceGB:    max(1, config.minFreeSpaceGB),  // Floor of 1GB
                preferredInterface: config.preferredInterface,
                preferredInterfaceMAC: config.preferredInterfaceMAC,
                backupSettingsShowConnection: config.backupSettingsShowConnection,
                backupSettingsShowIdentity:   config.backupSettingsShowIdentity,
                backupSettingsShowBehaviour:  config.backupSettingsShowBehaviour,
                backupSettingsShowAbout:      config.backupSettingsShowAbout
            )
            do {
                let data = try JSONEncoder().encode(b)
                try data.write(to: backupConfigURL, options: .atomic)
                if lastConfigSaveFailed { lastConfigSaveFailed = false }
            } catch {
                NSLog("[Sync] config_backup.json save failed: %@", error.localizedDescription)
                if !lastConfigSaveFailed { lastConfigSaveFailed = true }
            }
        }
        // Always save shared config (role-independent settings)
        saveSharedConfig()
    }

    private func writeRole(_ role: String) {
        do {
            let data = try JSONEncoder().encode(RoleFile(role: role))
            try data.write(to: roleURL, options: .atomic)
        } catch {
            NSLog("[Sync] role.json save failed: %@", error.localizedDescription)
            if !lastConfigSaveFailed { lastConfigSaveFailed = true }
        }
    }

    // MARK: - Transfer Log

    func appendTransferLogEntry(_ entry: TransferLogEntry) {
        var log = transferLog
        log.insert(entry, at: 0)  // newest first
        if log.count > 100 { log = Array(log.prefix(100)) }  // cap at 100
        transferLog = log
        saveTransferLog()
    }

    private func saveTransferLog() {
        do {
            let data = try JSONEncoder().encode(transferLog)
            try data.write(to: transferLogURL, options: .atomic)
        } catch {
            NSLog("[Sync] transfer_log.json save failed: %@", error.localizedDescription)
        }
    }

    private static func loadTransferLog(from url: URL) -> [TransferLogEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let log = try? JSONDecoder().decode([TransferLogEntry].self, from: data) else {
            NSLog("[Sync] transfer_log.json corrupted, starting fresh")
            return []
        }
        return log
    }

    // MARK: - Trust Foundation (Layer 1)

    private static func loadOrCreateIdentity(from url: URL) -> DeviceIdentity {
        if let data = try? Data(contentsOf: url),
           let ident = try? JSONDecoder().decode(DeviceIdentity.self, from: data) {
            return ident
        }
        let rawHostname = ProcessInfo.processInfo.hostName
        let deviceName = rawHostname
            .replacingOccurrences(of: ".local.", with: "")
            .replacingOccurrences(of: ".local", with: "")
        let newIdentity = DeviceIdentity(
            deviceId: UUID().uuidString,
            deviceName: deviceName,
            createdAt: Date()
        )
        if let data = try? JSONEncoder().encode(newIdentity) {
            try? data.write(to: url, options: .atomic)
        }
        NSLog("[Sync] Created new device identity: %@", newIdentity.deviceId)
        return newIdentity
    }

    private static func loadTrustedPeers(from url: URL) -> [TrustedPeer] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let peers = try? JSONDecoder().decode([TrustedPeer].self, from: data) else {
            NSLog("[Sync] trusted_peers.json corrupted, starting fresh")
            return []
        }
        return peers
    }

    private static func loadTrustLog(from url: URL) -> [TrustEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let log = try? JSONDecoder().decode([TrustEvent].self, from: data) else {
            NSLog("[Sync] trust_log.json corrupted, starting fresh")
            return []
        }
        return log
    }

    func saveIdentity() {
        do {
            let data = try JSONEncoder().encode(identity)
            try data.write(to: identityURL, options: .atomic)
        } catch {
            NSLog("[Sync] identity.json save failed: %@", error.localizedDescription)
        }
    }

    func reloadIdentityFromDisk() {
        identity = Self.loadOrCreateIdentity(from: identityURL)
        NSLog("[Sync] Reloaded identity from disk: %@", identity.deviceId)
    }

    func saveTrustedPeers() {
        do {
            let data = try JSONEncoder().encode(trustedPeers)
            try data.write(to: trustedPeersURL, options: .atomic)
        } catch {
            NSLog("[Sync] trusted_peers.json save failed: %@", error.localizedDescription)
        }
    }

    func appendTrustEvent(_ event: TrustEvent) {
        var log = trustLog
        log.insert(event, at: 0)
        if log.count > 100 { log = Array(log.prefix(100)) }
        trustLog = log
        saveTrustLog()
    }

    private func saveTrustLog() {
        do {
            let data = try JSONEncoder().encode(trustLog)
            try data.write(to: trustLogURL, options: .atomic)
        } catch {
            NSLog("[Sync] trust_log.json save failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Pairing Functions (Layer 2a)

    /// Called on BACKUP when user confirms pairing. Writes pubkey to authorized_keys + records trust.
    /// - Returns: true if successful, false if authorized_keys write failed (caller should fall back to wizard)
    func markPeerAsTrustedOnBackup(peerDeviceId: String, peerName: String,
                                    peerPublicKey: String, peerFingerprint: String) -> Bool {
        let comment = "Sync-Main-\(peerName.replacingOccurrences(of: " ", with: "-"))"
        guard appendPublicKeyToAuthorizedKeys(peerPublicKey, comment: comment) else {
            return false
        }

        let peer = TrustedPeer(
            id: UUID(),
            peerDeviceId: peerDeviceId,
            peerName: peerName,
            peerPublicKey: peerPublicKey,
            peerFingerprint: peerFingerprint,
            role: .main,
            direction: .inbound,
            pairedAt: Date(),
            lastSeen: nil,
            pinnedHostKey: nil
        )
        trustedPeers.append(peer)
        saveTrustedPeers()

        let event = TrustEvent(
            id: UUID(),
            timestamp: Date(),
            eventType: .paired,
            peerDeviceId: peerDeviceId,
            peerName: peerName,
            peerFingerprint: peerFingerprint,
            details: "Accepted pairing request"
        )
        appendTrustEvent(event)

        NSLog("[Sync] Marked peer as trusted on Backup: %@ (%@)", peerName, peerDeviceId)
        return true
    }

    /// Called on MAIN when pairing is acknowledged by Backup. Records trust + enables connection.
    func markPeerAsPairedOnMain(peerDeviceId: String, peerName: String, peerFingerprint: String) {
        let peer = TrustedPeer(
            id: UUID(),
            peerDeviceId: peerDeviceId,
            peerName: peerName,
            peerPublicKey: "",
            peerFingerprint: peerFingerprint,
            role: .backup,
            direction: .outbound,
            pairedAt: Date(),
            lastSeen: nil,
            pinnedHostKey: nil
        )
        trustedPeers.append(peer)
        saveTrustedPeers()

        let event = TrustEvent(
            id: UUID(),
            timestamp: Date(),
            eventType: .paired,
            peerDeviceId: peerDeviceId,
            peerName: peerName,
            peerFingerprint: peerFingerprint,
            details: "Pairing acknowledged by Backup"
        )
        appendTrustEvent(event)

        config.sshKeysConfigured = true
        config.sshKeyConfiguredForIP = config.destinationIP
        config.sshKeyConfiguredForUsername = config.username

        NSLog("[Sync] Marked peer as paired on Main: %@ (%@)", peerName, peerDeviceId)
    }

    /// Removes a peer from the trusted list and (on Backup) from authorized_keys.
    /// - Parameter peerId: The UUID of the TrustedPeer entry to remove
    /// - Returns: true if successful
    func unpairPeer(peerId: UUID) -> Bool {
        guard let index = trustedPeers.firstIndex(where: { $0.id == peerId }) else {
            NSLog("[Sync] Peer not found for unpair: %@", peerId.uuidString)
            return false
        }

        let peer = trustedPeers[index]

        if peer.role == .main && !peer.peerPublicKey.isEmpty {
            if !removePublicKeyFromAuthorizedKeys(peer.peerPublicKey) {
                NSLog("[Sync] Warning: Could not remove key from authorized_keys")
            }
        }

        trustedPeers.remove(at: index)
        saveTrustedPeers()

        let event = TrustEvent(
            id: UUID(),
            timestamp: Date(),
            eventType: .unpaired,
            peerDeviceId: peer.peerDeviceId,
            peerName: peer.peerName,
            peerFingerprint: peer.peerFingerprint,
            details: "Manually unpaired"
        )
        appendTrustEvent(event)

        NSLog("[Sync] Unpaired peer: %@ (%@)", peer.peerName, peer.peerDeviceId)
        return true
    }

    // MARK: - Shared Config

    private static func readSharedConfig(from url: URL) -> SharedConfig {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(SharedConfig.self, from: data) else {
            return SharedConfig()
        }
        return s
    }

    private func saveSharedConfig() {
        let s = SharedConfig(appPresence: config.appPresence)
        do {
            let data = try JSONEncoder().encode(s)
            try data.write(to: sharedConfigURL, options: .atomic)
        } catch {
            NSLog("[Sync] config_shared.json save failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Static loading helpers (static so they can run before init completes)

    private static func readRole(from url: URL) -> String {
        if let data = try? Data(contentsOf: url),
           let rf   = try? JSONDecoder().decode(RoleFile.self, from: data) {
            return rf.role
        }
        return UserDefaults.standard.string(forKey: "syncRole") ?? "main"
    }

    private static func readMainConfig(from url: URL) -> Config {
        var c = Config()
        guard let data = try? Data(contentsOf: url),
              let m   = try? JSONDecoder().decode(MainConfig.self, from: data) else { return c }
        c.sourceFolder              = m.sourceFolder
        c.destinationIP             = m.destinationIP
        c.username                  = m.username
        c.launchAtLogin             = m.launchAtLogin
        c.dryRunEnabled             = m.dryRunEnabled
        c.mainShowConnectionInfo    = m.mainShowConnectionInfo
        c.mainSettingsShowConnection = m.mainSettingsShowConnection
        c.mainSettingsShowBehaviour  = m.mainSettingsShowBehaviour
        c.mainSettingsShowIdentity   = m.mainSettingsShowIdentity ?? false
        c.mainSettingsShowAbout      = m.mainSettingsShowAbout ?? false
        c.sshKeysConfigured         = m.sshKeysConfigured
        c.sshKeyConfiguredForIP     = m.sshKeyConfiguredForIP
        c.sshKeyConfiguredForUsername = m.sshKeyConfiguredForUsername
        c.autoSyncEnabled               = m.autoSyncEnabled
        // Clamp autoSyncInterval: 0 is special (30s), otherwise 1-360 minutes
        let autoInt = m.autoSyncInterval
        c.autoSyncInterval = (autoInt == 0) ? 0 : max(1, min(360, autoInt))
        c.nextAutoSyncDate              = m.nextAutoSyncDate
        // Clamp nextAutoSyncScheduledInterval: same as autoSyncInterval (0 or 1-360)
        let schedInt = m.nextAutoSyncScheduledInterval
        c.nextAutoSyncScheduledInterval = (schedInt == 0) ? 0 : max(1, min(360, schedInt))
        c.pushSyncEnabled               = m.pushSyncEnabled
        // Clamp pushSyncDebounce: 5-300 seconds
        c.pushSyncDebounce              = max(5, min(300, m.pushSyncDebounce))
        c.versionHistoryEnabled         = m.versionHistoryEnabled
        // Clamp maxVersionCount: 3-20, migrate 0 (old unlimited) or <3 to 3, >20 to 20
        let verCount = m.maxVersionCount
        c.maxVersionCount               = max(3, min(20, verCount == 0 ? 3 : verCount))
        c.fastVerify                    = m.fastVerify
        c.discoveryMode                 = m.discoveryMode.isEmpty ? "automatic" : m.discoveryMode
        c.backupHostname                = m.backupHostname
        c.lastBackupDiscoveryName       = m.lastBackupDiscoveryName
        c.lastBackupIP                  = m.lastBackupIP
        c.preferredInterface            = m.preferredInterface
        c.preferredInterfaceMAC         = m.preferredInterfaceMAC
        c.globalHotkeyEnabled           = m.globalHotkeyEnabled
        migrateInterfaceMACIfNeeded(&c)
        return c
    }

    private static func readBackupConfig(from url: URL) -> Config {
        var c = Config()
        guard let data = try? Data(contentsOf: url),
              let b   = try? JSONDecoder().decode(BackupConfig.self, from: data) else { return c }
        c.mainIP = b.mainIP
        c.destinationFolder = b.destinationFolder.isEmpty
            ? (NSHomeDirectory() as NSString).appendingPathComponent("Sync")
            : b.destinationFolder
        c.launchAtLogin    = b.launchAtLogin
        c.lastReceivedTime = b.lastReceivedTime
        c.discoveryMode    = b.discoveryMode.isEmpty ? "automatic" : b.discoveryMode
        c.networkDiscoveryName = b.networkDiscoveryName
        c.minFreeSpaceGB   = max(1, b.minFreeSpaceGB)  // Floor of 1GB
        c.backupSettingsShowConnection = b.backupSettingsShowConnection ?? false
        c.backupSettingsShowIdentity   = b.backupSettingsShowIdentity ?? false
        c.backupSettingsShowBehaviour  = b.backupSettingsShowBehaviour ?? false
        c.backupSettingsShowAbout      = b.backupSettingsShowAbout ?? false
        c.preferredInterface = b.preferredInterface
        c.preferredInterfaceMAC = b.preferredInterfaceMAC
        migrateInterfaceMACIfNeeded(&c)
        return c
    }

    private static func migrateInterfaceMACIfNeeded(_ c: inout Config) {
        guard c.preferredInterfaceMAC.isEmpty, !c.preferredInterface.isEmpty else { return }
        if let interfaces = try? Interfaces.list(),
           let match = interfaces.first(where: { $0.name == c.preferredInterface }),
           let mac = match.mac {
            c.preferredInterfaceMAC = mac
        }
    }

    // MARK: - One-time migration from legacy config.json

    private static func migrateIfNeeded(dir: URL, roleURL: URL,
                                        mainConfigURL: URL, backupConfigURL: URL) {
        let legacyURL = dir.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL),
              let old  = try? JSONDecoder().decode(LegacyConfig.self, from: data) else { return }

        let role = old.role ?? UserDefaults.standard.string(forKey: "syncRole") ?? "main"

        // role.json
        if !FileManager.default.fileExists(atPath: roleURL.path) {
            if let d = try? JSONEncoder().encode(RoleFile(role: role)) {
                try? d.write(to: roleURL, options: .atomic)
            }
        }

        // config_main.json — always written regardless of the old role so both configs are seeded
        if !FileManager.default.fileExists(atPath: mainConfigURL.path) {
            let m = MainConfig(
                sourceFolder:               old.sourceFolder              ?? "",
                destinationIP:              old.destinationIP             ?? "",
                username:                   old.username                  ?? "",
                launchAtLogin:              old.launchAtLogin             ?? false,
                dryRunEnabled:              old.dryRunEnabled             ?? false,
                mainShowConnectionInfo:     old.mainShowConnectionInfo    ?? false,
                mainSettingsShowConnection: false,
                mainSettingsShowBehaviour:  false,
                sshKeysConfigured:          old.sshKeysConfigured         ?? false,
                sshKeyConfiguredForIP:      old.sshKeyConfiguredForIP     ?? "",
                sshKeyConfiguredForUsername: old.sshKeyConfiguredForUsername ?? "",
                pushSyncEnabled:            old.pushSyncEnabled           ?? false,
                pushSyncDebounce:           old.pushSyncDebounce          ?? 10,
                discoveryMode:              old.discoveryMode             ?? "automatic",
                backupHostname:             old.backupHostname            ?? ""
            )
            if let d = try? JSONEncoder().encode(m) {
                try? d.write(to: mainConfigURL, options: .atomic)
            }
        }

        // config_backup.json
        if !FileManager.default.fileExists(atPath: backupConfigURL.path) {
            let defaultFolder = (NSHomeDirectory() as NSString).appendingPathComponent("Sync")
            let b = BackupConfig(
                mainIP:            old.mainIP            ?? "",
                destinationFolder: old.destinationFolder ?? defaultFolder,
                launchAtLogin:     old.launchAtLogin     ?? false,
                lastReceivedTime:  nil,
                discoveryMode:     old.discoveryMode     ?? "automatic",
                networkDiscoveryName: old.networkDiscoveryName ?? ""
            )
            if let d = try? JSONEncoder().encode(b) {
                try? d.write(to: backupConfigURL, options: .atomic)
            }
        }

        try? FileManager.default.removeItem(at: legacyURL)
        NSLog("[Sync] Migrated config.json → role.json + config_main.json + config_backup.json")
    }
}
