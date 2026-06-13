import SwiftUI
import AppKit
import Network
import SystemConfiguration
import ShowNetwork

private let darkBg = Color(red: 0.12, green: 0.12, blue: 0.12)
private let popoverWidth: CGFloat = 360

// MARK: - Network interface enumeration

struct NetworkInterface: Identifiable, Hashable {
    let id: String       // interface name, e.g. "en0"
    let name: String     // same as id
    let displayName: String  // friendly name, e.g. "Wi-Fi" or "Ethernet"
    let ipv4: String     // e.g. "192.168.1.50"

    var displayLabel: String {
        "\(name) · \(displayName) · \(ipv4)"
    }
}

final class NetworkInterfaceManager: ObservableObject {
    static let shared = NetworkInterfaceManager()

    @Published var availableInterfaces: [NetworkInterface] = []
    @Published var usingFallback: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.sync.interfacemanager", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.updateInterfaces()
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    // Recompute availableInterfaces + usingFallback outside path-monitor events.
    // Path events alone leave the flag stale: a picker change or a transient
    // no-IPv4 moment could pin the "network not found" warning against a NIC
    // that is present and working.
    func refreshAvailability() {
        queue.async { [weak self] in self?.updateInterfaces() }
    }

    private func updateInterfaces() {
        // Enumerate via getifaddrs directly (not NWPathMonitor.availableInterfaces)
        // to include interfaces with self-assigned IPs (169.254.x.x) for direct cables
        var ifaceDict: [String: NetworkInterface] = [:]  // Dedupe by BSD name

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(first) }

        // Build lookup for friendly names from SystemConfiguration
        let friendlyNames = Self.buildFriendlyNameLookup()

        var ptr = Optional(first)
        while let current = ptr {
            let ifa = current.pointee
            let bsdName = String(cString: ifa.ifa_name)

            // Skip loopback
            if bsdName == "lo0" || bsdName.hasPrefix("lo") {
                ptr = ifa.ifa_next
                continue
            }

            // Only include interfaces with IPv4 addresses
            if ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                // Skip if we already have this interface (dedupe)
                if ifaceDict[bsdName] == nil {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, 0, NI_NUMERICHOST)
                    let ip = String(cString: hostname)

                    // Get friendly name from SystemConfiguration, fall back to BSD name
                    let displayName = friendlyNames[bsdName] ?? bsdName

                    ifaceDict[bsdName] = NetworkInterface(
                        id: bsdName,
                        name: bsdName,
                        displayName: displayName,
                        ipv4: ip
                    )
                }
            }
            ptr = ifa.ifa_next
        }

        // Sort by BSD name for consistent ordering
        let interfaces = ifaceDict.values.sorted { $0.name < $1.name }

        let preferredMAC = ConfigStore.shared.config.preferredInterfaceMAC
        let preferredAvailable = preferredMAC.isEmpty || interfaces.contains { iface in
            if let snIface = try? Interfaces.find(byMAC: preferredMAC) {
                return iface.name == snIface.name
            }
            return false
        }

        Task { @MainActor [weak self] in
            // Write-on-change: path events + popover-open refreshes often re-deliver
            // identical lists — don't republish them.
            if self?.availableInterfaces != interfaces {
                self?.availableInterfaces = interfaces
            }
            let newFallback = !preferredMAC.isEmpty && !preferredAvailable
            if self?.usingFallback != newFallback {
                self?.usingFallback = newFallback
            }
            if self?.usingFallback == true {
                if ConfigStore.shared.iconState != .syncing && ConfigStore.shared.iconState != .receiving {
                    ConfigStore.shared.iconState = .warning
                }
            } else if ConfigStore.shared.iconState == .warning {
                ConfigStore.shared.iconState = .idle
            }
        }
    }

    private static func buildFriendlyNameLookup() -> [String: String] {
        var lookup: [String: String] = [:]
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return lookup }
        for iface in interfaces {
            if let bsdName = SCNetworkInterfaceGetBSDName(iface) as String?,
               let displayName = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? {
                lookup[bsdName] = displayName
            }
        }
        return lookup
    }

    static func ipv4Address(for interfaceName: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }
        var ptr = Optional(first)
        while let current = ptr {
            let ifa = current.pointee
            if ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET),
               String(cString: ifa.ifa_name) == interfaceName {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count),
                            nil, 0, NI_NUMERICHOST)
                return String(cString: hostname)
            }
            ptr = ifa.ifa_next
        }
        return nil
    }

    func getEffectiveIP() -> String? {
        let preferredMAC = ConfigStore.shared.config.preferredInterfaceMAC
        if !preferredMAC.isEmpty {
            if let snIface = try? Interfaces.find(byMAC: preferredMAC) {
                return snIface.ipv4
            }
        }
        return availableInterfaces.first?.ipv4
    }

    func getEffectiveInterface() -> NetworkInterface? {
        let preferredMAC = ConfigStore.shared.config.preferredInterfaceMAC
        if !preferredMAC.isEmpty {
            if let snIface = try? Interfaces.find(byMAC: preferredMAC) {
                return availableInterfaces.first { $0.name == snIface.name }
            }
        }
        return availableInterfaces.first
    }
}

// MARK: - Network monitor

final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published var currentIP: String = "—"

    private let monitor = NWPathMonitor()
    private let queue   = DispatchQueue(label: "com.sync.networkmonitor", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let ip = Self.extractIPv4(from: path)
            Task { @MainActor [weak self] in
                self?.currentIP = ip ?? "—"
                // Network lost → red. Network restored from error → grey.
                // Never override success or receiving — those are time-bounded active states.
                if ip == nil {
                    ConfigStore.shared.iconState = .error
                } else if ConfigStore.shared.iconState == .error {
                    ConfigStore.shared.iconState = .idle
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    private static func extractIPv4(from path: NWPath) -> String? {
        let preferredMAC = ConfigStore.shared.config.preferredInterfaceMAC
        if !preferredMAC.isEmpty, let snIface = try? Interfaces.find(byMAC: preferredMAC) {
            for iface in path.availableInterfaces {
                if iface.name == snIface.name, let ip = ipv4Address(for: iface.name) {
                    return ip
                }
            }
        }
        for iface in path.availableInterfaces {
            if iface.type == .loopback { continue }
            if let ip = ipv4Address(for: iface.name) { return ip }
        }
        return nil
    }

    private static func ipv4Address(for interfaceName: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }
        var ptr = Optional(first)
        while let current = ptr {
            let ifa = current.pointee
            if ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET),
               String(cString: ifa.ifa_name) == interfaceName {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count),
                            nil, 0, NI_NUMERICHOST)
                return String(cString: hostname)
            }
            ptr = ifa.ifa_next
        }
        return nil
    }

    // Self-filter truth for the browser: the IP of the interface we actually bind
    // with (the old implementation read currentPath off a never-started monitor).
    static func getCurrentIP() -> String? {
        NetworkInterfaceManager.shared.getEffectiveIP()
    }
}

// MARK: - Storage monitor

final class StorageMonitor: ObservableObject {
    @Published var storageString: String = ""
    @Published var syncFolderString: String = ""
    @Published var syncFolderWritable: Bool = true
    private var timer: Timer?

    func startStorageUpdates() {
        stopStorageUpdates()
        updateStorage()
        updateSyncFolder()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStorage()
            self?.updateSyncFolder()
        }
    }

    func stopStorageUpdates() {
        timer?.invalidate()
        timer = nil
    }

    private func updateStorage() {
        let destPath = ReceiveMonitor.shared.effectiveDestination
        let url = URL(fileURLWithPath: destPath)
        let free: Int64
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let importantFree = values.volumeAvailableCapacityForImportantUsage, importantFree > 0 {
            free = importantFree
        } else {
            let attrs = try? FileManager.default.attributesOfFileSystem(forPath: destPath)
            free = attrs?[.systemFreeSize] as? Int64 ?? 0
        }
        let gb = Double(free) / 1_073_741_824
        let newValue: String
        if gb >= 1.0 {
            newValue = String(format: "%.1f GB free", gb)
        } else {
            let mb = Double(free) / 1_048_576
            newValue = String(format: "%.1f MB free", mb)
        }
        // Write-on-change: 1 s timer — identical strings must not republish
        if storageString != newValue { storageString = newValue }
    }

    private func updateSyncFolder() {
        let syncFolder = URL(fileURLWithPath: ReceiveMonitor.shared.effectiveDestination)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // TCC writability test — isWritableFile only checks Unix permissions,
            // not TCC. A real create-and-delete confirms macOS allows actual writes.
            let testFile = syncFolder.appendingPathComponent(".syncwritetest")
            let writable = FileManager.default.createFile(atPath: testFile.path, contents: Data())
            if writable { try? FileManager.default.removeItem(at: testFile) }
            guard writable else {
                Task { @MainActor in
                    if self.syncFolderWritable { self.syncFolderWritable = false }
                }
                return
            }
            guard let enumerator = FileManager.default.enumerator(
                at: syncFolder,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: .skipsHiddenFiles
            ) else {
                Task { @MainActor in
                    if !self.syncFolderWritable { self.syncFolderWritable = true }
                    if self.syncFolderString != "0 files · empty" { self.syncFolderString = "0 files · empty" }
                }
                return
            }
            var count: Int = 0
            var totalBytes: Int64 = 0
            for case let url as URL in enumerator {
                guard let res = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      res.isRegularFile == true else { continue }
                count += 1
                totalBytes += Int64(res.fileSize ?? 0)
            }
            let sizeStr: String
            if totalBytes < 1_048_576 {
                sizeStr = String(format: "%.1f KB", Double(totalBytes) / 1_024)
            } else if totalBytes < 1_073_741_824 {
                sizeStr = String(format: "%.1f MB", Double(totalBytes) / 1_048_576)
            } else {
                sizeStr = String(format: "%.1f GB", Double(totalBytes) / 1_073_741_824)
            }
            let fileWord = count == 1 ? "file" : "files"
            let result = count == 0 ? "0 files · empty" : "\(count) \(fileWord) · \(sizeStr)"
            Task { @MainActor in
                // Write-on-change: 1 s timer — identical values must not republish
                if !self.syncFolderWritable { self.syncFolderWritable = true }
                if self.syncFolderString != result { self.syncFolderString = result }
            }
        }
    }

    deinit { stopStorageUpdates() }
}

// MARK: - Receive monitor

enum ReceiveState { case idle, receiving, done }

enum BackupVerifyStatus: Equatable {
    case idle
    case requested       // Request sent to Main
    case verifying       // Main is running verify
    case verified        // All files match
    case differs(Int)    // N files differ
    case failed(String)  // Error message
    case manualHint      // Manual mode: waiting for Main popover to open

    var label: String {
        switch self {
        case .idle:           return ""
        case .requested:      return "Requesting verify..."
        case .verifying:      return "Main is verifying..."
        case .verified:       return "Verified — all files match"
        case .differs(let n): return "\(n) file\(n == 1 ? "" : "s") differ — re-sync recommended"
        case .failed(let m):  return m
        case .manualHint:     return "Open Main's Sync window for verify to run"
        }
    }

    var color: Color {
        switch self {
        case .idle:       return .gray
        case .requested:  return .yellow
        case .verifying:  return .yellow
        case .verified:   return .green
        case .differs:    return .orange
        case .failed:     return .red
        case .manualHint: return .yellow
        }
    }
}

final class ReceiveMonitor: ObservableObject {
    static let shared = ReceiveMonitor()

    @Published var state: ReceiveState    = .idle
    @Published var receivePercent: Int    = -1    // -1 = unknown; 0–100 during transfer
    @Published var receiveDetails: String = ""    // "4 files · 620 MB in 0:42"
    @Published var receivedBytes: Int64   = -1    // from .sync_progress bytesDone; -1 = unknown
    @Published var expectedBytes: Int64   = -1    // from .sync_progress bytesTotal; -1 = unknown
    @Published var receiveRate: Double?   = nil   // smoothed bytes/sec (≥3 samples); nil = calculating
    private var receiveRateSamples: [(time: Date, bytes: Int64)] = []
    @Published var usingFallback: Bool    = false // True when custom folder missing, using ~/Sync
    @Published var verifyStatus: BackupVerifyStatus = .idle  // Backup-initiated verify status
    // `lastReceivedTime` now lives on ConfigStore.config so it survives relaunch.

    /// The ACTUAL destination path being used right now (fallback ~/Sync or user's chosen folder)
    var effectiveDestination: String {
        if usingFallback {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sync").path
        }
        return ConfigStore.shared.config.destinationFolder
    }

    private var pollTimer:   Timer?
    private var isChecking:  Bool = false
    var stopAfterTransfer:   Bool = false
    var isMonitoring: Bool { pollTimer != nil }

    // FIX 3: Self-heal timeout - track when receiving started without progress
    private var receivingStartTime: Date?
    private var lastProgressTime: Date?
    private let staleTimeoutSeconds: TimeInterval = 45  // Clear stale signals after 45s of no progress

    // Volume mount/unmount observers for instant drive detection
    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?

    private init() {}

    // One reset for every transfer-progress field — called wherever a transfer
    // ends (done/cancel/self-heal) so the bar resolves cleanly and never goes stale.
    private func resetProgressFields() {
        receivePercent = -1
        receivedBytes  = -1
        expectedBytes  = -1
        receiveRate    = nil
        receiveRateSamples = []
    }

    func startMonitoring() {
        validateDestination()
        clearStaleSignalFiles()  // FIX 4: Clean slate on restart/launch
        state          = .idle
        resetProgressFields()
        receiveDetails = ""
        receivingStartTime = nil
        lastProgressTime = nil
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkSignalFiles()
        }
        checkSignalFiles()
        setupVolumeObservers()
    }

    private func setupVolumeObservers() {
        // Remove any existing observers first (avoid duplicates on role switch)
        removeVolumeObservers()

        let nc = NSWorkspace.shared.notificationCenter

        // Drive unmounted - check if it affects our destination
        unmountObserver = nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            let configPath = ConfigStore.shared.config.destinationFolder
            // If the unmounted volume is a prefix of our destination, we lost access
            if configPath.hasPrefix(volumeURL.path) {
                NSLog("[Backup] Volume unmounted: %@ - destination unavailable", volumeURL.path)
                self.validateDestination()
            }
        }

        // Drive mounted - check if our destination came back
        mountObserver = nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            NSLog("[Backup] Volume mounted - rechecking destination")
            self.validateDestination()
        }
    }

    private func removeVolumeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        if let obs = unmountObserver {
            nc.removeObserver(obs)
            unmountObserver = nil
        }
        if let obs = mountObserver {
            nc.removeObserver(obs)
            mountObserver = nil
        }
    }

    // FIX 4: Clear stale signal files from previous session (crash, force-quit, power loss)
    func clearStaleSignalFiles() {
        let base = URL(fileURLWithPath: effectiveDestination)
        let fm = FileManager.default
        let signalFiles = [SignalFile.start, SignalFile.progress, SignalFile.complete, SignalFile.refused,
                           SignalFile.renameRequest, SignalFile.unpairRequest,
                           SignalFile.verifyRequest, SignalFile.verifyResult]
        for filename in signalFiles {
            let path = base.appendingPathComponent(filename)
            if fm.fileExists(atPath: path.path) {
                try? fm.removeItem(at: path)
                NSLog("[Backup] Cleared stale signal file: %@", filename)
            }
        }
    }

    func validateDestination() {
        let fm = FileManager.default
        let configPath = ConfigStore.shared.config.destinationFolder
        let defaultPath = fm.homeDirectoryForCurrentUser.appendingPathComponent("Sync").path
        let isDefault = configPath == defaultPath || configPath.isEmpty
        let wasFallback = usingFallback

        if !isDefault && fm.fileExists(atPath: configPath) && fm.isWritableFile(atPath: configPath) {
            // Custom folder is available (or came back)
            usingFallback = false
            if wasFallback {
                // Drive returned! Update TXT (auto) + config file (manual)
                BonjourAdvertiser.shared.updateTXTRecord()
                ConfigStore.shared.forceSave()
                // Clear warning icon (only if it was warning)
                if ConfigStore.shared.iconState == .warning {
                    ConfigStore.shared.iconState = .idle
                }
            }
            return
        }
        // Fall back to ~/Sync
        let fallback = fm.homeDirectoryForCurrentUser.appendingPathComponent("Sync")
        if !fm.fileExists(atPath: fallback.path) {
            try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        }
        if !isDefault {
            usingFallback = true
            if !wasFallback {
                // Just started fallback - update TXT (auto) + config file (manual)
                BonjourAdvertiser.shared.updateTXTRecord()
                ConfigStore.shared.forceSave()
                // Set warning icon (only if not in higher-priority state)
                let current = ConfigStore.shared.iconState
                if current == .idle || current == .notConfigured || current == .success {
                    ConfigStore.shared.iconState = .warning
                }
            }
        } else {
            usingFallback = false
        }
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer      = nil
        isChecking     = false
        state          = .idle
        resetProgressFields()
        ConfigStore.shared.isSyncing = false
        removeVolumeObservers()
        // lastReceivedTime preserved across close/open
    }

    deinit {
        pollTimer?.invalidate()
        removeVolumeObservers()
    }

    private func checkSignalFiles() {
        guard !isChecking else { return }
        isChecking = true
        let destPath = effectiveDestination  // Capture before background dispatch
        let minFreeGB = ConfigStore.shared.config.minFreeSpaceGB  // Capture on main before dispatch
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let base         = URL(fileURLWithPath: destPath)
            let completePath = base.appendingPathComponent(SignalFile.complete)
            let progressPath = base.appendingPathComponent(SignalFile.progress)
            let startPath    = base.appendingPathComponent(SignalFile.start)
            let renamePath   = base.appendingPathComponent(SignalFile.renameRequest)
            let fm           = FileManager.default

            // Clear low-space error when space recovers (honest self-clear on every poll cycle)
            // Only clear if .sync_refused exists (we wrote it) AND space is now OK
            let refusedPath = base.appendingPathComponent(SignalFile.refused)
            let minFreeBytes: Int64 = Int64(minFreeGB) * 1024 * 1024 * 1024
            if fm.fileExists(atPath: refusedPath.path),
               let freeBytes = BonjourAdvertiser.getFreeSpace(path: base.path),
               freeBytes >= minFreeBytes {
                try? fm.removeItem(at: refusedPath)  // Clean up the refusal
                Task { @MainActor in
                    if ConfigStore.shared.iconState == .error {
                        ConfigStore.shared.iconState = .idle
                    }
                }
            }

            // Handle remote rename request from Main
            if fm.fileExists(atPath: renamePath.path) {
                let content = (try? String(contentsOf: renamePath, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? fm.removeItem(at: renamePath) // Cleanup immediately
                if Self.isValidBonjourName(content) {
                    DispatchQueue.main.async {
                        ConfigStore.shared.config.networkDiscoveryName = content
                        BonjourAdvertiser.shared.restart()
                    }
                }
            }

            // Layer 4: unpair request from Main — validate the deviceId against our
            // trusted peers; on match, our own unpairPeer removes the Main's key from
            // authorized_keys and logs the unpaired event. Mismatch: ignore (deleted).
            let unpairPath = base.appendingPathComponent(SignalFile.unpairRequest)
            if fm.fileExists(atPath: unpairPath.path) {
                let content = (try? String(contentsOf: unpairPath, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? fm.removeItem(at: unpairPath) // Cleanup immediately
                if let data = content.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let mainId = json["mainId"] as? String, !mainId.isEmpty {
                    DispatchQueue.main.async {
                        if let peer = ConfigStore.shared.trustedPeers.first(where: { $0.peerDeviceId == mainId && $0.role == .main }) {
                            _ = ConfigStore.shared.unpairPeer(peerId: peer.id)
                            NSLog("[Backup] Forgot Main on its request: %@", mainId)
                        } else {
                            NSLog("[Backup] Ignored unpair request from unknown deviceId: %@", mainId)
                        }
                    }
                }
            }

            if fm.fileExists(atPath: completePath.path) {
                let content = (try? String(contentsOf: completePath, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? fm.removeItem(at: completePath)
                try? fm.removeItem(at: progressPath)
                try? fm.removeItem(at: startPath)
                let details = Self.parseCompleteFile(content)
                Task { @MainActor [weak self] in
                    self?.isChecking      = false
                    guard let self else { return }
                    self.receiveDetails   = details
                    self.resetProgressFields()
                    self.state            = .done
                    ConfigStore.shared.config.lastReceivedTime = Date()
                    ConfigStore.shared.isSyncing = false
                    ConfigStore.shared.iconState = .success
                    // Storage truth: re-publish free space — but delayed 5 s so the
                    // snapshot measures settled reality, not mid-write APFS churn
                    // (purgeable-space estimate drifts right after a transfer).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        // Re-check the guard: mode may have changed during the delay,
                        // and updateTXTRecord would START the advertiser in manual mode.
                        if ConfigStore.shared.config.discoveryMode == "automatic" {
                            BonjourAdvertiser.shared.updateTXTRecord()
                        }
                    }
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                        guard let self, self.state == .done else { return }
                        self.state          = .idle
                        self.receiveDetails = ""
                        if self.stopAfterTransfer {
                            self.stopMonitoring()
                            self.stopAfterTransfer = false
                        }
                    }
                }
                return
            }

            // Check for verify result from Main
            let verifyResultPath = base.appendingPathComponent(SignalFile.verifyResult)
            if fm.fileExists(atPath: verifyResultPath.path) {
                let content = (try? String(contentsOf: verifyResultPath, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? fm.removeItem(at: verifyResultPath)
                let status = Self.parseVerifyResult(content)
                Task { @MainActor [weak self] in
                    self?.isChecking = false
                    guard let self else { return }
                    self.verifyStatus = status
                    // Clear after 10 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                        guard let self else { return }
                        if case .verified = self.verifyStatus { self.verifyStatus = .idle }
                        if case .differs = self.verifyStatus { self.verifyStatus = .idle }
                        if case .failed = self.verifyStatus { self.verifyStatus = .idle }
                    }
                }
                return
            }

            if fm.fileExists(atPath: progressPath.path) {
                let content = (try? String(contentsOf: progressPath, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let progress = Self.parseProgressFile(content)
                Task { @MainActor [weak self] in
                    self?.isChecking = false
                    guard let self else { return }
                    // Write-on-change: 0.5 s poll vs 1 s payload cadence — every other
                    // tick re-reads identical values.
                    if self.receivePercent != progress.percent { self.receivePercent = progress.percent }
                    if self.receivedBytes != progress.bytesDone { self.receivedBytes = progress.bytesDone }
                    if self.expectedBytes != progress.bytesTotal { self.expectedBytes = progress.bytesTotal }
                    // Smoothed rate from bytesDone deltas (rolling ~5-sample window)
                    if progress.bytesDone >= 0 {
                        if let last = self.receiveRateSamples.last, progress.bytesDone < last.bytes {
                            self.receiveRateSamples = []  // new transfer — reset window
                        }
                        self.receiveRateSamples.append((time: Date(), bytes: progress.bytesDone))
                        if self.receiveRateSamples.count > 5 { self.receiveRateSamples.removeFirst() }
                        if self.receiveRateSamples.count >= 3,
                           let first = self.receiveRateSamples.first, let last = self.receiveRateSamples.last,
                           last.time.timeIntervalSince(first.time) > 0 {
                            self.receiveRate = Double(last.bytes - first.bytes) / last.time.timeIntervalSince(first.time)
                        }
                    }
                    self.lastProgressTime = Date()  // FIX 3: track progress
                    if self.state != .receiving {
                        self.state = .receiving
                        self.receivingStartTime = Date()
                        ConfigStore.shared.isSyncing = true
                        ConfigStore.shared.iconState = .receiving
                    }
                }
                return
            }

            if fm.fileExists(atPath: startPath.path) {
                // Minimum free space check — refuse ONLY on confirmed real value under threshold
                // nil = unknown = allow sync to proceed (never refuse on unknown)
                let minFreeBytes: Int64 = Int64(minFreeGB) * 1024 * 1024 * 1024
                if let freeBytes = BonjourAdvertiser.getFreeSpace(path: base.path),
                   freeBytes < minFreeBytes {
                    let refusedPath = base.appendingPathComponent(SignalFile.refused)
                    try? "low_space".write(to: refusedPath, atomically: true, encoding: .utf8)
                    Task { @MainActor [weak self] in
                        self?.isChecking = false
                        ConfigStore.shared.iconState = .error
                    }
                    return
                }

                // FIX 3: Self-heal timeout - if .sync_start present but no progress for 45s, clear it
                Task { @MainActor [weak self] in
                    self?.isChecking = false
                    guard let self else { return }

                    let now = Date()
                    if self.state != .receiving {
                        // First time seeing .sync_start
                        self.state = .receiving
                        self.receivingStartTime = now
                        self.lastProgressTime = nil
                        ConfigStore.shared.isSyncing = true
                        ConfigStore.shared.iconState = .receiving
                    } else if let startTime = self.receivingStartTime {
                        // Already receiving - check for stale timeout
                        let refTime = self.lastProgressTime ?? startTime
                        if now.timeIntervalSince(refTime) > self.staleTimeoutSeconds {
                            NSLog("[Backup] Self-heal: clearing stale signal files after %.0fs timeout", now.timeIntervalSince(startTime))
                            self.clearStaleSignalFiles()
                            self.state = .idle
                            self.resetProgressFields()
                            self.receivingStartTime = nil
                            self.lastProgressTime = nil
                            ConfigStore.shared.isSyncing = false
                            ConfigStore.shared.iconState = .idle
                            return
                        }
                    }
                    self.resetProgressFields()
                }
                return
            }

            // No signal files — if we were receiving, Main finished or was cancelled
            Task { @MainActor [weak self] in
                self?.isChecking = false
                guard let self else { return }
                if self.state == .receiving {
                    self.state          = .idle
                    self.resetProgressFields()
                    self.receivingStartTime = nil
                    self.lastProgressTime = nil
                    ConfigStore.shared.isSyncing = false
                    ConfigStore.shared.iconState = .idle
                }
            }
        }
    }

    private static func parseCompleteFile(_ content: String) -> String {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Received"
        }
        let files    = (json["totalFiles"] as? NSNumber)?.intValue   ?? 0
        let bytes    = (json["totalBytes"] as? NSNumber)?.int64Value ?? 0
        let duration = (json["duration"]   as? NSNumber)?.intValue   ?? 0
        var parts: [String] = []
        if files > 0 { parts.append("\(files) \(files == 1 ? "file" : "files")") }
        if bytes > 0 { parts.append(formatBytes(bytes)) }
        let base = parts.isEmpty ? "Received" : parts.joined(separator: " · ")
        guard duration > 0 else { return base }
        return "\(base) in \(duration / 60):\(String(format: "%02d", duration % 60))"
    }

    // Extended payload {"percent","bytesDone","bytesTotal"}; falls back to
    // percent-only (older Mains) — bytes report -1 = unknown.
    private static func parseProgressFile(_ content: String) -> (percent: Int, bytesDone: Int64, bytesTotal: Int64) {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (-1, -1, -1)
        }
        let rawPct = (json["percent"] as? NSNumber)?.intValue ?? -1
        let pct = rawPct < 0 ? -1 : max(0, min(100, rawPct))
        let done = (json["bytesDone"] as? NSNumber)?.int64Value ?? -1
        let total = (json["bytesTotal"] as? NSNumber)?.int64Value ?? -1
        return (pct, done, total <= 0 ? -1 : total)
    }

    private static func parseVerifyResult(_ content: String) -> BackupVerifyStatus {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? String else {
            return .failed("Verify failed — invalid response")
        }
        if result == "ok" {
            return .verified
        } else if result.hasPrefix("differs:") {
            let countStr = result.dropFirst("differs:".count)
            if let count = Int(countStr) {
                return .differs(count)
            }
            return .differs(0)
        } else {
            return .failed("Verify failed — couldn't reach Main")
        }
    }

    private static func isValidBonjourName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 63 else { return false }
        // Disallow control characters and forward slash (invalid in Bonjour names)
        for char in name.unicodeScalars {
            if char.value < 32 || char == "/" { return false }
        }
        return true
    }
}

// MARK: - Backup view

struct BackupView: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @StateObject private var storageMonitor = StorageMonitor()
    @ObservedObject private var receiveMonitor = ReceiveMonitor.shared
    @ObservedObject private var interfaceManager = NetworkInterfaceManager.shared
    @ObservedObject private var advertiser  = BonjourAdvertiser.shared
    @State private var showQuitConfirm = false
    @State private var backupEtaText = ""  // smoothed ETA; frozen on stall, never bounces
    var onSettingsTapped: () -> Void = {}

    private var isAutomatic: Bool { store.config.discoveryMode == "automatic" }

    var body: some View {
        if showQuitConfirm {
            InlineConfirm(
                title: "Quit Sync?",
                message: isReceiving
                    ? "A backup is in progress and will be interrupted."
                    : "Any sync in progress will stop.",
                confirmLabel: "Quit",
                confirmColor: .red,
                onCancel: {
                    store.pendingQuitConfirm = false
                    showQuitConfirm = false
                },
                onConfirm: {
                    store.pendingQuitConfirm = false
                    receiveMonitor.clearStaleSignalFiles()  // Clean up before quit
                    (NSApp.delegate as? AppDelegate)?.quitConfirmed = true
                    NSApp.terminate(nil)
                }
            )
            .frame(width: popoverWidth)
            .background(darkBg)
            .preferredColorScheme(.dark)
            .ignoresSafeArea()
        } else {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Circle()
                    .fill(headerColor)
                    .frame(width: 8, height: 8)
                Text("Sync")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text(headerStatus)
                    .font(.system(size: 12))
                    .foregroundColor(headerColor)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            if isAutomatic {
                // Network Discovery — large name, small IP below
                VStack(spacing: 4) {
                    Text("Network Discovery")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.45))
                    if case .advertising(let name) = advertiser.state {
                        Text(name)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text(effectiveDisplayIP == "—" ? "Not set" : effectiveDisplayIP)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(white: 0.55))
                    } else {
                        Text("Setting up...")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            } else {
                // Manual mode — IP large, as before
                VStack(spacing: 4) {
                    Text("This Mac's IP")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.45))
                    Text(effectiveDisplayIP == "—" ? "Not set" : effectiveDisplayIP)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(effectiveDisplayIP == "—" ? Color(white: 0.55) : .white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }

            Divider()

            // BACKUP User
            VStack(spacing: 4) {
                Text("Backup User")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.45))
                Text(NSUserName())
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Divider()

            // Info rows
            VStack(alignment: .leading, spacing: 6) {
                infoRow(
                    label: "Last received",
                    value: store.config.lastReceivedTime.map { formatTime($0) } ?? "Never"
                )
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if receiveMonitor.usingFallback {
                            // Show intended destination with unavailable indicator
                            Text("\(shortenPath(store.config.destinationFolder)) (drive unavailable)")
                                .font(.system(size: 12))
                                .foregroundColor(.orange)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(shortenPath(receiveMonitor.effectiveDestination))
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if !storageMonitor.syncFolderWritable {
                            HStack(alignment: .top, spacing: 3) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 6, height: 6)
                                Text("Cannot write — see Settings")
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else if receiveMonitor.state == .receiving {
                            Text("Receiving…")
                                .font(.system(size: 12))
                                .foregroundColor(.yellow)
                                .lineLimit(1)
                        } else if receiveMonitor.state == .done {
                            Text(receiveMonitor.receiveDetails.isEmpty ? "✓ Received" : "✓ \(receiveMonitor.receiveDetails)")
                                .font(.system(size: 12))
                                .foregroundColor(.green)
                                .lineLimit(1)
                        } else {
                            Text(storageMonitor.syncFolderString)
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                    }
                    if receiveMonitor.state == .receiving && storageMonitor.syncFolderWritable {
                        VStack(alignment: .leading, spacing: 5) {
                            if let frac = receiveFraction {
                                ProgressView(value: frac)
                                    .progressViewStyle(.linear)
                                    .tint(.yellow)
                                HStack {
                                    Text(receiveByteText)
                                    Spacer()
                                    Text(backupEtaText)
                                }
                                .font(.system(size: 11))
                                .foregroundColor(.yellow)
                            } else {
                                // Totals unknown (older Main or estimate failed) — honest indeterminate bar
                                ProgressView()
                                    .progressViewStyle(.linear)
                                    .tint(.yellow)
                                if receiveMonitor.receivedBytes >= 0 {
                                    Text("\(formatBytes(receiveMonitor.receivedBytes)) received")
                                        .font(.system(size: 11))
                                        .foregroundColor(.yellow)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                    if receiveMonitor.usingFallback {
                        Text("Syncing to ~/Sync until drive returns")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }
                infoRow(label: "Storage", value: storageMonitor.storageString)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            // Verify section
            VStack(alignment: .leading, spacing: 8) {
                if receiveMonitor.verifyStatus == .idle {
                    Button {
                        requestVerify()
                    } label: {
                        Text("Verify Backup")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("Ask Main to verify all files match")
                } else {
                    Text(receiveMonitor.verifyStatus.label)
                        .font(.system(size: 12))
                        .foregroundColor(receiveMonitor.verifyStatus.color)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            // Footer
            HStack {
                Button { onSettingsTapped() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.6))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")

                Spacer()

                Button("Quit") { showQuitConfirm = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.5))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        .frame(width: popoverWidth)
        .background(darkBg)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .onAppear {
            storageMonitor.startStorageUpdates()
            receiveMonitor.startMonitoring()
            NetworkInterfaceManager.shared.refreshAvailability()  // fresh IP label
            if store.config.username.isEmpty {
                store.config.username = NSUserName()
            }
        }
        .onDisappear {
            storageMonitor.stopStorageUpdates()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in
            storageMonitor.startStorageUpdates()
            receiveMonitor.stopAfterTransfer = false
            receiveMonitor.validateDestination()  // Recheck if drive returned
            if !receiveMonitor.isMonitoring { receiveMonitor.startMonitoring() }
            NetworkInterfaceManager.shared.refreshAvailability()  // fresh IP label
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in
            storageMonitor.stopStorageUpdates()
        }
        .onChange(of: store.pendingQuitConfirm) { newValue in
            if newValue { showQuitConfirm = true }
        }
        .onChange(of: receiveMonitor.receivedBytes) { bytes in
            // ETA smoothing: update only while moving with a known total; freeze on
            // stall rather than inflate; clear when the transfer ends.
            guard receiveMonitor.state == .receiving, bytes >= 0,
                  receiveMonitor.expectedBytes > 0 else {
                backupEtaText = ""
                return
            }
            if let rate = receiveMonitor.receiveRate {
                if rate > 1024 {
                    let remaining = Double(receiveMonitor.expectedBytes - bytes) / rate
                    backupEtaText = formatETA(remaining)
                }
                // else: stalled — keep the last ETA text
            } else if backupEtaText.isEmpty {
                backupEtaText = "calculating…"
            }
        }
        } // end else
    }

    // MARK: - Header helpers

    private var headerColor: Color {
        receiveMonitor.state == .receiving ? .yellow : .green
    }

    private var headerStatus: String {
        receiveMonitor.state == .receiving ? "Receiving" : "Ready"
    }

    private var isReceiving: Bool { receiveMonitor.state == .receiving }

    // Display the IP of the interface the engine actually binds with — same truth
    // as getEffectiveIP (e.g. 169.254.x when the cable is selected), not the
    // system's satisfied-path IP (which is Wi-Fi when the cable has no internet).
    private var effectiveDisplayIP: String {
        interfaceManager.getEffectiveIP() ?? "—"
    }

    // Bar fraction: prefer byte-accurate (extended payload), fall back to percent,
    // nil = indeterminate (older Main or estimate failed).
    private var receiveFraction: Double? {
        if receiveMonitor.receivedBytes >= 0, receiveMonitor.expectedBytes > 0 {
            return min(Double(receiveMonitor.receivedBytes) / Double(receiveMonitor.expectedBytes), 1.0)
        }
        if receiveMonitor.receivePercent >= 0 {
            return Double(receiveMonitor.receivePercent) / 100.0
        }
        return nil
    }

    private var receiveByteText: String {
        let pct = Int((receiveFraction ?? 0) * 100)
        if receiveMonitor.receivedBytes >= 0, receiveMonitor.expectedBytes > 0 {
            return "\(pct)% · \(formatBytes(receiveMonitor.receivedBytes)) of \(formatBytes(receiveMonitor.expectedBytes))"
        }
        return "\(pct)%"
    }

    // MARK: - Row helpers

    private var bonjourDotColor: Color {
        switch advertiser.state {
        case .idle:        return Color(white: 0.55)
        case .advertising: return .green
        case .failed:      return .red
        }
    }

    private var bonjourLabel: String {
        switch advertiser.state {
        case .idle:                       return "Starting..."
        case .advertising(let name):      return "Advertising as \"\(name)\""
        case .failed:                     return "Network discovery unavailable"
        }
    }

    private func infoRow(label: String, value: String, dim: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.5))
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(dim ? Color(white: 0.38) : .white)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func requestVerify() {
        let nonce = UUID().uuidString.prefix(8).lowercased()
        receiveMonitor.verifyStatus = .requested

        if store.config.discoveryMode == "automatic" {
            // AUTO mode: Update Bonjour TXT record with verify request nonce
            BonjourAdvertiser.shared.verifyRequestNonce = String(nonce)
            BonjourAdvertiser.shared.updateTXTRecord()

            // Set 90s timeout for response
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak receiveMonitor] in
                guard let rm = receiveMonitor, rm.verifyStatus == .requested else { return }
                rm.verifyStatus = .failed("Verify timed out — Main may not be reachable")
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak receiveMonitor] in
                    if receiveMonitor?.verifyStatus == .failed("Verify timed out — Main may not be reachable") {
                        receiveMonitor?.verifyStatus = .idle
                    }
                }
            }
        } else {
            // MANUAL mode: Write .verify_request file and show hint
            let destPath = receiveMonitor.effectiveDestination
            let requestPath = URL(fileURLWithPath: destPath).appendingPathComponent(SignalFile.verifyRequest)
            let content = "{\"nonce\":\"\(nonce)\",\"ts\":\(Int(Date().timeIntervalSince1970))}"
            try? content.write(to: requestPath, atomically: true, encoding: .utf8)

            // Show manual mode hint
            receiveMonitor.verifyStatus = .manualHint

            // Set 90s timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak receiveMonitor] in
                guard let rm = receiveMonitor else { return }
                if rm.verifyStatus == .manualHint || rm.verifyStatus == .requested {
                    rm.verifyStatus = .failed("Verify timed out — open Main's Sync window first")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak receiveMonitor] in
                        if case .failed = receiveMonitor?.verifyStatus {
                            receiveMonitor?.verifyStatus = .idle
                        }
                    }
                }
            }
        }
    }

}
