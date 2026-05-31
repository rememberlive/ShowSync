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
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
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
        let syncFolder = URL(fileURLWithPath: ConfigStore.shared.config.destinationFolder)
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

    private var pollTimer:   Timer?
    private var isChecking:  Bool = false
    var stopAfterTransfer:   Bool = false
    var isMonitoring: Bool { pollTimer != nil }

    private init() {}

    func startMonitoring() {
        validateDestination()
        state          = .idle
        receivePercent = -1
        receiveDetails = ""
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkSignalFiles()
        }
        checkSignalFiles()
    }

    func validateDestination() {
        let fm = FileManager.default
        let configPath = ConfigStore.shared.config.destinationFolder
        let defaultPath = fm.homeDirectoryForCurrentUser.appendingPathComponent("Sync").path
        let isDefault = configPath == defaultPath || configPath.isEmpty

        if !isDefault && fm.fileExists(atPath: configPath) && fm.isWritableFile(atPath: configPath) {
            usingFallback = false
            return
        }
        // Fall back to ~/Sync
        let fallback = fm.homeDirectoryForCurrentUser.appendingPathComponent("Sync")
        if !fm.fileExists(atPath: fallback.path) {
            try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        }
        if !isDefault {
            usingFallback = true
            ConfigStore.shared.config.destinationFolder = fallback.path
            BonjourAdvertiser.shared.restart() // Update TXT record
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
        // lastReceivedTime preserved across close/open
    }

    deinit { pollTimer?.invalidate() }

    private func checkSignalFiles() {
        guard !isChecking else { return }
        isChecking = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let base         = URL(fileURLWithPath: ConfigStore.shared.config.destinationFolder)
            let completePath = base.appendingPathComponent(".sync_complete")
            let progressPath = base.appendingPathComponent(".sync_progress")
            let startPath    = base.appendingPathComponent(".sync_start")
            let renamePath   = base.appendingPathComponent(".sync_rename_request")
            let fm           = FileManager.default

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
                    if self.state != .receiving {
                        self.state = .receiving
                        ConfigStore.shared.isSyncing = true
                        ConfigStore.shared.iconState = .receiving
                    }
                }
                return
            }

            if fm.fileExists(atPath: startPath.path) {
                // 2GB minimum free space check
                let freeBytes = BonjourAdvertiser.getFreeSpace(path: base.path)
                let minFreeBytes: Int64 = 2 * 1024 * 1024 * 1024 // 2GB
                if freeBytes < minFreeBytes {
                    let refusedPath = base.appendingPathComponent(".sync_refused")
                    try? "low_space".write(to: refusedPath, atomically: true, encoding: .utf8)
                    Task { @MainActor [weak self] in
                        self?.isChecking = false
                    }
                    return
                }
                Task { @MainActor [weak self] in
                    self?.isChecking = false
                    guard let self else { return }
                    self.receivePercent = -1
                    if self.state != .receiving {
                        self.state = .receiving
                        ConfigStore.shared.isSyncing = true
                        ConfigStore.shared.iconState = .receiving
                    }
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
                message: "Any sync in progress will stop.",
                confirmLabel: "Quit",
                confirmColor: .red,
                onCancel: {
                    store.pendingQuitConfirm = false
                    showQuitConfirm = false
                },
                onConfirm: {
                    store.pendingQuitConfirm = false
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
                        Text(shortenPath(store.config.destinationFolder))
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
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
                        Text("Using default folder — set a destination if needed")
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
                    .foregroundColor(isReceiving ? Color(white: 0.25) : Color(white: 0.5))
                    .disabled(isReceiving)
                    .help(isReceiving ? "Transfer in progress" : "")
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
