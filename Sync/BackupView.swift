import SwiftUI
import AppKit
import Network

private let darkBg = Color(red: 0.12, green: 0.12, blue: 0.12)
private let popoverWidth: CGFloat = 360

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

    static func getCurrentIP() -> String? {
        let monitor = NWPathMonitor()
        let currentPath = monitor.currentPath
        return extractIPv4(from: currentPath)
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
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: destPath)
        let free = attrs?[.systemFreeSize] as? Int64 ?? 0
        let gb = Double(free) / 1_073_741_824
        if gb >= 1.0 {
            storageString = String(format: "%.1f GB free", gb)
        } else {
            let mb = Double(free) / 1_048_576
            storageString = String(format: "%.1f MB free", mb)
        }
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
                Task { @MainActor in self.syncFolderWritable = false }
                return
            }
            guard let enumerator = FileManager.default.enumerator(
                at: syncFolder,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: .skipsHiddenFiles
            ) else {
                Task { @MainActor in
                    self.syncFolderWritable = true
                    self.syncFolderString = "0 files · empty"
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
                self.syncFolderWritable = true
                self.syncFolderString = result
            }
        }
    }

    deinit { stopStorageUpdates() }
}

// MARK: - Receive monitor

enum ReceiveState { case idle, receiving, done }

final class ReceiveMonitor: ObservableObject {
    static let shared = ReceiveMonitor()

    @Published var state: ReceiveState    = .idle
    @Published var receivePercent: Int    = -1    // -1 = unknown; 0–100 during transfer
    @Published var receiveDetails: String = ""    // "4 files · 620 MB in 0:42"
    @Published var usingFallback: Bool    = false // True when custom folder missing, using ~/Sync
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

    func startMonitoring() {
        validateDestination()
        clearStaleSignalFiles()  // FIX 4: Clean slate on restart/launch
        state          = .idle
        receivePercent = -1
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
        let signalFiles = [".sync_start", ".sync_progress", ".sync_complete", ".sync_refused"]
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
        receivePercent = -1
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let base         = URL(fileURLWithPath: destPath)
            let completePath = base.appendingPathComponent(".sync_complete")
            let progressPath = base.appendingPathComponent(".sync_progress")
            let startPath    = base.appendingPathComponent(".sync_start")
            let renamePath   = base.appendingPathComponent(".sync_rename_request")
            let fm           = FileManager.default

            // Clear low-space error when space recovers (honest self-clear on every poll cycle)
            // Only clear if .sync_refused exists (we wrote it) AND space is now OK
            let refusedPath = base.appendingPathComponent(".sync_refused")
            let minFreeBytes: Int64 = 2 * 1024 * 1024 * 1024 // 2GB
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
                    self.receivePercent   = -1
                    self.state            = .done
                    ConfigStore.shared.config.lastReceivedTime = Date()
                    ConfigStore.shared.isSyncing = false
                    ConfigStore.shared.iconState = .success
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

            if fm.fileExists(atPath: progressPath.path) {
                let content = (try? String(contentsOf: progressPath, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let pct = Self.parseProgressFile(content)
                Task { @MainActor [weak self] in
                    self?.isChecking = false
                    guard let self else { return }
                    self.receivePercent = pct
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
                // 2GB minimum free space check — refuse ONLY on confirmed real value under 2GB
                // nil = unknown = allow sync to proceed (never refuse on unknown)
                let minFreeBytes: Int64 = 2 * 1024 * 1024 * 1024 // 2GB
                if let freeBytes = BonjourAdvertiser.getFreeSpace(path: base.path),
                   freeBytes < minFreeBytes {
                    let refusedPath = base.appendingPathComponent(".sync_refused")
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
                            self.receivePercent = -1
                            self.receivingStartTime = nil
                            self.lastProgressTime = nil
                            ConfigStore.shared.isSyncing = false
                            ConfigStore.shared.iconState = .idle
                            return
                        }
                    }
                    self.receivePercent = -1
                }
                return
            }

            // No signal files — if we were receiving, Main finished or was cancelled
            Task { @MainActor [weak self] in
                self?.isChecking = false
                guard let self else { return }
                if self.state == .receiving {
                    self.state          = .idle
                    self.receivePercent = -1
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

    private static func parseProgressFile(_ content: String) -> Int {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pct  = (json["percent"] as? NSNumber)?.intValue else { return -1 }
        return max(0, min(100, pct))
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1_024         { return "\(bytes) bytes" }
        if bytes < 1_048_576     { return String(format: "%.1f KB", Double(bytes) / 1_024) }
        if bytes < 1_073_741_824 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
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
    @ObservedObject private var advertiser  = BonjourAdvertiser.shared
    @State private var showQuitConfirm = false
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
                        Text(networkMonitor.currentIP == "—" ? "Not set" : networkMonitor.currentIP)
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
                    Text(networkMonitor.currentIP == "—" ? "Not set" : networkMonitor.currentIP)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(networkMonitor.currentIP == "—" ? Color(white: 0.55) : .white)
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
                Text("BACKUP User")
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
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 6, height: 6)
                                Text("Cannot write — see Settings")
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
                            }
                        } else if receiveMonitor.state == .receiving {
                            Text(receivingText)
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

            // About
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Version")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.45))
                    Spacer()
                    Text(appVersion())
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("© RememberLive 2026")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.45))
                    Text("Designed and Programmed by Remember Chaitezvi")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.45))
                    Text("rememberlive.africa")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.45))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

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
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in
            storageMonitor.stopStorageUpdates()
        }
        .onChange(of: store.pendingQuitConfirm) { newValue in
            if newValue { showQuitConfirm = true }
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

    private var receivingText: String {
        let pct = receiveMonitor.receivePercent
        return pct >= 0 ? "Receiving... \(pct)%" : "Receiving..."
    }

    // MARK: - Row helpers

    private func shortenPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

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

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f.string(from: date)
    }

    private func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
