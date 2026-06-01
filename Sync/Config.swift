import Foundation

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
    var maxVersionCount: Int = 10

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
    var maxVersionCount: Int = 10
    var discoveryMode: String = "automatic"
    var backupHostname: String = ""
    var lastBackupDiscoveryName: String = ""
    var lastBackupIP: String = ""
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
        didSet { save() }
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

    private let roleURL: URL
    private let mainConfigURL: URL
    private let backupConfigURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        roleURL         = dir.appendingPathComponent("role.json")
        mainConfigURL   = dir.appendingPathComponent("config_main.json")
        backupConfigURL = dir.appendingPathComponent("config_backup.json")

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
        config = loaded
        UserDefaults.standard.set(role, forKey: "syncRole")
    }

    // Saves the current role's settings, then loads the new role's settings.
    // Callers must not set config.role directly — always go through this method.
    func setRole(_ role: String) {
        save()   // flush current role before switching

        var newConfig = role == "backup"
            ? Self.readBackupConfig(from: backupConfigURL)
            : Self.readMainConfig(from: mainConfigURL)
        newConfig.role = role
        // Auto-fill backup username from the system account only when not previously saved.
        if role == "backup" && newConfig.username.isEmpty {
            newConfig.username = NSUserName()
        }

        config = newConfig   // triggers didSet → save() which writes to the new role's file
        writeRole(role)
        UserDefaults.standard.set(role, forKey: "syncRole")
    }

    // MARK: - Persistence

    /// Force a save of the current config (e.g., when effectivePath changes but config fields don't).
    func forceSave() {
        save()
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
                discoveryMode:                 config.discoveryMode,
                backupHostname:                config.backupHostname,
                lastBackupDiscoveryName:       config.lastBackupDiscoveryName,
                lastBackupIP:                  config.lastBackupIP
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
                minFreeSpaceGB:    max(1, config.minFreeSpaceGB)  // Floor of 1GB
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
        c.sshKeysConfigured         = m.sshKeysConfigured
        c.sshKeyConfiguredForIP     = m.sshKeyConfiguredForIP
        c.sshKeyConfiguredForUsername = m.sshKeyConfiguredForUsername
        c.autoSyncEnabled               = m.autoSyncEnabled
        c.autoSyncInterval              = m.autoSyncInterval
        c.nextAutoSyncDate              = m.nextAutoSyncDate
        c.nextAutoSyncScheduledInterval = m.nextAutoSyncScheduledInterval
        c.pushSyncEnabled               = m.pushSyncEnabled
        c.pushSyncDebounce              = m.pushSyncDebounce
        c.versionHistoryEnabled         = m.versionHistoryEnabled
        c.maxVersionCount               = m.maxVersionCount
        c.discoveryMode                 = m.discoveryMode.isEmpty ? "automatic" : m.discoveryMode
        c.backupHostname                = m.backupHostname
        c.lastBackupDiscoveryName       = m.lastBackupDiscoveryName
        c.lastBackupIP                  = m.lastBackupIP
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
        return c
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
