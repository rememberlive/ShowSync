import Foundation
import Darwin
import Network
import AppKit

// Pure-Apple Bonjour discovery for the Sync app.
//
// Two responsibilities, kept separate:
//   • BonjourAdvertiser — Backup-role singleton; publishes _rememberlivesync._tcp
//     on launch (event-driven, zero idle CPU). AppDelegate owns lifecycle.
//   • BonjourBrowser — Main-role browser; lives inside SettingsView for the
//     duration the Discovery section is visible, per the project's
//     "zero CPU at idle" rule. NetServiceBrowser.stop() releases all callbacks.
//
// Layer 2b: BonjourPairingService — temporary _syncpair._tcp for passwordless pairing.
//   Dedicated thread + runloop, independent of discovery. Main advertises pairing request,
//   Backup browses + shows confirm dialog. Clean teardown on all paths.

// MARK: - Shared service type

private let serviceType = "_rememberlivesync._tcp"
private let pairingServiceType = "_syncpair._tcp"

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

    // Pairing ack/nack (Layer 2b) — transient fields, cleared after 5s
    var pairAckDeviceId: String = ""
    var pairAckNonce: String = ""
    var pairNackDeviceId: String = ""
    var pairNackNonce: String = ""
    private var ackClearWorkItem: DispatchWorkItem?

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
        // Layer 2b: Include identity for pairing
        let identity = ConfigStore.shared.identity
        txtDict["backupId"] = identity.deviceId.data(using: .utf8) ?? Data()
        if let fp = getSSHFingerprint() {
            txtDict["backupFP"] = fp.data(using: .utf8) ?? Data()
        }
        // Transient pairing ack/nack
        if !pairAckDeviceId.isEmpty {
            txtDict["pairAck"] = pairAckDeviceId.data(using: .utf8) ?? Data()
            txtDict["pairAckNonce"] = pairAckNonce.data(using: .utf8) ?? Data()
        }
        if !pairNackDeviceId.isEmpty {
            txtDict["pairNack"] = pairNackDeviceId.data(using: .utf8) ?? Data()
            txtDict["pairNackNonce"] = pairNackNonce.data(using: .utf8) ?? Data()
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
        // Layer 2b: Include identity for pairing
        let identity = ConfigStore.shared.identity
        txtDict["backupId"] = identity.deviceId.data(using: .utf8) ?? Data()
        if let fp = getSSHFingerprint() {
            txtDict["backupFP"] = fp.data(using: .utf8) ?? Data()
        }
        // Transient pairing ack/nack
        if !pairAckDeviceId.isEmpty {
            txtDict["pairAck"] = pairAckDeviceId.data(using: .utf8) ?? Data()
            txtDict["pairAckNonce"] = pairAckNonce.data(using: .utf8) ?? Data()
        }
        if !pairNackDeviceId.isEmpty {
            txtDict["pairNack"] = pairNackDeviceId.data(using: .utf8) ?? Data()
            txtDict["pairNackNonce"] = pairNackNonce.data(using: .utf8) ?? Data()
        }
        let txtData = NetService.data(fromTXTRecord: txtDict)
        svc.setTXTRecord(txtData)
        NSLog("[Bonjour] TXT record updated in place: dest=%@, effective=%@, verifyReq=%@", intendedDest, effectiveDest, verifyRequestNonce)
    }

    // MARK: - Pairing Ack/Nack (Layer 2b)

    /// Set pairing ack (trust granted) and update TXT. Clears after 5s.
    func setPairAck(forDeviceId deviceId: String, nonce: String) {
        ackClearWorkItem?.cancel()
        pairAckDeviceId = deviceId
        pairAckNonce = nonce
        pairNackDeviceId = ""
        pairNackNonce = ""
        updateTXTRecord()
        // Auto-clear after 5 seconds
        let workItem = DispatchWorkItem { [weak self] in
            self?.pairAckDeviceId = ""
            self?.pairAckNonce = ""
            self?.updateTXTRecord()
        }
        ackClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    /// Set pairing nack (trust declined) and update TXT. Clears after 5s.
    func setPairNack(forDeviceId deviceId: String, nonce: String) {
        ackClearWorkItem?.cancel()
        pairNackDeviceId = deviceId
        pairNackNonce = nonce
        pairAckDeviceId = ""
        pairAckNonce = ""
        updateTXTRecord()
        // Auto-clear after 5 seconds
        let workItem = DispatchWorkItem { [weak self] in
            self?.pairNackDeviceId = ""
            self?.pairNackNonce = ""
            self?.updateTXTRecord()
        }
        ackClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
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
    // Layer 2b: Identity for pairing
    var backupDeviceId: String = ""   // Backup's unique device ID (from TXT)
    var backupFingerprint: String = ""  // Backup's SSH fingerprint (from TXT)

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

    // Layer 2b: Pairing ack/nack callback
    var pairingAckCallback: ((String, String) -> Void)?   // (deviceId, nonce)
    var pairingNackCallback: ((String, String) -> Void)?  // (deviceId, nonce)

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
        var backupId = ""                 // Layer 2b: device identity
        var backupFP = ""                 // Layer 2b: SSH fingerprint
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
            // Layer 2b: Parse identity fields
            if let idData = dict["backupId"], let str = String(data: idData, encoding: .utf8) {
                backupId = str
            }
            if let fpData = dict["backupFP"], let str = String(data: fpData, encoding: .utf8) {
                backupFP = str
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
            self.services.append(DiscoveredBackup(id: name, hostname: host, resolvedIP: resolvedIP, destinationPath: destPath, effectiveDestinationPath: effectivePath, freeSpaceBytes: freeBytes, isReachableOnSelectedInterface: isReachable, backupDeviceId: backupId, backupFingerprint: backupFP))
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
        var backupId = ""
        var backupFP = ""
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
        // Layer 2b: Parse identity fields
        if let idData = dict["backupId"], let str = String(data: idData, encoding: .utf8) {
            backupId = str
        }
        if let fpData = dict["backupFP"], let str = String(data: fpData, encoding: .utf8) {
            backupFP = str
        }

        // Check for Backup-initiated verify request
        var verifyReq = ""
        if let verifyData = dict["verifyReq"], let str = String(data: verifyData, encoding: .utf8) {
            verifyReq = str
        }

        // Layer 2b: Check for pairing ack/nack
        var pairAck = ""
        var pairAckNonce = ""
        var pairNack = ""
        var pairNackNonce = ""
        if let ackData = dict["pairAck"], let str = String(data: ackData, encoding: .utf8) {
            pairAck = str
        }
        if let ackNonceData = dict["pairAckNonce"], let str = String(data: ackNonceData, encoding: .utf8) {
            pairAckNonce = str
        }
        if let nackData = dict["pairNack"], let str = String(data: nackData, encoding: .utf8) {
            pairNack = str
        }
        if let nackNonceData = dict["pairNackNonce"], let str = String(data: nackNonceData, encoding: .utf8) {
            pairNackNonce = str
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Layer 2b: Fire pairing ack/nack callbacks
            if !pairAck.isEmpty && !pairAckNonce.isEmpty {
                self.pairingAckCallback?(pairAck, pairAckNonce)
            }
            if !pairNack.isEmpty && !pairNackNonce.isEmpty {
                self.pairingNackCallback?(pairNack, pairNackNonce)
            }

            // Handle Backup-initiated verify: trigger if new nonce from currently connected Backup
            // GUARD: skip verify if Backup is unreachable on selected interface
            let config = ConfigStore.shared.config
            if !verifyReq.isEmpty && verifyReq != self.lastHandledVerifyNonce {
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
                    isReachableOnSelectedInterface: old.isReachableOnSelectedInterface,
                    backupDeviceId: backupId,
                    backupFingerprint: backupFP
                )
                NSLog("[Bonjour] TXT update for %@: dest=%@, effective=%@", name, destPath, effectivePath)

                // If this is the currently connected Backup, update config live
                // Defer scalar writes to next runloop tick to avoid AttributeGraph cycle
                // (services array write above stays synchronous to avoid stale-index risk)
                let config = ConfigStore.shared.config
                if config.destinationIP == old.resolvedIP {
                    let isFallback = !effectivePath.isEmpty && effectivePath != destPath
                    DispatchQueue.main.asyncAfter(deadline: .now()) {
                        ConfigStore.shared.config.backupDestination = destPath
                        SyncEngine.shared.usingFallback = isFallback
                        NSLog("[Bonjour] Updated connected Backup destination: %@ (fallback=%d)", destPath, isFallback ? 1 : 0)
                    }
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

// MARK: - BonjourPairingService (Layer 2b)
// Dedicated service for passwordless pairing. Main advertises _syncpair._tcp with pubkey,
// Backup browses, shows confirm dialog, writes key to authorized_keys.
// Independent thread + runloop for isolation. Clean teardown on all paths.

enum PairingState: Equatable {
    case idle
    case advertising(targetBackupId: String)
    case browsing
    case waitingForConfirm(peerName: String)
    case paired(peerName: String)
    case declined(peerName: String)
    case timeout
    case failed(reason: String)
}

final class BonjourPairingService: NSObject, ObservableObject {
    static let shared = BonjourPairingService()

    @Published var state: PairingState = .idle

    // Re-entrancy guard: prevent overlapping pairing attempts
    private var isPairingInProgress = false

    // Dedicated thread for pairing operations (isolated from discovery)
    private var pairingRunLoop: RunLoop?
    private let runLoopReady = DispatchSemaphore(value: 0)
    private var isRunLoopReady = false

    private lazy var pairingThread: Thread = {
        let thread = Thread { [weak self] in
            self?.pairingRunLoop = RunLoop.current
            self?.runLoopReady.signal()
            self?.isRunLoopReady = true
            RunLoop.current.add(NSMachPort(), forMode: .default)
            RunLoop.current.run()
        }
        thread.name = "com.rememberlive.sync.pairing"
        thread.qualityOfService = .utility
        thread.start()
        return thread
    }()

    // Main-role: advertiser for pairing requests
    private var advertiserService: NetService?
    private var currentNonce: String = ""
    private var targetBackupId: String = ""
    private var pairingCompletion: ((Bool, String?) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?

    // Backup-role: browser for incoming pairing requests
    private var pairingBrowser: NetServiceBrowser?
    private var resolvingServices: [NetService] = []
    private var handledNonces: Set<String> = []  // Dedupe: don't re-prompt for same request

    private override init() {
        super.init()
        _ = pairingThread  // Start thread eagerly
    }

    // MARK: - Main-role: Initiate pairing

    /// Generate SSH key if missing (mirrors SSHKeyWizard.generateKey)
    private func ensureSSHKeyExists(completion: @escaping (Bool) -> Void) {
        let fm = FileManager.default
        let sshDir = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
        let keyPath = (sshDir as NSString).appendingPathComponent("id_ed25519")

        // Key already exists - proceed
        if fm.fileExists(atPath: keyPath) {
            completion(true)
            return
        }

        // Create ~/.ssh (0700) if needed
        if !fm.fileExists(atPath: sshDir) {
            do {
                try fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true, attributes: nil)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir)
            } catch {
                NSLog("[Pairing] Failed to create ~/.ssh: %@", error.localizedDescription)
                completion(false)
                return
            }
        }

        // Generate key (same args as SSHKeyWizard)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        proc.arguments = ["-t", "ed25519", "-f", keyPath, "-N", "", "-q"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { p in
            DispatchQueue.main.async { completion(p.terminationStatus == 0) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try proc.run()
            } catch {
                NSLog("[Pairing] ssh-keygen launch failed: %@", error.localizedDescription)
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    /// Start pairing with a specific Backup (by deviceId).
    /// - Parameters:
    ///   - targetBackupId: The deviceId of the Backup to pair with
    ///   - completion: Called with (success, errorMessage?)
    func startPairing(targetBackupId: String, completion: @escaping (Bool, String?) -> Void) {
        guard !isPairingInProgress else {
            completion(false, "Pairing already in progress")
            return
        }
        isPairingInProgress = true
        self.targetBackupId = targetBackupId
        self.pairingCompletion = completion
        self.currentNonce = UUID().uuidString

        // FIX 2: asyncAfter to avoid "Publishing changes from within view updates"
        DispatchQueue.main.asyncAfter(deadline: .now()) { [weak self] in
            self?.state = .advertising(targetBackupId: targetBackupId)
        }

        // FIX 1: Ensure SSH key exists before advertising (generate if missing)
        ensureSSHKeyExists { [weak self] keyOK in
            guard let self else { return }
            guard keyOK else {
                self.finishPairing(success: false, error: "Could not generate SSH key")
                return
            }
            // Key exists - proceed to advertise
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                if !self.isRunLoopReady { self.runLoopReady.wait() }
                self.perform(#selector(self.startAdvertisingPairing), on: self.pairingThread, with: nil, waitUntilDone: false)
            }
        }

        // 45-second hard timeout
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.isPairingInProgress else { return }
            NSLog("[Pairing] Timeout - no response from Backup")
            self.cancelPairing(reason: .timeout)
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)

        // Listen for ack/nack from BonjourBrowser
        BonjourBrowser.shared.pairingAckCallback = { [weak self] deviceId, nonce in
            self?.handleAck(fromDeviceId: deviceId, nonce: nonce)
        }
        BonjourBrowser.shared.pairingNackCallback = { [weak self] deviceId, nonce in
            self?.handleNack(fromDeviceId: deviceId, nonce: nonce)
        }
    }

    @objc private func startAdvertisingPairing() {
        // Defensive cleanup: stop any stale advertiser from a previous attempt
        // (can occur if stopAdvertisingPairing queued async hasn't completed yet)
        if let old = advertiserService {
            old.stop()
            old.delegate = nil
            advertiserService = nil
            NSLog("[Pairing] Cleaned up stale advertiser before re-advertising")
        }

        let identity = ConfigStore.shared.identity
        let pubKeyPath = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/id_ed25519.pub")
        guard let pubKey = try? String(contentsOfFile: pubKeyPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !pubKey.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                self?.finishPairing(success: false, error: "No SSH key found. Generate one first.")
            }
            return
        }

        guard let fingerprint = getSSHFingerprint() else {
            DispatchQueue.main.async { [weak self] in
                self?.finishPairing(success: false, error: "Could not get key fingerprint")
            }
            return
        }

        // Advertise _syncpair._tcp with: mainId, mainName, mainPubKey, mainFP, targetBackupId, nonce
        let svc = NetService(domain: "", type: pairingServiceType, name: identity.deviceName, port: 0)
        svc.delegate = self
        let txtDict: [String: Data] = [
            "mainId": identity.deviceId.data(using: .utf8) ?? Data(),
            "mainName": identity.deviceName.data(using: .utf8) ?? Data(),
            "mainPubKey": pubKey.data(using: .utf8) ?? Data(),
            "mainFP": fingerprint.data(using: .utf8) ?? Data(),
            "targetBackupId": targetBackupId.data(using: .utf8) ?? Data(),
            "nonce": currentNonce.data(using: .utf8) ?? Data()
        ]
        svc.setTXTRecord(NetService.data(fromTXTRecord: txtDict))

        if let runLoop = pairingRunLoop {
            svc.schedule(in: runLoop, forMode: .common)
        }
        svc.publish(options: .listenForConnections)
        advertiserService = svc
        NSLog("[Pairing] Main advertising _syncpair._tcp for Backup %@", targetBackupId)
    }

    private func handleAck(fromDeviceId deviceId: String, nonce: String) {
        guard isPairingInProgress,
              deviceId == ConfigStore.shared.identity.deviceId,
              nonce == currentNonce else { return }

        NSLog("[Pairing] Received ACK from Backup")

        // Find the Backup's info from browser
        if let backup = BonjourBrowser.shared.services.first(where: { _ in true }) {
            // Record the pairing on Main side
            // Note: We need the Backup's fingerprint - it's in their TXT record
            // For now, mark paired without pinning (Layer 3 will add host-key pinning)
            ConfigStore.shared.markPeerAsPairedOnMain(
                peerDeviceId: targetBackupId,
                peerName: backup.hostname,
                peerFingerprint: ""  // Layer 3: will add host-key from known_hosts
            )
        }

        finishPairing(success: true, error: nil)
    }

    private func handleNack(fromDeviceId deviceId: String, nonce: String) {
        guard isPairingInProgress,
              deviceId == ConfigStore.shared.identity.deviceId,
              nonce == currentNonce else { return }

        NSLog("[Pairing] Received NACK from Backup - pairing declined")
        cancelPairing(reason: .declined(peerName: "Backup"))
    }

    func cancelPairing() {
        cancelPairing(reason: .idle)
    }

    private func cancelPairing(reason: PairingState) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        BonjourBrowser.shared.pairingAckCallback = nil
        BonjourBrowser.shared.pairingNackCallback = nil

        perform(#selector(stopAdvertisingPairing), on: pairingThread, with: nil, waitUntilDone: false)

        let errorMsg: String?
        switch reason {
        case .timeout: errorMsg = "Pairing timed out - no response from Backup"
        case .declined: errorMsg = "Backup declined the pairing request"
        case .failed(let msg): errorMsg = msg
        default: errorMsg = nil
        }

        isPairingInProgress = false
        // FIX 2: asyncAfter to avoid "Publishing changes from within view updates"
        DispatchQueue.main.asyncAfter(deadline: .now()) { [weak self] in
            self?.state = reason
            self?.pairingCompletion?(false, errorMsg)
            self?.pairingCompletion = nil
        }
    }

    private func finishPairing(success: Bool, error: String?) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        BonjourBrowser.shared.pairingAckCallback = nil
        BonjourBrowser.shared.pairingNackCallback = nil

        perform(#selector(stopAdvertisingPairing), on: pairingThread, with: nil, waitUntilDone: false)

        isPairingInProgress = false
        // FIX 2: asyncAfter to avoid "Publishing changes from within view updates"
        DispatchQueue.main.asyncAfter(deadline: .now()) { [weak self] in
            if success {
                self?.state = .paired(peerName: self?.targetBackupId ?? "Backup")
            } else {
                self?.state = .failed(reason: error ?? "Unknown error")
            }
            self?.pairingCompletion?(success, error)
            self?.pairingCompletion = nil
        }
    }

    @objc private func stopAdvertisingPairing() {
        if let svc = advertiserService {
            svc.stop()
            if let runLoop = pairingRunLoop {
                svc.remove(from: runLoop, forMode: .common)
            }
            svc.delegate = nil
        }
        advertiserService = nil
        NSLog("[Pairing] Stopped advertising _syncpair._tcp")
    }

    // MARK: - Backup-role: Listen for pairing requests

    /// Start listening for pairing requests (Backup role)
    func startListening() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if !self.isRunLoopReady { self.runLoopReady.wait() }
            self.perform(#selector(self.startBrowsingPairing), on: self.pairingThread, with: nil, waitUntilDone: false)
        }
    }

    /// Stop listening for pairing requests
    func stopListening() {
        perform(#selector(stopBrowsingPairing), on: pairingThread, with: nil, waitUntilDone: false)
    }

    @objc private func startBrowsingPairing() {
        let browser = NetServiceBrowser()
        browser.delegate = self
        if let runLoop = pairingRunLoop {
            browser.schedule(in: runLoop, forMode: .common)
        }
        browser.searchForServices(ofType: pairingServiceType, inDomain: "")
        pairingBrowser = browser
        DispatchQueue.main.asyncAfter(deadline: .now()) { [weak self] in
            self?.state = .browsing
        }
        NSLog("[Pairing] Backup started browsing for _syncpair._tcp")
    }

    @objc private func stopBrowsingPairing() {
        if let browser = pairingBrowser {
            browser.stop()
            if let runLoop = pairingRunLoop {
                browser.remove(from: runLoop, forMode: .common)
            }
            browser.delegate = nil
        }
        pairingBrowser = nil
        // Clean up any resolving services
        for svc in resolvingServices {
            svc.stop()
            if let runLoop = pairingRunLoop {
                svc.remove(from: runLoop, forMode: .common)
            }
            svc.delegate = nil
        }
        resolvingServices = []
        // FIX 2: asyncAfter to avoid "Publishing changes from within view updates"
        DispatchQueue.main.asyncAfter(deadline: .now()) { [weak self] in
            self?.state = .idle
        }
        NSLog("[Pairing] Backup stopped browsing for _syncpair._tcp")
    }
}

// MARK: - BonjourPairingService NetService Delegates

extension BonjourPairingService: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        NSLog("[Pairing] Successfully published _syncpair._tcp as '%@' on port %d", sender.name, sender.port)
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        NSLog("[Pairing] Failed to publish _syncpair._tcp: code=%d", code)
        DispatchQueue.main.async { [weak self] in
            self?.finishPairing(success: false, error: "Failed to advertise pairing request")
        }
    }

    func netService(_ sender: NetService, didAcceptConnectionWith inputStream: InputStream, outputStream: OutputStream) {
        // Pairing data rides TXT records, not this socket — close immediately to avoid leaks
        inputStream.close()
        outputStream.close()
        NSLog("[Pairing] pairing service accepted+closed an incoming connection")
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        // Backup received a pairing request - parse TXT and show confirm
        guard let txtData = sender.txtRecordData() else {
            NSLog("[Pairing] Resolved service but no TXT data")
            return
        }

        let dict = NetService.dictionary(fromTXTRecord: txtData)
        guard let mainIdData = dict["mainId"], let mainId = String(data: mainIdData, encoding: .utf8),
              let mainNameData = dict["mainName"], let mainName = String(data: mainNameData, encoding: .utf8),
              let mainPubKeyData = dict["mainPubKey"], let mainPubKey = String(data: mainPubKeyData, encoding: .utf8),
              let mainFPData = dict["mainFP"], let mainFP = String(data: mainFPData, encoding: .utf8),
              let targetIdData = dict["targetBackupId"], let targetId = String(data: targetIdData, encoding: .utf8),
              let nonceData = dict["nonce"], let nonce = String(data: nonceData, encoding: .utf8) else {
            NSLog("[Pairing] Missing required TXT fields in pairing request")
            return
        }

        // Check if this is addressed to us
        let myId = ConfigStore.shared.identity.deviceId
        guard targetId == myId else {
            NSLog("[Pairing] Pairing request not for us (target=%@, we are=%@)", targetId, myId)
            return
        }

        // Dedupe: don't re-prompt for the same nonce
        guard !handledNonces.contains(nonce) else {
            NSLog("[Pairing] Already handled nonce %@, ignoring", nonce)
            return
        }
        handledNonces.insert(nonce)

        NSLog("[Pairing] Received pairing request from '%@' (%@) with fingerprint %@", mainName, mainId, mainFP)

        DispatchQueue.main.async { [weak self] in
            self?.state = .waitingForConfirm(peerName: mainName)
        }

        // Show confirm dialog — must run on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let appDelegate = AppDelegate.shared else { return }
            appDelegate.showPairingConfirmDialog(peerName: mainName, peerFingerprint: mainFP) { [weak self] (result: PairingConfirmResult) in
                guard let self else { return }
                switch result {
                case .trust:
                    NSLog("[Pairing] User TRUSTED '%@'", mainName)
                    // Write key to authorized_keys
                    let success = ConfigStore.shared.markPeerAsTrustedOnBackup(
                        peerDeviceId: mainId,
                        peerName: mainName,
                        peerPublicKey: mainPubKey,
                        peerFingerprint: mainFP
                    )
                    if success {
                        // Send ack via BonjourAdvertiser TXT record
                        BonjourAdvertiser.shared.setPairAck(forDeviceId: mainId, nonce: nonce)
                        DispatchQueue.main.async {
                            self.state = .paired(peerName: mainName)
                        }
                    } else {
                        NSLog("[Pairing] Failed to write key to authorized_keys")
                        DispatchQueue.main.async {
                            self.state = .failed(reason: "Failed to save key")
                        }
                    }
                case .decline:
                    NSLog("[Pairing] User DECLINED '%@'", mainName)
                    // Send nack via BonjourAdvertiser TXT record
                    BonjourAdvertiser.shared.setPairNack(forDeviceId: mainId, nonce: nonce)
                    DispatchQueue.main.async {
                        self.state = .declined(peerName: mainName)
                    }
                }
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        NSLog("[Pairing] Failed to resolve pairing service: code=%d", code)
        resolvingServices.removeAll { $0 === sender }
    }
}

extension BonjourPairingService: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        NSLog("[Pairing] Found pairing service: %@", service.name)
        service.delegate = self
        if let runLoop = pairingRunLoop {
            service.schedule(in: runLoop, forMode: .common)
        }
        resolvingServices.append(service)
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        service.stop()
        if let runLoop = pairingRunLoop {
            service.remove(from: runLoop, forMode: .common)
        }
        service.delegate = nil
        resolvingServices.removeAll { $0 === service }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        NSLog("[Pairing] Browse failed: code=%d", code)
    }
}
