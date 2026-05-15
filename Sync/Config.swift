import Foundation

struct Config: Codable {
    var role: String = "main"
    var sourceFolder: String = ""
    var destinationFolder: String = ""
    var destinationIP: String = ""
    var username: String = ""
    var launchAtLogin: Bool = false
    var notifyOnComplete: Bool = true

    var isReadyToSync: Bool {
        !sourceFolder.isEmpty && !destinationFolder.isEmpty && !destinationIP.isEmpty
    }
}

final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: Config {
        didSet { save() }
    }

    // Transient — not persisted. Set by SyncEngine during active rsync.
    @Published var isSyncing: Bool = false

    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            config = decoded
        } else {
            var fresh = Config()
            fresh.username = NSUserName()
            config = fresh
            // Seed role from UserDefaults if set before first launch
            if let storedRole = UserDefaults.standard.string(forKey: "syncRole") {
                config.role = storedRole
            }
        }

        // Keep UserDefaults in sync with config file on load
        UserDefaults.standard.set(config.role, forKey: "syncRole")
    }

    func setRole(_ role: String) {
        config.role = role
        UserDefaults.standard.set(role, forKey: "syncRole")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
