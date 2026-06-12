import Foundation
import Darwin
import Network
import AppKit
import ShowNetwork

// ShowNetwork-based discovery for the Sync app.
//
// Three responsibilities:
//   • BonjourAdvertiser — Backup-role singleton; publishes _rememberlivesync._tcp
//   • BonjourBrowser — Main-role browser for discovering Backup machines
//   • BonjourPairingService — temporary _syncpair._tcp for passwordless pairing

// MARK: - Shared

private let serviceType = "_rememberlivesync._tcp"
private let pairingServiceType = "_syncpair._tcp"

func resolvePreferredInterface() -> Interface? {
    let mac = ConfigStore.shared.config.preferredInterfaceMAC
    if mac.isEmpty {
        return try? Interfaces.list().first { $0.isCandidate }
    }
    return try? Interfaces.find(byMAC: mac)
}

// MARK: - Advertiser (Backup)

enum AdvertiserState: Equatable {
    case idle
    case advertising(name: String)
    case failed(reason: String)
}

final class BonjourAdvertiser: ObservableObject {
    static let shared = BonjourAdvertiser()

    @Published var state: AdvertiserState = .idle
    @Published var confirmedName: String = ""
    @Published var verifyRequestNonce: String = ""

    var pairAckDeviceId: String = ""
    var pairAckNonce: String = ""
    var pairNackDeviceId: String = ""
    var pairNackNonce: String = ""
    private var ackClearWorkItem: DispatchWorkItem?

    private var advertiser: Advertiser?

    private init() {}

    func start() {
        guard advertiser == nil else { return }
        guard let iface = resolvePreferredInterface() else {
            DispatchQueue.main.async { self.state = .failed(reason: "No network interface available") }
            return
        }

        let configName = ConfigStore.shared.config.networkDiscoveryName
        let advertisedName: String
        if !configName.isEmpty {
            advertisedName = configName
        } else {
            let raw = ProcessInfo.processInfo.hostName
            advertisedName = raw
                .replacingOccurrences(of: ".local.", with: "")
                .replacingOccurrences(of: ".local", with: "")
        }

        let txt = buildTXTRecord()

        let adv = Advertiser(interface: iface, type: serviceType, name: advertisedName, port: 22, txt: txt)
        do {
            try adv.start { [weak self] event in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch event {
                    case .registered(let name, _, _):
                        self.confirmedName = name
                        self.state = .advertising(name: name)
                    case .error(let err):
                        self.state = .failed(reason: err.description)
                    }
                }
            }
            advertiser = adv
        } catch {
            DispatchQueue.main.async { self.state = .failed(reason: error.localizedDescription) }
        }
    }

    func stop() {
        advertiser?.stop()
        advertiser = nil
        DispatchQueue.main.async { self.state = .idle }
    }

    func restart() {
        stop()
        start()
    }

    func updateTXTRecord() {
        guard advertiser != nil else {
            start()
            return
        }
        stop()
        start()
    }

    func stopAndClearState() {
        stop()
        DispatchQueue.main.async { self.confirmedName = "" }
    }

    func setPairAck(forDeviceId deviceId: String, nonce: String) {
        ackClearWorkItem?.cancel()
        pairAckDeviceId = deviceId
        pairAckNonce = nonce
        pairNackDeviceId = ""
        pairNackNonce = ""
        updateTXTRecord()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pairAckDeviceId = ""
            self?.pairAckNonce = ""
            self?.updateTXTRecord()
        }
        ackClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    func setPairNack(forDeviceId deviceId: String, nonce: String) {
        ackClearWorkItem?.cancel()
        pairNackDeviceId = deviceId
        pairNackNonce = nonce
        pairAckDeviceId = ""
        pairAckNonce = ""
        updateTXTRecord()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pairNackDeviceId = ""
            self?.pairNackNonce = ""
            self?.updateTXTRecord()
        }
        ackClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    private func buildTXTRecord() -> [String: String] {
        let intendedDest = ConfigStore.shared.config.destinationFolder
        let effectiveDest = ReceiveMonitor.shared.effectiveDestination
        let freeBytes = Self.getFreeSpace(path: effectiveDest) ?? 0

        var txt: [String: String] = [
            "free": String(freeBytes)
        ]
        if !intendedDest.isEmpty { txt["dest"] = intendedDest }
        if !effectiveDest.isEmpty { txt["effectiveDest"] = effectiveDest }
        if !verifyRequestNonce.isEmpty { txt["verifyReq"] = verifyRequestNonce }

        let identity = ConfigStore.shared.identity
        txt["backupId"] = identity.deviceId
        if let fp = getSSHFingerprint() { txt["backupFP"] = fp }
        // Identity: the account name the Main must ssh in as — broadcast so the
        // Main never types it (auto-username).
        txt["username"] = NSUserName()

        if !pairAckDeviceId.isEmpty {
            txt["pairAck"] = pairAckDeviceId
            txt["pairAckNonce"] = pairAckNonce
        }
        if !pairNackDeviceId.isEmpty {
            txt["pairNack"] = pairNackDeviceId
            txt["pairNackNonce"] = pairNackNonce
        }
        return txt
    }

    static func getFreeSpace(path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage, free > 0 {
            return free
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
           let free = attrs[.systemFreeSize] as? Int64, free > 0 {
            return free
        }
        var volumeRoot = url
        while volumeRoot.path != "/" && volumeRoot.pathComponents.count > 2 {
            volumeRoot = volumeRoot.deletingLastPathComponent()
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: volumeRoot.path),
               let free = attrs[.systemFreeSize] as? Int64, free > 0 {
                return free
            }
        }
        return nil
    }
}

// MARK: - Browser (Main)

struct DiscoveredBackup: Identifiable, Equatable {
    let id: String
    let hostname: String
    let resolvedIP: String
    let destinationPath: String
    let effectiveDestinationPath: String
    let freeSpaceBytes: Int64
    var isReachableOnSelectedInterface: Bool = true
    var backupDeviceId: String = ""
    var backupFingerprint: String = ""
    var username: String = ""  // Backup's macOS account name ("" = older Backup, no broadcast)

    var isUsingFallback: Bool {
        !effectiveDestinationPath.isEmpty && effectiveDestinationPath != destinationPath
    }
}

enum BrowserState: Equatable {
    case idle
    case searching
    case failed(reason: String)
}

final class BonjourBrowser: ObservableObject {
    static let shared = BonjourBrowser()

    @Published var services: [DiscoveredBackup] = []
    @Published var state: BrowserState = .idle
    @Published var isCurrentPeerReachable: Bool = true

    var pairingAckCallback: ((String, String) -> Void)?
    var pairingNackCallback: ((String, String) -> Void)?

    private var browser: Browser?
    private var resolvers: [String: Resolver] = [:]
    private var lastHandledVerifyNonce: String = ""

    // Rename settling window: after the Main asks the Backup to rename, the old
    // advertisement can linger (lost mDNS goodbye). Until the new name resolves
    // (or Settings times the rename out), an entry with the old name must not
    // overwrite config.lastBackupDiscoveryName — that's the old-name flashback.
    private var renameSettlingOldName: String? = nil
    private var renameSettlingNewName: String? = nil

    private init() {}

    func noteRenamePending(oldName: String, newName: String) {
        renameSettlingOldName = oldName
        renameSettlingNewName = newName
    }

    func clearRenameSettling() {
        renameSettlingOldName = nil
        renameSettlingNewName = nil
    }

    func start() {
        guard browser == nil else { return }
        guard let iface = resolvePreferredInterface() else {
            DispatchQueue.main.async {
                self.state = .failed(reason: "No network interface available")
            }
            return
        }

        DispatchQueue.main.async {
            self.state = .searching
            self.services = []
        }

        let b = Browser(interface: iface, type: serviceType)
        do {
            try b.start { [weak self] event in
                DispatchQueue.main.async {
                    self?.handleBrowserEvent(event, interface: iface)
                }
            }
            browser = b
        } catch {
            DispatchQueue.main.async {
                self.state = .failed(reason: error.localizedDescription)
            }
        }
    }

    func stop() {
        browser?.stop()
        browser = nil
        for (_, resolver) in resolvers {
            resolver.stop()
        }
        resolvers.removeAll()
        DispatchQueue.main.async {
            self.state = .idle
            self.services = []
        }
    }

    func restart() {
        stop()
        // Clear destinationIP on interface change — will be re-set if peer is reachable on new interface
        ConfigStore.shared.config.destinationIP = ""
        ConfigStore.shared.config.backupHostname = ""
        isCurrentPeerReachable = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.start()
        }
    }

    private func handleBrowserEvent(_ event: Browser.Event, interface: Interface) {
        switch event {
        case .added(let name, let type, let domain, _):
            startResolver(name: name, type: type, domain: domain, interface: interface)
        case .removed(let name, _, _, _):
            resolvers[name]?.stop()
            resolvers.removeValue(forKey: name)
            services.removeAll { $0.id == name }
        case .error(let err):
            state = .failed(reason: err.description)
        }
    }

    private func startResolver(name: String, type: String, domain: String, interface: Interface) {
        // Stop any existing resolver for this name before overwriting — a duplicate
        // .added (advertiser restart) would otherwise orphan a live DNS-SD query.
        resolvers[name]?.stop()
        let resolver = Resolver(interface: interface, name: name, type: type, domain: domain)
        resolvers[name] = resolver
        do {
            try resolver.start { [weak self] event in
                DispatchQueue.main.async {
                    self?.handleResolverEvent(event, serviceName: name, interface: interface)
                }
            }
        } catch {
            resolvers.removeValue(forKey: name)
        }
    }

    private func handleResolverEvent(_ event: Resolver.Event, serviceName: String, interface: Interface) {
        // NOTE: no resolver-dict membership guard here — late .resolved events must
        // be processed. The Backup's advertiser stop+starts mid-protocol (pairing
        // acks, TXT updates), and under remove/add races the re-install of the
        // entry by a "late" event is load-bearing (a guard here broke pairing).
        // Rename staleness is handled by id+IP+hostname (stale-entry drop below).
        switch event {
        case .resolved(let host, _, let txt, let addresses):
            // IPv4-only preferred-address selection — keep ssh/rsync traffic on the bound NIC.
            // IPv6 (ULA / link-local with %scope) is deferred to v2; ignored here so no IPv6
            // address can ever reach the engine dest-string sites (which would need bracketing).
            let ipv4s = addresses.filter { PreferredAddress.isIPv4($0) }
            guard !ipv4s.isEmpty else { return }

            let resolvedIP: String
            let isReachable: Bool

            if let subnet = getInterfaceSubnet(name: interface.name) {
                if let chosen = PreferredAddress.pickPreferredIPv4(from: ipv4s, subnet: subnet) {
                    // On the bound interface (link-local 169.254/16, or private same-subnet)
                    // → the address is only reachable via this NIC, so traffic stays on it.
                    resolvedIP = chosen
                    isReachable = true
                } else {
                    // No on-interface IPv4 (no link-local / private same-subnet) → unreachable.
                    // NO routable fallback: a routable IPv4 could egress another NIC and leak.
                    // Keep a display IP only; it never becomes destinationIP (gated by isReachable=false).
                    resolvedIP = ipv4s.first { !$0.hasPrefix("169.254.") } ?? ipv4s[0]
                    isReachable = false
                }
            } else {
                // Bound subnet undeterminable (e.g. automatic mode, candidate without IPv4) → permissive.
                resolvedIP = ipv4s.first { !$0.hasPrefix("169.254.") } ?? ipv4s[0]
                isReachable = true
            }

            let hostname = host
                .replacingOccurrences(of: ".local.", with: "")
                .replacingOccurrences(of: ".local", with: "")

            let destPath = txt["dest"] ?? "~/Sync"
            let effectivePath = txt["effectiveDest"] ?? destPath
            let freeBytes = Int64(txt["free"] ?? "0") ?? 0
            let backupId = txt["backupId"] ?? ""
            let backupFP = txt["backupFP"] ?? ""
            let backupUsername = txt["username"] ?? ""  // "" = older Backup

            if let currentIP = getCurrentIP(), resolvedIP == currentIP {
                return
            }

            let backup = DiscoveredBackup(
                id: serviceName,
                hostname: hostname,
                resolvedIP: resolvedIP,
                destinationPath: destPath,
                effectiveDestinationPath: effectivePath,
                freeSpaceBytes: freeBytes,
                isReachableOnSelectedInterface: isReachable,
                backupDeviceId: backupId,
                backupFingerprint: backupFP,
                username: backupUsername
            )

            // A different service name resolving to the same IP + hostname is a stale
            // pre-rename advertisement of this same device (its goodbye was lost) —
            // drop it and stop its resolver so old + new never coexist in the list.
            let staleIds = services.filter {
                $0.resolvedIP == resolvedIP && $0.hostname == hostname && $0.id != serviceName
            }.map(\.id)
            for staleId in staleIds {
                resolvers[staleId]?.stop()
                resolvers.removeValue(forKey: staleId)
            }
            services.removeAll { $0.id == serviceName || staleIds.contains($0.id) }
            services.append(backup)
            services.sort { $0.hostname.localizedCaseInsensitiveCompare($1.hostname) == .orderedAscending }

            // The requested new name is live — the rename has settled.
            if serviceName == renameSettlingNewName {
                clearRenameSettling()
            }

            handlePairingFields(txt: txt)
            handleVerifyRequest(txt: txt, serviceName: serviceName, resolvedIP: resolvedIP, isReachable: isReachable)
            handleAutoReconnect(backup: backup)

            // Update reachability for currently-targeted peer; clear stale destinationIP if unreachable
            let currentDestIP = ConfigStore.shared.config.destinationIP
            if !currentDestIP.isEmpty {
                if let targetedService = services.first(where: { $0.resolvedIP == currentDestIP }) {
                    if isCurrentPeerReachable != targetedService.isReachableOnSelectedInterface {
                        isCurrentPeerReachable = targetedService.isReachableOnSelectedInterface
                    }
                    if !isCurrentPeerReachable {
                        ConfigStore.shared.config.destinationIP = ""
                        ConfigStore.shared.config.backupHostname = ""
                    }
                }
            }

        case .error:
            break
        }
    }

    private func handlePairingFields(txt: [String: String]) {
        if let pairAck = txt["pairAck"], let nonce = txt["pairAckNonce"], !pairAck.isEmpty, !nonce.isEmpty {
            pairingAckCallback?(pairAck, nonce)
        }
        if let pairNack = txt["pairNack"], let nonce = txt["pairNackNonce"], !pairNack.isEmpty, !nonce.isEmpty {
            pairingNackCallback?(pairNack, nonce)
        }
    }

    private func handleVerifyRequest(txt: [String: String], serviceName: String, resolvedIP: String, isReachable: Bool) {
        guard let verifyReq = txt["verifyReq"], !verifyReq.isEmpty, verifyReq != lastHandledVerifyNonce else { return }
        let config = ConfigStore.shared.config
        if let service = services.first(where: { $0.id == serviceName }),
           config.destinationIP == service.resolvedIP,
           isReachable {
            lastHandledVerifyNonce = verifyReq
            SyncEngine.shared.triggerRemoteVerify()
        }
    }

    private func handleAutoReconnect(backup: DiscoveredBackup) {
        guard backup.isReachableOnSelectedInterface else { return }
        let config = ConfigStore.shared.config
        let nameMatch = !config.lastBackupDiscoveryName.isEmpty && backup.id == config.lastBackupDiscoveryName
        let ipMatch = !config.lastBackupIP.isEmpty && backup.resolvedIP == config.lastBackupIP
        let isCurrentConnection = !config.destinationIP.isEmpty && backup.resolvedIP == config.destinationIP

        if nameMatch || ipMatch || isCurrentConnection {
            if config.destinationIP != backup.resolvedIP || config.backupHostname != backup.hostname {
                ConfigStore.shared.config.destinationIP = backup.resolvedIP
                ConfigStore.shared.config.backupHostname = backup.hostname
            }
            // Write-on-change: this runs on every matched resolve — unguarded writes
            // would re-render every ConfigStore observer and schedule config saves.
            if ConfigStore.shared.config.backupDestination != backup.destinationPath {
                ConfigStore.shared.config.backupDestination = backup.destinationPath
            }
            if SyncEngine.shared.usingFallback != backup.isUsingFallback {
                SyncEngine.shared.usingFallback = backup.isUsingFallback
            }
            // Adopt the advertised name — except while a rename is settling: the old
            // advertisement may still resolve, and re-adopting its name would clobber
            // the optimistic new name (old-name flashback / ping-pong).
            if !nameMatch && config.lastBackupDiscoveryName != backup.id
                && backup.id != renameSettlingOldName {
                ConfigStore.shared.config.lastBackupDiscoveryName = backup.id
            }
            // Auto-username: the Backup broadcasts its account name — in automatic
            // mode the broadcast wins (only the Backup knows its own account).
            // Guarded: no churn, and "" (older Backup) never overwrites.
            if !backup.username.isEmpty && config.username != backup.username {
                ConfigStore.shared.config.username = backup.username
            }
            if !isCurrentPeerReachable { isCurrentPeerReachable = true }
        }
    }

    private func checkSubnetReachability(ip: String) -> Bool {
        let mac = ConfigStore.shared.config.preferredInterfaceMAC
        if mac.isEmpty { return true }
        guard let iface = try? Interfaces.find(byMAC: mac),
              iface.ipv4 != nil else { return true }
        guard let subnet = getInterfaceSubnet(name: iface.name) else { return true }
        return isOnSubnet(ip, ifaceIP: subnet.ip, mask: subnet.mask)
    }

    private func getCurrentIP() -> String? {
        if let iface = resolvePreferredInterface(), let ip = iface.ipv4 {
            return ip
        }
        return try? Interfaces.list().first { $0.isCandidate }?.ipv4
    }

    private func getInterfaceSubnet(name interfaceName: String) -> (ip: UInt32, mask: UInt32)? {
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

    private func isOnSubnet(_ ipString: String, ifaceIP: UInt32, mask: UInt32) -> Bool {
        var addr = in_addr()
        guard inet_pton(AF_INET, ipString, &addr) == 1 else { return false }
        return (addr.s_addr & mask) == (ifaceIP & mask)
    }
}

// MARK: - BonjourPairingService

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

final class BonjourPairingService: ObservableObject {
    static let shared = BonjourPairingService()

    @Published var state: PairingState = .idle

    private var isPairingInProgress = false
    private var advertiser: Advertiser?
    private var browser: Browser?
    private var resolvers: [String: Resolver] = [:]
    private var currentNonce: String = ""
    private var targetBackupId: String = ""
    private var pairingCompletion: ((Bool, String?) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    private var handledNonces: Set<String> = []

    private init() {}

    // MARK: - Main-role: Initiate pairing

    func startPairing(targetBackupId: String, completion: @escaping (Bool, String?) -> Void) {
        guard !isPairingInProgress else {
            completion(false, "Pairing already in progress")
            return
        }
        isPairingInProgress = true
        self.targetBackupId = targetBackupId
        self.pairingCompletion = completion
        self.currentNonce = UUID().uuidString

        DispatchQueue.main.async { self.state = .advertising(targetBackupId: targetBackupId) }

        ensureSSHKeyExists { [weak self] keyOK in
            guard let self else { return }
            guard keyOK else {
                self.finishPairing(success: false, error: "Could not generate SSH key")
                return
            }
            self.startAdvertisingPairing()
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.isPairingInProgress else { return }
            self.cancelPairing(reason: .timeout)
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)

        BonjourBrowser.shared.pairingAckCallback = { [weak self] deviceId, nonce in
            self?.handleAck(fromDeviceId: deviceId, nonce: nonce)
        }
        BonjourBrowser.shared.pairingNackCallback = { [weak self] deviceId, nonce in
            self?.handleNack(fromDeviceId: deviceId, nonce: nonce)
        }
    }

    private func startAdvertisingPairing() {
        guard let iface = resolvePreferredInterface() else {
            finishPairing(success: false, error: "No network interface available")
            return
        }

        let identity = ConfigStore.shared.identity
        let pubKeyPath = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/id_ed25519.pub")
        guard let pubKey = try? String(contentsOfFile: pubKeyPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !pubKey.isEmpty else {
            finishPairing(success: false, error: "No SSH key found")
            return
        }

        guard let fingerprint = getSSHFingerprint() else {
            finishPairing(success: false, error: "Could not get key fingerprint")
            return
        }

        let txt: [String: String] = [
            "mainId": identity.deviceId,
            "mainName": identity.deviceName,
            "mainPubKey": pubKey,
            "mainFP": fingerprint,
            "targetBackupId": targetBackupId,
            "nonce": currentNonce
        ]

        // Port must be non-zero: DNSServiceRegister treats port 0 as a non-discoverable
        // placeholder, so the Backup's browser never sees it. The value itself is irrelevant
        // for pairing (all data rides in TXT; acks come back via _rememberlivesync).
        let adv = Advertiser(interface: iface, type: pairingServiceType, name: identity.deviceName, port: 22, txt: txt)
        do {
            try adv.start { [weak self] event in
                DispatchQueue.main.async {
                    if case .error(let err) = event {
                        self?.finishPairing(success: false, error: err.description)
                    }
                }
            }
            advertiser = adv
        } catch {
            finishPairing(success: false, error: error.localizedDescription)
        }
    }

    private func handleAck(fromDeviceId deviceId: String, nonce: String) {
        guard isPairingInProgress,
              deviceId == ConfigStore.shared.identity.deviceId,
              nonce == currentNonce else { return }

        if let backup = BonjourBrowser.shared.services.first(where: { _ in true }) {
            ConfigStore.shared.markPeerAsPairedOnMain(
                peerDeviceId: targetBackupId,
                peerName: backup.hostname,
                peerFingerprint: ""
            )
        }
        finishPairing(success: true, error: nil)
    }

    private func handleNack(fromDeviceId deviceId: String, nonce: String) {
        guard isPairingInProgress,
              deviceId == ConfigStore.shared.identity.deviceId,
              nonce == currentNonce else { return }
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

        advertiser?.stop()
        advertiser = nil

        let errorMsg: String?
        switch reason {
        case .timeout: errorMsg = "Pairing timed out"
        case .declined: errorMsg = "Backup declined the pairing request"
        case .failed(let msg): errorMsg = msg
        default: errorMsg = nil
        }

        isPairingInProgress = false
        DispatchQueue.main.async {
            self.state = reason
            self.pairingCompletion?(false, errorMsg)
            self.pairingCompletion = nil
        }
    }

    private func finishPairing(success: Bool, error: String?) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        BonjourBrowser.shared.pairingAckCallback = nil
        BonjourBrowser.shared.pairingNackCallback = nil

        advertiser?.stop()
        advertiser = nil

        isPairingInProgress = false
        DispatchQueue.main.async {
            if success {
                self.state = .paired(peerName: self.targetBackupId)
            } else {
                self.state = .failed(reason: error ?? "Unknown error")
            }
            self.pairingCompletion?(success, error)
            self.pairingCompletion = nil
        }
    }

    private func ensureSSHKeyExists(completion: @escaping (Bool) -> Void) {
        let fm = FileManager.default
        let sshDir = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
        let keyPath = (sshDir as NSString).appendingPathComponent("id_ed25519")

        if fm.fileExists(atPath: keyPath) {
            completion(true)
            return
        }

        if !fm.fileExists(atPath: sshDir) {
            do {
                try fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true, attributes: nil)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir)
            } catch {
                completion(false)
                return
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        proc.arguments = ["-t", "ed25519", "-f", keyPath, "-N", "", "-q"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { p in
            DispatchQueue.main.async { completion(p.terminationStatus == 0) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do { try proc.run() } catch { DispatchQueue.main.async { completion(false) } }
        }
    }

    // MARK: - Backup-role: Listen for pairing requests

    func startListening() {
        guard browser == nil else { return }
        guard let iface = resolvePreferredInterface() else { return }

        let b = Browser(interface: iface, type: pairingServiceType)
        do {
            try b.start { [weak self] event in
                DispatchQueue.main.async {
                    self?.handlePairingBrowserEvent(event, interface: iface)
                }
            }
            browser = b
            DispatchQueue.main.async { self.state = .browsing }
        } catch {
            // Silent failure for listening
        }
    }

    func stopListening() {
        browser?.stop()
        browser = nil
        for (_, resolver) in resolvers {
            resolver.stop()
        }
        resolvers.removeAll()
        DispatchQueue.main.async { self.state = .idle }
    }

    private func handlePairingBrowserEvent(_ event: Browser.Event, interface: Interface) {
        switch event {
        case .added(let name, let type, let domain, _):
            let resolver = Resolver(interface: interface, name: name, type: type, domain: domain)
            resolvers[name] = resolver
            do {
                try resolver.start { [weak self] event in
                    DispatchQueue.main.async {
                        self?.handlePairingResolverEvent(event)
                    }
                }
            } catch {
                resolvers.removeValue(forKey: name)
            }
        case .removed(let name, _, _, _):
            resolvers[name]?.stop()
            resolvers.removeValue(forKey: name)
        case .error:
            break
        }
    }

    private func handlePairingResolverEvent(_ event: Resolver.Event) {
        guard case .resolved(_, _, let txt, _) = event else { return }

        guard let mainId = txt["mainId"],
              let mainName = txt["mainName"],
              let mainPubKey = txt["mainPubKey"],
              let mainFP = txt["mainFP"],
              let targetId = txt["targetBackupId"],
              let nonce = txt["nonce"] else { return }

        let myId = ConfigStore.shared.identity.deviceId
        guard targetId == myId else { return }
        guard !handledNonces.contains(nonce) else { return }
        handledNonces.insert(nonce)

        DispatchQueue.main.async { self.state = .waitingForConfirm(peerName: mainName) }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let appDelegate = AppDelegate.shared else { return }
            appDelegate.showPairingConfirmDialog(peerName: mainName, peerFingerprint: mainFP) { [weak self] result in
                guard let self else { return }
                switch result {
                case .trust:
                    let success = ConfigStore.shared.markPeerAsTrustedOnBackup(
                        peerDeviceId: mainId,
                        peerName: mainName,
                        peerPublicKey: mainPubKey,
                        peerFingerprint: mainFP
                    )
                    if success {
                        BonjourAdvertiser.shared.setPairAck(forDeviceId: mainId, nonce: nonce)
                        DispatchQueue.main.async { self.state = .paired(peerName: mainName) }
                    } else {
                        DispatchQueue.main.async { self.state = .failed(reason: "Failed to save key") }
                    }
                case .decline:
                    BonjourAdvertiser.shared.setPairNack(forDeviceId: mainId, nonce: nonce)
                    DispatchQueue.main.async { self.state = .declined(peerName: mainName) }
                }
            }
        }
    }
}

// MARK: - Preferred-address selection (IPv4 only; IPv6 deferred to v2)

// Chooses the peer IPv4 address that keeps SSH/rsync traffic on the bound interface.
// Leak-safe order:
//   1. IPv4 link-local (169.254.0.0/16) on the bound interface's subnet
//   2. IPv4 private (10/8, 172.16/12, 192.168/16) on the bound interface's subnet
//   else: nil — peer is not reachable on the bound interface. There is deliberately NO
//         "any routable IPv4" fallback: a routable address can egress another NIC and
//         would reintroduce the cross-interface leak the isolation fix removed.
// IPv6 selection (ULA / fe80 with %scope) + rsync bracketing is a separate v2 task and
// is intentionally absent here, so no IPv6 address can ever become the ssh destination.
enum PreferredAddress {

    /// Returns the preferred on-interface IPv4 address, or nil if none qualifies.
    /// - Parameters:
    ///   - ipv4Addresses: peer addresses already filtered to IPv4 (see `isIPv4`).
    ///   - subnet: the bound interface's (ip, mask) in network byte order.
    static func pickPreferredIPv4(from ipv4Addresses: [String],
                                  subnet: (ip: UInt32, mask: UInt32)) -> String? {
        let onSubnet = ipv4Addresses.filter { isOnSubnet($0, ifaceIP: subnet.ip, mask: subnet.mask) }
        guard !onSubnet.isEmpty else { return nil }

        // Rule 1: link-local on the bound subnet.
        if let linkLocal = onSubnet.first(where: { $0.hasPrefix("169.254.") }) {
            return linkLocal
        }
        // Rule 2: RFC 1918 private on the bound subnet.
        if let priv = onSubnet.first(where: { isPrivateIPv4($0) }) {
            return priv
        }
        // On-subnet but neither link-local nor private (public same-subnet) → not selected.
        return nil
    }

    /// True if the string is a dotted-quad IPv4 address (rejects IPv6 / anything with ':').
    static func isIPv4(_ s: String) -> Bool {
        if s.contains(":") { return false }
        var addr = in_addr()
        return inet_pton(AF_INET, s, &addr) == 1
    }

    /// True for RFC 1918 private ranges: 10/8, 172.16/12, 192.168/16.
    static func isPrivateIPv4(_ s: String) -> Bool {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return false }
        let host = UInt32(bigEndian: addr.s_addr)            // network → host byte order
        if (host & 0xFF00_0000) == 0x0A00_0000 { return true }   // 10.0.0.0/8
        if (host & 0xFFF0_0000) == 0xAC10_0000 { return true }   // 172.16.0.0/12
        if (host & 0xFFFF_0000) == 0xC0A8_0000 { return true }   // 192.168.0.0/16
        return false
    }

    /// Masked-subnet equality. `ifaceIP` and `mask` are network byte order (sockaddr_in.s_addr).
    static func isOnSubnet(_ ipString: String, ifaceIP: UInt32, mask: UInt32) -> Bool {
        var addr = in_addr()
        guard inet_pton(AF_INET, ipString, &addr) == 1 else { return false }
        return (addr.s_addr & mask) == (ifaceIP & mask)
    }
}
