import Foundation
import Darwin
import Network

// Pure-Apple Bonjour discovery for the Sync app.
//
// Two responsibilities, kept separate:
//   • BonjourAdvertiser — Backup-role singleton; publishes _rememberlivesync._tcp
//     on launch (event-driven, zero idle CPU). AppDelegate owns lifecycle.
//   • BonjourBrowser — Main-role browser; lives inside SettingsView for the
//     duration the Discovery section is visible, per the project's
//     "zero CPU at idle" rule. NetServiceBrowser.stop() releases all callbacks.

// MARK: - Shared service type

private let serviceType = "_rememberlivesync._tcp"

// MARK: - Advertiser (Backup)

enum AdvertiserState: Equatable {
    case idle
    case advertising(name: String)
    case failed(reason: String)
}

final class BonjourAdvertiser: NSObject, ObservableObject {
    static let shared = BonjourAdvertiser()

    @Published var state: AdvertiserState = .idle
    @Published var confirmedName: String = ""

    private var service: NetService?
    private var bonjourRunLoop: RunLoop?
    private let runLoopReady = DispatchSemaphore(value: 0)
    private var isRunLoopReady = false

    // Dedicated background thread for all NetService operations to prevent main thread blocking
    private lazy var bonjourThread: Thread = {
        let thread = Thread { [weak self] in
            self?.bonjourRunLoop = RunLoop.current
            // Signal that runloop is ready
            self?.runLoopReady.signal()
            self?.isRunLoopReady = true
            // Keep the runloop alive with a port
            RunLoop.current.add(NSMachPort(), forMode: .default)
            RunLoop.current.run()
        }
        thread.name = "com.rememberlive.sync.bonjour-advertiser"
        thread.qualityOfService = .utility
        thread.start()
        return thread
    }()

    private override init() { super.init() }

    func start() {
        // Start thread and move wait + perform to background to avoid blocking main thread
        _ = bonjourThread // Start thread
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if !self.isRunLoopReady { self.runLoopReady.wait() }
            self.perform(#selector(self.startPublishing), on: self.bonjourThread, with: nil, waitUntilDone: false)
        }
    }

    @objc private func startPublishing() {
        guard service == nil else { return }

        // Get custom Network Discovery name from config, or fall back to hostname
        let configName = ConfigStore.shared.config.networkDiscoveryName
        let advertisedName: String
        if !configName.isEmpty {
            advertisedName = configName
        } else {
            // ProcessInfo.hostName is cached and does not round-trip to configd, unlike
            // Host.current().localizedName which can block the main thread on flaky DNS.
            let raw = ProcessInfo.processInfo.hostName
            advertisedName = raw
                .replacingOccurrences(of: ".local.", with: "")
                .replacingOccurrences(of: ".local",  with: "")
        }
        let svc = NetService(domain: "", type: serviceType, name: advertisedName, port: 22)
        svc.delegate = self
        // Publish destination folder in TXT record for Main to read
        let dest = ConfigStore.shared.config.destinationFolder
        let txtData = NetService.data(fromTXTRecord: ["dest": dest.data(using: .utf8) ?? Data()])
        svc.setTXTRecord(txtData)
        // Schedule on the background thread's runloop, not main
        if let runLoop = bonjourRunLoop {
            svc.schedule(in: runLoop, forMode: .common)
        }
        svc.publish() // This can now block without freezing the UI
        service = svc
    }

    func stop() {
        perform(#selector(stopPublishing), on: bonjourThread, with: nil, waitUntilDone: false)
    }

    func restart() {
        stop()
        start()
    }

    @objc private func stopPublishing() {
        if let svc = service {
            svc.stop()
            if let runLoop = bonjourRunLoop {
                svc.remove(from: runLoop, forMode: .common)
            }
            svc.delegate = nil
        }
        service = nil
        DispatchQueue.main.async { [weak self] in
            self?.state = .idle
        }
    }
}

extension BonjourAdvertiser: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        let name = sender.name
        DispatchQueue.main.async { [weak self] in
            self?.confirmedName = name
            self?.state = .advertising(name: name)
        }
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        NSLog("[Bonjour] publish failed: code=%d", code)
        DispatchQueue.main.async { [weak self] in
            self?.state = .failed(reason: "Error \(code)")
        }
    }
}

// MARK: - Browser (Main)

struct DiscoveredBackup: Identifiable, Equatable {
    let id: String          // NetService.name — unique per host on the LAN
    let hostname: String    // display label
    let resolvedIP: String  // IPv4 used for SSH
    let destinationPath: String  // Backup's receive folder (from TXT record, default ~/Sync)
}

enum BrowserState: Equatable {
    case idle
    case searching
    case failed(reason: String)
}

final class BonjourBrowser: NSObject, ObservableObject {
    static let shared = BonjourBrowser()

    @Published var services: [DiscoveredBackup] = []
    @Published var state: BrowserState = .idle

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []   // strong refs while resolution is in-flight
    private var bonjourRunLoop: RunLoop?
    private let runLoopReady = DispatchSemaphore(value: 0)
    private var isRunLoopReady = false

    // Dedicated background thread for all NetServiceBrowser operations to prevent main thread blocking
    private lazy var bonjourThread: Thread = {
        let thread = Thread { [weak self] in
            self?.bonjourRunLoop = RunLoop.current
            // Signal that runloop is ready
            self?.runLoopReady.signal()
            self?.isRunLoopReady = true
            // Keep the runloop alive with a port
            RunLoop.current.add(NSMachPort(), forMode: .default)
            RunLoop.current.run()
        }
        thread.name = "com.rememberlive.sync.bonjour-browser"
        thread.qualityOfService = .userInitiated
        thread.start()
        return thread
    }()

    private override init() {
        super.init()
        browser.delegate = self
        // Start thread and move wait + perform to background to avoid blocking main thread
        _ = bonjourThread // Start thread
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if !self.isRunLoopReady { self.runLoopReady.wait() }
            self.perform(#selector(self.setupBrowser), on: self.bonjourThread, with: nil, waitUntilDone: false)
        }
    }

    @objc private func setupBrowser() {
        if let runLoop = bonjourRunLoop {
            browser.schedule(in: runLoop, forMode: .common)
        }
    }

    func start() {
        if state == .searching { return }
        Task { @MainActor [weak self] in
            self?.state = .searching
            self?.services = []
        }
        // Move blocking searchForServices call to background thread
        perform(#selector(startSearching), on: bonjourThread, with: nil, waitUntilDone: false)
    }

    @objc private func startSearching() {
        resolving.removeAll() // Clear resolving array on restart
        browser.searchForServices(ofType: serviceType, inDomain: "") // Can now block without freezing UI
    }

    func stop() {
        perform(#selector(stopSearching), on: bonjourThread, with: nil, waitUntilDone: false)
    }

    @objc private func stopSearching() {
        browser.stop()
        for svc in resolving {
            svc.stop()
            if let runLoop = bonjourRunLoop {
                svc.remove(from: runLoop, forMode: .common)
            }
            svc.delegate = nil
        }
        resolving.removeAll()
        Task { @MainActor [weak self] in
            self?.state = .idle
            self?.services = []
        }
    }

    deinit {
        perform(#selector(cleanupBrowser), on: bonjourThread, with: nil, waitUntilDone: false)
    }

    @objc private func cleanupBrowser() {
        browser.stop()
        if let runLoop = bonjourRunLoop {
            browser.remove(from: runLoop, forMode: .common)
        }
    }
}

extension BonjourBrowser: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        // Schedule found services on background thread, not main
        if let runLoop = bonjourRunLoop {
            service.schedule(in: runLoop, forMode: .common)
        }
        resolving.append(service)
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let name = service.name
        if let runLoop = bonjourRunLoop {
            service.remove(from: runLoop, forMode: .common)
        }
        resolving.removeAll { $0 === service }
        Task { @MainActor [weak self] in
            self?.services.removeAll { $0.id == name }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        NSLog("[Bonjour] browse failed: code=%d", code)
        Task { @MainActor [weak self] in
            self?.state = .failed(reason: "Error \(code)")
        }
    }
}

extension BonjourBrowser: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        let ip = Self.firstIPv4(in: sender.addresses ?? [])
        let name = sender.name
        // hostName looks like "Remembers-MacBook-Air.local." — strip the mDNS suffix.
        let host = (sender.hostName ?? name)
            .replacingOccurrences(of: ".local.", with: "")
            .replacingOccurrences(of: ".local", with: "")
        // Parse destination folder from TXT record (default ~/Sync)
        var destPath = "~/Sync"
        if let txtData = sender.txtRecordData() {
            let dict = NetService.dictionary(fromTXTRecord: txtData)
            if let destData = dict["dest"], let str = String(data: destData, encoding: .utf8), !str.isEmpty {
                destPath = str
            }
        }

        // Remove from background runloop, not main
        if let runLoop = bonjourRunLoop {
            sender.remove(from: runLoop, forMode: .common)
        }
        sender.delegate = nil
        resolving.removeAll { $0 === sender }

        guard let resolvedIP = ip else { return }

        // Safety net: Filter out This Mac's own IP to prevent self-discovery
        if let currentIP = Self.getCurrentIP(), resolvedIP == currentIP {
            NSLog("[Bonjour] Filtered out self-discovered service: %@ (%@)", name, resolvedIP)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.services.removeAll { $0.id == name }
            self.services.append(DiscoveredBackup(id: name, hostname: host, resolvedIP: resolvedIP, destinationPath: destPath))
            self.services.sort { $0.hostname.localizedCaseInsensitiveCompare($1.hostname) == .orderedAscending }

            // Auto-reconnect: match by name (primary) or IP (fallback for renamed Backup)
            let config = ConfigStore.shared.config
            let nameMatch = !config.lastBackupDiscoveryName.isEmpty && name == config.lastBackupDiscoveryName
            let ipMatch = !config.lastBackupIP.isEmpty && resolvedIP == config.lastBackupIP
            let isCurrentConnection = !config.destinationIP.isEmpty && resolvedIP == config.destinationIP

            if nameMatch || ipMatch || isCurrentConnection {
                // Update connection details if needed
                if config.destinationIP != resolvedIP || config.backupHostname != host {
                    NSLog("[Bonjour] Auto-reconnecting to Backup: %@", name)
                    ConfigStore.shared.config.destinationIP = resolvedIP
                    ConfigStore.shared.config.backupHostname = host
                }
                // Always update destination (Backup may have changed it)
                ConfigStore.shared.config.backupDestination = destPath
                // Update stored name if Backup was renamed (matched by IP, not name)
                if !nameMatch && config.lastBackupDiscoveryName != name {
                    NSLog("[Bonjour] Connected Backup renamed to: %@", name)
                    ConfigStore.shared.config.lastBackupDiscoveryName = name
                }
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        NSLog("[Bonjour] resolve failed: code=%d", code)
        // Remove from background runloop, not main
        if let runLoop = bonjourRunLoop {
            sender.remove(from: runLoop, forMode: .common)
        }
        sender.delegate = nil
        resolving.removeAll { $0 === sender }
    }

    private static func firstIPv4(in addresses: [Data]) -> String? {
        for data in addresses {
            let ip: String? = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
                guard let base = raw.baseAddress else { return nil }
                let sa = base.assumingMemoryBound(to: sockaddr.self)
                guard sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var addr = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: buf)
            }
            if let ip { return ip }
        }
        return nil
    }

    // IP detection using getifaddrs directly
    private static func getCurrentIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var ptr = Optional(first)
        while let current = ptr {
            let ifa = current.pointee
            let name = String(cString: ifa.ifa_name)

            // Skip loopback interfaces
            if name == "lo0" || name.hasPrefix("lo") {
                ptr = ifa.ifa_next
                continue
            }

            // Check for IPv4 addresses on non-loopback interfaces
            if let ip = ipv4Address(for: name) {
                return ip
            }

            ptr = ifa.ifa_next
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
}
