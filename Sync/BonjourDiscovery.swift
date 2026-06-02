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

    // Backup-initiated verify: nonce (timestamp) to request verify from Main
    @Published var verifyRequestNonce: String = ""

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
        // Publish both paths so Main can display badge when drive unavailable
        let intendedDest = ConfigStore.shared.config.destinationFolder  // User's chosen path
        let effectiveDest = ReceiveMonitor.shared.effectiveDestination   // Where files actually go
        let freeBytes = Self.getFreeSpace(path: effectiveDest) ?? 0      // Free space on effective path
        var txtDict: [String: Data] = [
            "free": String(freeBytes).data(using: .utf8) ?? Data()
        ]
        if !intendedDest.isEmpty {
            txtDict["dest"] = intendedDest.data(using: .utf8) ?? Data()
        }
        if !effectiveDest.isEmpty {
            txtDict["effectiveDest"] = effectiveDest.data(using: .utf8) ?? Data()
        }
        if !verifyRequestNonce.isEmpty {
            txtDict["verifyReq"] = verifyRequestNonce.data(using: .utf8) ?? Data()
        }
        let txtData = NetService.data(fromTXTRecord: txtDict)
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

    /// Update TXT record in place (fast) - use for destination/fallback/free-space changes
    func updateTXTRecord() {
        perform(#selector(updateTXTRecordOnThread), on: bonjourThread, with: nil, waitUntilDone: false)
    }

    @objc private func updateTXTRecordOnThread() {
        guard let svc = service else {
            // No service running - need full start instead
            startPublishing()
            return
        }
        // Rebuild TXT data with current values
        let intendedDest = ConfigStore.shared.config.destinationFolder
        let effectiveDest = ReceiveMonitor.shared.effectiveDestination
        let freeBytes = Self.getFreeSpace(path: effectiveDest) ?? 0
        var txtDict: [String: Data] = [
            "free": String(freeBytes).data(using: .utf8) ?? Data()
        ]
        if !intendedDest.isEmpty {
            txtDict["dest"] = intendedDest.data(using: .utf8) ?? Data()
        }
        if !effectiveDest.isEmpty {
            txtDict["effectiveDest"] = effectiveDest.data(using: .utf8) ?? Data()
        }
        if !verifyRequestNonce.isEmpty {
            txtDict["verifyReq"] = verifyRequestNonce.data(using: .utf8) ?? Data()
        }
        let txtData = NetService.data(fromTXTRecord: txtDict)
        svc.setTXTRecord(txtData)
        NSLog("[Bonjour] TXT record updated in place: dest=%@, effective=%@, verifyReq=%@", intendedDest, effectiveDest, verifyRequestNonce)
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

    /// Stop advertising AND clear confirmedName. Use on role/mode switch to prevent stale name display.
    func stopAndClearState() {
        stop()
        DispatchQueue.main.async { [weak self] in
            self?.confirmedName = ""
        }
    }
    static func getFreeSpace(path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)

        // Primary: volumeAvailableCapacityForImportantUsageKey
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage, free > 0 {
            return free
        }

        // Fallback: FileManager attributesOfFileSystem on the path
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
           let free = attrs[.systemFreeSize] as? Int64, free > 0 {
            return free
        }

        // Volume root fallback: if subfolder doesn't exist yet, query the volume root
        // e.g. /Volumes/Protools/synctestdelete → /Volumes/Protools
        var volumeRoot = url
        while volumeRoot.path != "/" && volumeRoot.pathComponents.count > 2 {
            volumeRoot = volumeRoot.deletingLastPathComponent()
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: volumeRoot.path),
               let free = attrs[.systemFreeSize] as? Int64, free > 0 {
                return free
            }
        }

        // Unknown — return nil, NOT 0 (0 would falsely trigger "under 2GB" refusal)
        return nil
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
            self?.state = .failed(reason: "Couldn't advertise on the network")
        }
    }
}

// MARK: - Browser (Main)

struct DiscoveredBackup: Identifiable, Equatable {
    let id: String          // NetService.name — unique per host on the LAN
    let hostname: String    // display label
    let resolvedIP: String  // IPv4 used for SSH
    let destinationPath: String       // Backup's intended folder (user's choice, may be unavailable)
    let effectiveDestinationPath: String  // Where files actually go (~/Sync when drive unavailable)
    let freeSpaceBytes: Int64         // Backup's free space on effective path (0 if unknown)
    var isReachableOnSelectedInterface: Bool = true  // False if Backup is on a different subnet than user's selected interface

    var isUsingFallback: Bool {
        !effectiveDestinationPath.isEmpty && effectiveDestinationPath != destinationPath
    }
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

    // Backup-initiated verify: dedupe so we run once per nonce
    private var lastHandledVerifyNonce: String = ""

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []   // strong refs while resolution is in-flight
    private var monitoring: [NetService] = []  // strong refs for TXT record monitoring
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
        browser.remove(from: RunLoop.main, forMode: .common)
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

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.start()
        }
    }

    @objc private func stopSearching() {
        browser.stop()
        // Clean up resolving services
        for svc in resolving {
            svc.stop()
            if let runLoop = bonjourRunLoop {
                svc.remove(from: runLoop, forMode: .common)
            }
            svc.delegate = nil
        }
        resolving.removeAll()
        // Clean up monitoring services
        for svc in monitoring {
            svc.stopMonitoring()
            if let runLoop = bonjourRunLoop {
                svc.remove(from: runLoop, forMode: .common)
            }
            svc.delegate = nil
        }
        monitoring.removeAll()
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
        // Stop monitoring and clean up
        service.stopMonitoring()
        if let runLoop = bonjourRunLoop {
            service.remove(from: runLoop, forMode: .common)
        }
        service.delegate = nil
        resolving.removeAll { $0 === service }
        monitoring.removeAll { $0 === service }
        Task { @MainActor [weak self] in
            self?.services.removeAll { $0.id == name }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        NSLog("[Bonjour] browse failed: code=%d", code)
        Task { @MainActor [weak self] in
            self?.state = .failed(reason: "Couldn't search the network")
        }
    }
}

extension BonjourBrowser: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        let allIPs = Self.allIPv4Addresses(in: sender.addresses ?? [])
        let name = sender.name
        // hostName looks like "Remembers-MacBook-Air.local." — strip the mDNS suffix.
        let host = (sender.hostName ?? name)
            .replacingOccurrences(of: ".local.", with: "")
            .replacingOccurrences(of: ".local", with: "")
        // Parse destination folder and free space from TXT record
        var destPath = "~/Sync"           // User's intended destination
        var effectivePath = "~/Sync"      // Where files actually go
        var freeBytes: Int64 = 0
        if let txtData = sender.txtRecordData(), Self.isValidTXTFormat(txtData) {
            let dict = NetService.dictionary(fromTXTRecord: txtData)
            if let destData = dict["dest"], let str = String(data: destData, encoding: .utf8), !str.isEmpty {
                destPath = str
            }
            if let effectiveData = dict["effectiveDest"], let str = String(data: effectiveData, encoding: .utf8), !str.isEmpty {
                effectivePath = str
            } else {
                effectivePath = destPath  // Fallback for older Backup versions
            }
            if let freeData = dict["free"], let str = String(data: freeData, encoding: .utf8), let val = Int64(str) {
                freeBytes = val
            }
        }

        // Move from resolving to monitoring for TXT updates
        resolving.removeAll { $0 === sender }

        // Classify reachability based on selected interface
        let preferred = ConfigStore.shared.config.preferredInterface
        var resolvedIP: String?
        var isReachable = true

        if preferred.isEmpty {
            // Automatic mode: use first IPv4, mark reachable (unchanged behavior)
            resolvedIP = allIPs.first
            isReachable = true
        } else if let subnet = Self.getInterfaceSubnet(name: preferred) {
            // Interface selected: prefer on-subnet address
            if let onSubnetIP = allIPs.first(where: { Self.isOnSubnet($0, ifaceIP: subnet.ip, mask: subnet.mask) }) {
                resolvedIP = onSubnetIP
                isReachable = true
            } else {
                // No on-subnet address — use first IP for DISPLAY, flag unreachable
                resolvedIP = allIPs.first
                isReachable = false
            }
        } else {
            // Interface set but has no IP (down) — fallback: use first, mark reachable (with notice)
            resolvedIP = allIPs.first
            isReachable = true
        }

        guard let resolvedIP else {
            // Resolution failed - clean up
            if let runLoop = bonjourRunLoop {
                sender.remove(from: runLoop, forMode: .common)
            }
            sender.delegate = nil
            return
        }

        // Start monitoring for TXT record changes (keep delegate and runloop scheduled)
        sender.startMonitoring()
        monitoring.append(sender)

        // Safety net: Filter out This Mac's own IP to prevent self-discovery
        if let currentIP = Self.getCurrentIP(), resolvedIP == currentIP {
            NSLog("[Bonjour] Filtered out self-discovered service: %@ (%@)", name, resolvedIP)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.services.removeAll { $0.id == name }
            self.services.append(DiscoveredBackup(id: name, hostname: host, resolvedIP: resolvedIP, destinationPath: destPath, effectiveDestinationPath: effectivePath, freeSpaceBytes: freeBytes, isReachableOnSelectedInterface: isReachable))
            self.services.sort { $0.hostname.localizedCaseInsensitiveCompare($1.hostname) == .orderedAscending }

            // Auto-reconnect: match by name (primary) or IP (fallback for renamed Backup)
            // GUARD: only auto-reconnect if the Backup is reachable on selected interface
            guard isReachable else { return }

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
                // Always update destination and fallback state (Backup may have changed it)
                ConfigStore.shared.config.backupDestination = destPath
                let isFallback = !effectivePath.isEmpty && effectivePath != destPath
                SyncEngine.shared.usingFallback = isFallback
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

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        let name = sender.name
        // Validate TXT format before parsing (malformed data can SIGABRT)
        guard Self.isValidTXTFormat(data) else { return }
        // Parse updated TXT record
        var destPath = "~/Sync"
        var effectivePath = "~/Sync"
        var freeBytes: Int64 = 0
        let dict = NetService.dictionary(fromTXTRecord: data)
        if let destData = dict["dest"], let str = String(data: destData, encoding: .utf8), !str.isEmpty {
            destPath = str
        }
        if let effectiveData = dict["effectiveDest"], let str = String(data: effectiveData, encoding: .utf8), !str.isEmpty {
            effectivePath = str
        } else {
            effectivePath = destPath
        }
        if let freeData = dict["free"], let str = String(data: freeData, encoding: .utf8), let val = Int64(str) {
            freeBytes = val
        }

        // Check for Backup-initiated verify request
        var verifyReq = ""
        if let verifyData = dict["verifyReq"], let str = String(data: verifyData, encoding: .utf8) {
            verifyReq = str
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Handle Backup-initiated verify: trigger if new nonce from currently connected Backup
            // GUARD: skip verify if Backup is unreachable on selected interface
            let config = ConfigStore.shared.config
            if !verifyReq.isEmpty && verifyReq != self.lastHandledVerifyNonce {
                // Find the service to check if it's our connected Backup
                if let service = self.services.first(where: { $0.id == name }),
                   config.destinationIP == service.resolvedIP,
                   service.isReachableOnSelectedInterface {
                    self.lastHandledVerifyNonce = verifyReq
                    NSLog("[Bonjour] Received verify request from Backup: nonce=%@", verifyReq)
                    SyncEngine.shared.triggerRemoteVerify()
                }
            }

            // Update the service entry in our array (preserve reachability flag)
            if let idx = self.services.firstIndex(where: { $0.id == name }) {
                let old = self.services[idx]
                self.services[idx] = DiscoveredBackup(
                    id: old.id,
                    hostname: old.hostname,
                    resolvedIP: old.resolvedIP,
                    destinationPath: destPath,
                    effectiveDestinationPath: effectivePath,
                    freeSpaceBytes: freeBytes,
                    isReachableOnSelectedInterface: old.isReachableOnSelectedInterface
                )
                NSLog("[Bonjour] TXT update for %@: dest=%@, effective=%@", name, destPath, effectivePath)

                // If this is the currently connected Backup, update config live
                let config = ConfigStore.shared.config
                if config.destinationIP == old.resolvedIP {
                    ConfigStore.shared.config.backupDestination = destPath
                    let isFallback = !effectivePath.isEmpty && effectivePath != destPath
                    SyncEngine.shared.usingFallback = isFallback
                    NSLog("[Bonjour] Updated connected Backup destination: %@ (fallback=%d)", destPath, isFallback ? 1 : 0)
                }
            }
        }
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

    // IP detection using getifaddrs directly — prefers selected interface if set
    private static func getCurrentIP() -> String? {
        let preferred = ConfigStore.shared.config.preferredInterface
        if !preferred.isEmpty, let ip = ipv4Address(for: preferred) {
            return ip
        }

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
            guard ifa.ifa_addr != nil else { ptr = ifa.ifa_next; continue }
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

    // Returns ALL IPv4 addresses from resolved NetService addresses (Backup may advertise on multiple interfaces)
    private static func allIPv4Addresses(in addresses: [Data]) -> [String] {
        var result: [String] = []
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
            if let ip { result.append(ip) }
        }
        return result
    }

    // Returns IP and netmask for the given interface (for subnet comparison)
    private static func getInterfaceSubnet(name interfaceName: String) -> (ip: UInt32, mask: UInt32)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }
        var ptr = Optional(first)
        while let current = ptr {
            let ifa = current.pointee
            guard ifa.ifa_addr != nil else { ptr = ifa.ifa_next; continue }
            if ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET),
               String(cString: ifa.ifa_name) == interfaceName,
               let netmaskPtr = ifa.ifa_netmask {
                let addrIn = ifa.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let maskIn = netmaskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                return (ip: addrIn.sin_addr.s_addr, mask: maskIn.sin_addr.s_addr)
            }
            ptr = ifa.ifa_next
        }
        return nil
    }

    // Check if an IP string is on the same subnet as the given interface IP/mask
    private static func isOnSubnet(_ ipString: String, ifaceIP: UInt32, mask: UInt32) -> Bool {
        var addr = in_addr()
        guard inet_pton(AF_INET, ipString, &addr) == 1 else { return false }
        return (addr.s_addr & mask) == (ifaceIP & mask)
    }

    // Validate TXT record format before calling dictionary(fromTXTRecord:)
    // which can SIGABRT on malformed data. Format: length-prefixed entries.
    private static func isValidTXTFormat(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        var offset = 0
        while offset < data.count {
            let length = Int(data[offset])
            offset += 1
            if offset + length > data.count { return false }
            offset += length
        }
        return offset == data.count
    }
}
