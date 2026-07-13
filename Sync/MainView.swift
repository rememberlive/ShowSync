// Copyright © 2026 Remember Chaitezvi. All rights reserved.
// Part of ShowSync — Remember Live.

import SwiftUI
import AppKit
import CoreServices

private let darkBg = Color(red: 0.12, green: 0.12, blue: 0.12)
private let popoverWidth: CGFloat = 360

// Verbose sync step-tracing. DEBUG-only: the body is compiled out of release
// builds (#if DEBUG), so these never ship — but the call sites are kept verbatim
// (same format strings + args as NSLog) for future debugging. Mirrors NSLog via
// NSLogv so formatting/bridging is identical.
@inline(__always)
private func syncTrace(_ format: String, _ args: CVarArg...) {
    #if DEBUG
    withVaList(args) { NSLogv(format, $0) }
    #endif
}

// MARK: - Types

struct DryRunResult: Equatable {
    let title: String
    let body: String
}

struct SyncProgress: Equatable {
    let transferred: Int64   // bytes received by Backup (SSH du polling)
    let expected: Int64      // transfer delta from the estimate dry-run (0 = unknown → indeterminate bar)
    let startTime: Date      // when this sync started
    let bytesPerSec: Double? // smoothed rate (≥3 du samples); nil = still calculating
}

enum MainViewState {
    case normal, dryRunResult, confirmCancel, confirmQuit, history
}

enum SyncStatus {
    case ready, preparing, syncing, done, cancelled, error(String)

    var color: Color {
        switch self {
        case .ready:      return .gray
        case .preparing:  return .yellow
        case .syncing:    return .yellow
        case .done:       return .green
        case .cancelled:  return .gray
        case .error:      return .red
        }
    }

    var label: String {
        switch self {
        case .ready:      return "Ready"
        case .preparing:  return "Preparing..."
        case .syncing:    return "Syncing"
        case .done:       return "Synced"
        case .cancelled:  return "Cancelled"
        case .error:      return "Failed"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .syncing: return true
        default: return false
        }
    }
}

extension SyncStatus: Equatable {
    static func == (lhs: SyncStatus, rhs: SyncStatus) -> Bool {
        switch (lhs, rhs) {
        case (.ready, .ready), (.preparing, .preparing), (.syncing, .syncing),
             (.done, .done), (.cancelled, .cancelled): return true
        case (.error(let a), .error(let b)):           return a == b
        default:                                       return false
        }
    }
}

enum VerifyStatus: Equatable {
    case idle
    case verifying
    case verified(deep: Bool)   // deep = checksum (-avc); false = fast size+modtime (-av)
    case differs(Int)  // Number of files that differ
    case failed(String)

    var color: Color {
        switch self {
        case .idle:      return .gray
        case .verifying: return .yellow
        case .verified:  return .green
        case .differs:   return .orange
        case .failed:    return .red
        }
    }

    var label: String {
        switch self {
        case .idle:             return ""
        case .verifying:        return "Verifying… (checks every file)"
        case .verified(let deep): return deep ? "Verified — all files match" : "Verified — sizes & dates match"
        case .differs(let n):   return "\(n) file\(n == 1 ? "" : "s") differ — re-sync recommended"
        case .failed(let msg):  return msg
        }
    }
}

// MARK: - Sync engine

final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()

    @Published var status: SyncStatus = .ready
    @Published var lastSyncTime: Date?
    @Published var dryRunResult: DryRunResult? = nil
    @Published var syncProgress: SyncProgress? = nil
    @Published var fallbackNotice: String? = nil  // Calm notice when fallback to ~/Sync
    @Published var lowSpaceNotice: String? = nil  // Notice when Backup refuses due to low space
    @Published var syncBlockedNotice: String? = nil  // Why a sync request was refused (was a silent return)
    @Published var usingFallback: Bool = false    // True when sync redirected to ~/Sync due to unavailable drive
    @Published var manualModeFreeSpace: Int64 = 0 // Free space from manual-mode config poll (bytes)

    // First-hand write-test verdict for the CURRENT configured real destination.
    // The Main's own probe of whether it can write the real dest wins over the
    // Backup's advertised fallback state (both directions) so a stale advertisement
    // can't force fallback and a "backup says fine" can't clear a genuine fallback.
    // Keyed to the dest path + refreshed on every sync's write-test, so it never
    // suppresses a later genuine change. nil = no first-hand result this session.
    var lastRealDestWriteTest: (path: String, writable: Bool)? = nil

    // Reconcile usingFallback with the Backup's advertised fallback, giving
    // precedence to the Main's own most-recent write-test verdict for the same
    // configured dest. No matching first-hand verdict → adopt as before.
    func reconcileFallback(advertisedFallback: Bool, realDest: String) {
        let target: Bool
        if let fh = lastRealDestWriteTest, fh.path == realDest {
            target = !fh.writable            // first-hand writability wins (both directions)
        } else {
            target = advertisedFallback      // no first-hand verdict for this dest → adopt as today
        }
        if usingFallback != target { usingFallback = target }
    }

    // Auto Sync - Independent timer system
    @Published var nextAutoSyncDate: Date?
    private var autoSyncTimer: Timer?

    // Push Sync - date for countdown display (debounce lives in FSEventsWatcher)
    @Published var nextPushSyncDate: Date?

    // Set true when an rsync launch failure has not yet been acknowledged by a
    // dropdown open. Cleared on next successful sync or when the user opens the popover.
    @Published var hasUnacknowledgedError: Bool = false
    private var task: Process?
    private var syncTotalFiles: Int    = 0
    private var syncStartTime:  Date   = Date()
    private var syncUsername:   String = ""
    private var syncIP:         String = ""
    private var syncRemotePath: String = "~/Sync"
    private var isAutoSync:     Bool   = false
    private var isPushSync:     Bool   = false

    // Verify Now - separate from sync
    @Published var verifyStatus: VerifyStatus = .idle
    private var verifyTask: Process?
    // V1.1: widened private → internal so the Windows-target verify (WindowsTransport.swift)
    // can honor Backup-requested verifies and reset the flag. Behavior unchanged.
    var isRemoteVerify: Bool = false  // True when triggered by Backup via Bonjour

    private init() {}

    deinit {
        task?.terminate()
        verifyTask?.terminate()
        duPollTimer?.invalidate()
        autoSyncTimer?.invalidate()
        Task { @MainActor in
            ConfigStore.shared.isSyncing = false
        }
    }

    // Single entry point for both preview (config.dryRunEnabled=true) and real sync.
    // Phase 1 always runs a dry run to get accurate totals and show "Preparing...".
    // Phase 2 starts the real transfer once totals are known (skipped in preview mode).
    func sync(config: Config, isAuto: Bool = false, isPush: Bool = false) {
        guard config.isReadyToSync else {
            surfaceBlockedNotice(
                config.sourceFolder.isEmpty ? "Can't sync — choose a source folder"
                : config.destinationIP.isEmpty ? "Can't sync — no Backup selected"
                : config.username.isEmpty ? "Can't sync — no Backup user set"
                : "Can't sync — connection not yet set up")
            return
        }
        guard !status.isActive else { return }  // UI already shows the active sync
        // Interface isolation: in automatic mode, refuse sync if peer not reachable on
        // bound interface. Reconciled with the live ssh probe: it binds -b to the chosen
        // NIC, so a reachable ConnectionStatus is stronger proof than the browser
        // heuristic. Manual mode bypasses this check (user explicitly entered the IP).
        if config.discoveryMode == "automatic" {
            // sync() always runs on the main thread (button taps, main-runloop timers)
            let sshReachable = MainActor.assumeIsolated { ConnectionStatus.shared.state == .reachable }
            guard BonjourBrowser.shared.isCurrentPeerReachable || sshReachable else {
                NSLog("[Sync] Refused: peer not reachable on selected interface")
                surfaceBlockedNotice("Can't sync — Backup not reachable on selected network")
                return
            }
        }
        syncBlockedNotice = nil
        // Sync supersedes verify - cancel any in-flight verify before starting
        if verifyStatus == .verifying { cancelVerify() }
        isAutoSync         = isAuto
        isPushSync         = isPush
        status             = .preparing
        ConfigStore.shared.isSyncing = true
        ConfigStore.shared.iconState = .syncing
        expectedSize   = 0
        syncProgress   = nil
        syncTotalFiles = 0
        syncUsername   = config.username
        syncIP         = config.destinationIP
        // Always target the CONFIGURED real destination so the write-test below
        // re-probes it every sync (self-heal). Fallback to ~/Sync is decided by
        // THIS attempt's write-test result, not a cached usingFallback flag — the
        // old pre-redirect latched onto ~/Sync and never re-probed the real dest.
        syncRemotePath = config.backupDestination.isEmpty ? "~/Sync" : config.backupDestination

        let mode = config.discoveryMode
        syncTrace("[SyncTrace] 1 sync requested, mode=%@, remotePath='%@', usingFallback=%d, dryRunEnabled=%d, isAuto=%d",
              mode, syncRemotePath, usingFallback ? 1 : 0, config.dryRunEnabled ? 1 : 0, isAuto ? 1 : 0)

        // platform=windows (TXT key / manual toggle) routes to the scp/sftp transport; the flag
        // is never set by a Mac Backup, so the fall-through below is today's path, untouched.
        if config.backupPlatform == "windows" {
            WindowsTransport.shared.startSync(config: config, isAuto: isAuto, isPush: isPush)
            return
        }

        // Check if this is a "Check Files" preview request
        let isPreviewOnly = config.dryRunEnabled && !isAuto

        if isPreviewOnly {
            // Preview mode: run dry-run to show file list (uses fixed pipe drain)
            runDryRunPreview(config: config)
        } else {
            // Normal sync: SKIP dry-run entirely, go straight to write-test and rsync
            syncTrace("[SyncTrace] 2 SKIPPING dry-run (normal sync path)")
            syncTotalFiles = 0
            expectedSize   = 0
            syncStartTime  = Date()
            fallbackNotice = nil
            lowSpaceNotice = nil

            // Transfer estimate — concurrent with the write-test, never blocks the sync.
            // Fills expectedSize/syncTotalFiles when it lands; on failure the bar
            // simply stays indeterminate.
            runTransferEstimate(config: config)

            // Write-test then rsync
            let originalRemotePath = syncRemotePath
            syncTrace("[SyncTrace] 4 starting write-test, remotePath='%@'", originalRemotePath)
            runSyncTimeWriteTest(username: config.username, ip: config.destinationIP, remotePath: originalRemotePath) { [weak self] result, _ in
                guard let self else {
                    syncTrace("[SyncTrace] 5 write-test callback but self is nil")
                    return
                }
                guard self.status == .preparing else { return }
                syncTrace("[SyncTrace] 5 write-test result=%d (0=writable, 1=unwritable, 2=testFailed)", result == .writable ? 0 : (result == .unwritable ? 1 : 2))
                switch result {
                case .writable:
                    // First-hand verdict: the Main CAN write the real dest. Record it
                    // (wins over adoption) and self-heal if we were latched in fallback.
                    self.lastRealDestWriteTest = (originalRemotePath, true)
                    if self.usingFallback { self.usingFallback = false }
                case .unwritable:
                    // First-hand verdict: the Main CANNOT write the real dest.
                    self.lastRealDestWriteTest = (originalRemotePath, false)
                    self.syncRemotePath = "~/Sync"
                    self.usingFallback = true
                    self.fallbackNotice = "Couldn't write to the chosen folder — backing up to the default Sync folder instead."
                    NSLog("[Sync] Destination unwritable, falling back to ~/Sync")
                case .testFailed:
                    // Ambiguous (SSH error/timeout) — not a writability verdict; leave
                    // the last first-hand result untouched and proceed.
                    NSLog("[Sync] Write-test failed (SSH error), proceeding anyway")
                }
                syncTrace("[SyncTrace] 6 calling continueSyncAfterWriteTest")
                self.continueSyncAfterWriteTest(config: config, totalBytes: 0, fileCount: 0, dryRunOutput: "")
            }
        }
    }

    // MARK: - Dry-run preview (Check Files only)

    private func runDryRunPreview(config: Config) {
        let rawSource = config.sourceFolder.hasPrefix("~")
            ? (NSHomeDirectory() as NSString).appendingPathComponent(String(config.sourceFolder.dropFirst()))
            : config.sourceFolder
        let source = rawSource.hasSuffix("/") ? rawSource : rawSource + "/"
        let rsyncCandidates = ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/usr/bin/rsync"]
        let rsyncPath = rsyncCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/rsync"
        // R1: escape the remote path for the remote shell (spaces in dest names)
        let dest = "\(syncUsername)@\(syncIP):\(rsyncEscapedRemotePath(syncRemotePath, rsyncPath: rsyncPath))/"

        syncTrace("[SyncTrace] 2 starting dry-run PREVIEW, rsyncPath=%@", rsyncPath)
        let prepProc = Process()
        prepProc.executableURL = URL(fileURLWithPath: rsyncPath)
        var prepArgs = ["-av", "--dry-run", "--stats"] + RsyncExclusions.args
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !ConfigStore.shared.config.preferredInterfaceMAC.isEmpty {
            prepArgs.insert(contentsOf: ["-e", "ssh -b \(bindIP) -o ServerAliveInterval=15 -o ServerAliveCountMax=3"], at: 0)
        }
        prepArgs.append(contentsOf: [source, dest])
        prepProc.arguments = prepArgs
        let prepPipe = Pipe()
        prepProc.standardOutput = prepPipe
        prepProc.standardError  = prepPipe
        task = prepProc

        // Thread-safe output buffer
        class OutputBuffer {
            private var data = Data()
            private let lock = NSLock()
            func append(_ chunk: Data) {
                lock.lock()
                data.append(chunk)
                lock.unlock()
            }
            func getString() -> String {
                lock.lock()
                let result = String(data: data, encoding: .utf8) ?? ""
                lock.unlock()
                return result
            }
        }
        let outputBuffer = OutputBuffer()

        // Use readInBackgroundAndNotify for proper async pipe drain (no deadlock)
        let fileHandle = prepPipe.fileHandleForReading
        NotificationCenter.default.addObserver(
            forName: .NSFileHandleDataAvailable,
            object: fileHandle,
            queue: nil
        ) { [weak fileHandle] _ in
            guard let fh = fileHandle else { return }
            let chunk = fh.availableData
            if !chunk.isEmpty {
                outputBuffer.append(chunk)
                fh.waitForDataInBackgroundAndNotify()
            }
        }
        fileHandle.waitForDataInBackgroundAndNotify()

        // Timeout: 30s backstop
        var completed = false
        let completedLock = NSLock()
        let timeoutItem = DispatchWorkItem { [weak prepProc] in
            completedLock.lock()
            let done = completed
            completedLock.unlock()
            if !done, let p = prepProc, p.isRunning {
                syncTrace("[SyncTrace] 2f dry-run PREVIEW TIMEOUT (30s)")
                p.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutItem)

        prepProc.terminationHandler = { [weak self] p in
            timeoutItem.cancel()
            completedLock.lock()
            completed = true
            completedLock.unlock()
            NotificationCenter.default.removeObserver(self as Any, name: .NSFileHandleDataAvailable, object: fileHandle)
            syncTrace("[SyncTrace] 3 dry-run PREVIEW terminated, exit=%d", p.terminationStatus)
            let output = outputBuffer.getString()

            Task { @MainActor [weak self] in
                guard let self, self.status == .preparing else {
                    syncTrace("[SyncTrace] 3b dry-run guard FAILED")
                    return
                }

                self.status = .ready
                ConfigStore.shared.isSyncing = false
                ConfigStore.shared.iconState = ConfigStore.shared.config.isReadyToSync ? .idle : .notConfigured

                let wasTimeout = p.terminationStatus == -1 || p.terminationStatus == 15
                if wasTimeout {
                    self.dryRunResult = DryRunResult(
                        title: "Check Files Timeout",
                        body: "The file check took too long. Try syncing directly."
                    )
                    return
                }
                if p.terminationStatus != 0 {
                    self.dryRunResult = DryRunResult(
                        title: "Check Files Failed",
                        body: "Couldn't connect to the backup. Check your connection."
                    )
                    return
                }

                let fileCount  = Self.parseDryRunFileCount(output)
                let totalBytes = Self.parseTotalSize(output) ?? 0
                syncTrace("[SyncTrace] 3c preview parsed: fileCount=%d totalBytes=%lld", fileCount, totalBytes)

                let (previewFiles, _) = Self.parseDryRunOutput(output)
                if fileCount > 0 && previewFiles.isEmpty {
                    let note = totalBytes > 0 ? "\nTotal size: \(formatBytes(totalBytes))" : ""
                    self.dryRunResult = DryRunResult(
                        title: "Check Files Complete",
                        body: "\(fileCount) file\(fileCount == 1 ? "" : "s") will be transferred\(note)"
                    )
                } else {
                    let (title, body) = Self.formatDryRunMessage(
                        files: previewFiles,
                        transferBytes: totalBytes > 0 ? totalBytes : nil
                    )
                    self.dryRunResult = DryRunResult(title: title, body: body)
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            syncTrace("[SyncTrace] 2b dry-run PREVIEW dispatch executing")
            do {
                try prepProc.run()
                syncTrace("[SyncTrace] 2c dry-run PREVIEW process started")
            } catch {
                timeoutItem.cancel()
                syncTrace("[SyncTrace] 2d dry-run PREVIEW launch FAILED: %@", error.localizedDescription)
                Task { @MainActor [weak self] in
                    self?.handleRsyncLaunchFailure()
                }
            }
        }
    }

    private func continueSyncAfterWriteTest(config: Config, totalBytes: Int64, fileCount: Int, dryRunOutput: String) {
        syncTrace("[SyncTrace] 7 continueSyncAfterWriteTest entered, setting status=syncing")
        status = .syncing
        // Use the engine fields, not the caller's values — the concurrent estimate
        // fills them with real totals (the call site passes zeros).
        writeSyncStart(totalBytes: expectedSize, totalFiles: syncTotalFiles)

        // Rebuild dest with potentially updated syncRemotePath
        let rawSource = config.sourceFolder.hasPrefix("~")
            ? (NSHomeDirectory() as NSString).appendingPathComponent(String(config.sourceFolder.dropFirst()))
            : config.sourceFolder
        let source = rawSource.hasSuffix("/") ? rawSource : rawSource + "/"
        let rsyncCandidates = ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/usr/bin/rsync"]
        let rsyncPath = rsyncCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/rsync"
        // R1: escape the remote path for the remote shell (spaces in dest names)
        let dest = "\(syncUsername)@\(syncIP):\(rsyncEscapedRemotePath(syncRemotePath, rsyncPath: rsyncPath))/"

        syncTrace("[SyncTrace] 8 about to launch rsync, source='%@', dest='%@'", source, dest)

                let launchRsync = { [weak self] in
                    guard let self else { return }
                    syncTrace("[SyncTrace] 9 launchRsync closure executing")
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: rsyncPath)
                    var rsyncArgs = ["-av", "--stats"] + RsyncExclusions.args
                    if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
                       !ConfigStore.shared.config.preferredInterfaceMAC.isEmpty {
                        rsyncArgs.insert(contentsOf: ["-e", "ssh -b \(bindIP) -o ServerAliveInterval=15 -o ServerAliveCountMax=3"], at: 0)
                    }
                    rsyncArgs.append(contentsOf: [source, dest])
                    proc.arguments = rsyncArgs

                    // Capture stdout for --stats output using concurrent drain pattern
                    class OutputBuffer {
                        private var data = Data()
                        private let lock = NSLock()
                        func append(_ chunk: Data) {
                            lock.lock()
                            data.append(chunk)
                            lock.unlock()
                        }
                        func getString() -> String {
                            lock.lock()
                            let result = String(data: data, encoding: .utf8) ?? ""
                            lock.unlock()
                            return result
                        }
                    }
                    let stdoutBuffer = OutputBuffer()
                    let stdoutPipe = Pipe()
                    proc.standardOutput = stdoutPipe

                    let stdoutHandle = stdoutPipe.fileHandleForReading
                    let stdoutObserver = NotificationCenter.default.addObserver(
                        forName: .NSFileHandleDataAvailable,
                        object: stdoutHandle,
                        queue: nil
                    ) { [weak stdoutHandle] _ in
                        guard let fh = stdoutHandle else { return }
                        let chunk = fh.availableData
                        if !chunk.isEmpty {
                            stdoutBuffer.append(chunk)
                            fh.waitForDataInBackgroundAndNotify()
                        }
                    }
                    stdoutHandle.waitForDataInBackgroundAndNotify()

                    let errPipe = Pipe()
                    proc.standardError  = errPipe

                    proc.terminationHandler = { [weak self] p in
                        // Capture decision values IMMEDIATELY before any async hop
                        let exitCode = p.terminationStatus
                        let wasUsingFallback = self?.usingFallback ?? false
                        let syncTrigger = (self?.isAutoSync ?? false) ? "auto" : ((self?.isPushSync ?? false) ? "push" : "manual")
                        let syncDest = self?.syncRemotePath ?? "~/Sync"

                        syncTrace("[SyncTrace] 10 rsync terminated, exit=%d", exitCode)
                        NotificationCenter.default.removeObserver(stdoutObserver)
                        let statsOutput = stdoutBuffer.getString()
                        _ = errPipe.fileHandleForReading.readDataToEndOfFile() // drain stderr
                        if exitCode != 0 {
                            NSLog("[Sync] exit %d", exitCode)
                        }
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.stopDuPolling()
                            self.syncProgress = nil
                            ConfigStore.shared.isSyncing = false

                            // Check for .sync_refused (Backup low on space)
                            self.checkSyncRefused(username: self.syncUsername, ip: self.syncIP, remotePath: self.syncRemotePath) { [weak self] refused in
                                guard let self else { return }
                                if refused {
                                    self.lowSpaceNotice = "Not enough space on the backup drive. Free up space to resume backups."
                                    self.status = .error("Backup drive low on space")
                                    ConfigStore.shared.iconState = .error
                                    self.cleanupSignalFiles()  // FIX 1: clean up .sync_start on refusal

                                    // Record refused transfer log entry
                                    let duration = Int(Date().timeIntervalSince(self.syncStartTime))
                                    let entry = TransferLogEntry(
                                        id: UUID(),
                                        date: Date(),
                                        trigger: syncTrigger,
                                        result: "refused",
                                        fileCount: 0,
                                        totalBytes: 0,
                                        durationSeconds: duration,
                                        destination: syncDest,
                                        usedFallback: wasUsingFallback
                                    )
                                    ConfigStore.shared.appendTransferLogEntry(entry)
                                    return
                                }

                                if exitCode == 0 {
                                    let duration = Int(Date().timeIntervalSince(self.syncStartTime))
                                    self.lastSyncTime = Date()
                                    ConfigStore.shared.config.sshKeysConfigured = true
                                    ConfigStore.shared.iconState = wasUsingFallback ? .warning : .success
                                    self.status = .done
                                    self.writeSyncComplete(
                                        totalFiles: self.syncTotalFiles,
                                        totalBytes: self.expectedSize,
                                        duration:   duration)

                                    // Record transfer log entry (stats parsing is additive, outside decision path)
                                    let actualFileCount = Self.parseStatsFileCount(statsOutput)
                                    let actualBytes = Self.parseStatsTotalBytes(statsOutput)
                                    let entry = TransferLogEntry(
                                        id: UUID(),
                                        date: Date(),
                                        trigger: syncTrigger,
                                        result: wasUsingFallback ? "fallback" : "success",
                                        fileCount: actualFileCount,
                                        totalBytes: actualBytes,
                                        durationSeconds: duration,
                                        destination: syncDest,
                                        usedFallback: wasUsingFallback
                                    )
                                    ConfigStore.shared.appendTransferLogEntry(entry)

                                    // Prune old versions (fire-and-forget)
                                    if config.versionHistoryEnabled {
                                        self.pruneVersions(
                                            username: config.username,
                                            ip: config.destinationIP,
                                            remotePath: self.syncRemotePath,
                                            maxCount: config.maxVersionCount
                                        )
                                    }

                                    // Clear any stale .sync_refused on success
                                    self.clearSyncRefused()
                                    // Clear fallback flag if we synced to the chosen path (drive is back)
                                    if self.syncRemotePath != "~/Sync" {
                                        self.usingFallback = false
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                                        guard self?.status == .done else { return }
                                        self?.status = .ready
                                        self?.fallbackNotice = nil
                                    }
                                } else {
                                    self.cleanupSignalFiles()
                                    self.status = .error("Sync interrupted — files may be incomplete")
                                    ConfigStore.shared.iconState = .error

                                    // Record failed transfer log entry
                                    let duration = Int(Date().timeIntervalSince(self.syncStartTime))
                                    let entry = TransferLogEntry(
                                        id: UUID(),
                                        date: Date(),
                                        trigger: syncTrigger,
                                        result: "failed",
                                        fileCount: 0,
                                        totalBytes: 0,
                                        durationSeconds: duration,
                                        destination: syncDest,
                                        usedFallback: wasUsingFallback
                                    )
                                    ConfigStore.shared.appendTransferLogEntry(entry)
                                }
                            }
                        }
                    }

                    self.task = proc
                    self.startDuPolling(username: config.username, ip: config.destinationIP)
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        do {
                            try proc.run()
                        } catch {
                            NSLog("[Sync] rsync launch failed: %@", error.localizedDescription)
                            Task { @MainActor [weak self] in
                                self?.handleRsyncLaunchFailure()
                            }
                        }
                    }
                }

        // Create inline versions before sync (if enabled), then launch rsync
        if config.versionHistoryEnabled {
            createInlineVersions(
                config: config,
                source: source,
                rsyncPath: rsyncPath,
                completion: launchRsync
            )
        } else {
            launchRsync()
        }
    }

    func cancel() {
        // A Windows run never populates the private per-run fields below; it carries its own
        // metadata and cancel/cleanup. isSyncActive is false whenever no Windows transfer runs.
        if WindowsTransport.shared.isSyncActive {
            WindowsTransport.shared.cancelSync()
            return
        }

        let wasActive = status.isActive
        let cancelTrigger = isAutoSync ? "auto" : (isPushSync ? "push" : "manual")
        let cancelDest = syncRemotePath
        let cancelFallback = usingFallback
        let cancelDuration = Int(Date().timeIntervalSince(syncStartTime))

        task?.terminate()
        task = nil
        isAutoSync = false
        isPushSync = false
        stopDuPolling()
        cleanupSignalFiles()
        Task { @MainActor [weak self] in
            self?.status = .cancelled
            self?.syncProgress = nil
            ConfigStore.shared.isSyncing = false
            ConfigStore.shared.iconState = ConfigStore.shared.config.isReadyToSync ? .idle : .notConfigured

            // Record cancelled transfer log entry (only if sync was actually active)
            if wasActive {
                let entry = TransferLogEntry(
                    id: UUID(),
                    date: Date(),
                    trigger: cancelTrigger,
                    result: "cancelled",
                    fileCount: 0,
                    totalBytes: 0,
                    durationSeconds: cancelDuration,
                    destination: cancelDest,
                    usedFallback: cancelFallback
                )
                ConfigStore.shared.appendTransferLogEntry(entry)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.status == .cancelled { self?.status = .ready }
            }
        }
    }

    // MARK: - Verify Now

    func verifyNow(config: Config) {
        guard config.isReadyToSync else { return }
        guard verifyStatus != .verifying else { return }
        guard !status.isActive else { return }  // Verify yields to sync

        if config.backupPlatform == "windows" {
            WindowsTransport.shared.startVerify(config: config)
            return
        }

        verifyStatus = .verifying

        let rawSource = config.sourceFolder
        let source = rawSource.hasSuffix("/") ? rawSource : rawSource + "/"
        let remotePath = usingFallback ? "~/Sync" : (config.backupDestination.isEmpty ? "~/Sync" : config.backupDestination)
        let rsyncCandidates = ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/usr/bin/rsync"]
        let rsyncPath = rsyncCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/rsync"
        // R1: escape the remote path for the remote shell (spaces in dest names)
        let dest = "\(config.username)@\(config.destinationIP):\(rsyncEscapedRemotePath(remotePath, rsyncPath: rsyncPath))/"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rsyncPath)

        // Deep (default) checksums every file (-avc); Fast compares size+modtime only (-av).
        var args = (config.fastVerify ? ["-av", "--dry-run"] : ["-avc", "--dry-run"]) + RsyncExclusions.args
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !config.preferredInterfaceMAC.isEmpty {
            args.insert(contentsOf: ["-e", "ssh -b \(bindIP)"], at: 0)
        }
        args.append(contentsOf: [source, dest])
        proc.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Thread-safe output buffer for concurrent drain
        class OutputBuffer {
            private var data = Data()
            private let lock = NSLock()
            func append(_ chunk: Data) {
                lock.lock()
                data.append(chunk)
                lock.unlock()
            }
            func getString() -> String {
                lock.lock()
                let result = String(data: data, encoding: .utf8) ?? ""
                lock.unlock()
                return result
            }
        }
        let outputBuffer = OutputBuffer()

        // CRITICAL: Concurrent pipe drain to avoid deadlock
        // Use readInBackgroundAndNotify for async, non-blocking reads
        let stdoutHandle = stdoutPipe.fileHandleForReading
        NotificationCenter.default.addObserver(
            forName: .NSFileHandleDataAvailable,
            object: stdoutHandle,
            queue: nil
        ) { [weak stdoutHandle] _ in
            guard let fh = stdoutHandle else { return }
            let chunk = fh.availableData
            if !chunk.isEmpty {
                outputBuffer.append(chunk)
                fh.waitForDataInBackgroundAndNotify()
            }
        }
        stdoutHandle.waitForDataInBackgroundAndNotify()

        // Drain stderr too (discard, but must drain to avoid pipe full)
        let stderrHandle = stderrPipe.fileHandleForReading
        NotificationCenter.default.addObserver(
            forName: .NSFileHandleDataAvailable,
            object: stderrHandle,
            queue: nil
        ) { [weak stderrHandle] _ in
            guard let fh = stderrHandle else { return }
            let chunk = fh.availableData
            if !chunk.isEmpty {
                fh.waitForDataInBackgroundAndNotify()
            }
        }
        stderrHandle.waitForDataInBackgroundAndNotify()

        proc.terminationHandler = { [weak self] p in
            // Small delay to let final data arrive
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                let output = outputBuffer.getString()

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.verifyTask = nil

                    var resultCode: String = "error"
                    if p.terminationStatus == 0 {
                        // Success: count files that would transfer (= differ)
                        let differCount = self.countDifferingFiles(output)
                        if differCount == 0 {
                            self.verifyStatus = .verified(deep: !config.fastVerify)
                            resultCode = "ok"
                        } else {
                            self.verifyStatus = .differs(differCount)
                            resultCode = "differs:\(differCount)"
                        }
                    } else {
                        // SSH/connection failure
                        self.verifyStatus = .failed("Verify failed — couldn't reach Backup")
                        resultCode = "error"
                    }

                    // Write result to Backup if this was a remote verify request
                    if self.isRemoteVerify {
                        self.writeVerifyResult(resultCode)
                        self.isRemoteVerify = false
                    }

                    // Clear status after 10 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                        if case .verified = self?.verifyStatus { self?.verifyStatus = .idle }
                        if case .differs = self?.verifyStatus { self?.verifyStatus = .idle }
                        if case .failed = self?.verifyStatus { self?.verifyStatus = .idle }
                    }
                }
            }
        }

        verifyTask = proc
        DispatchQueue.global(qos: .utility).async {
            do {
                try proc.run()
            } catch {
                Task { @MainActor [weak self] in
                    self?.verifyTask = nil
                    self?.verifyStatus = .failed("Verify failed — couldn't start rsync")
                }
            }
        }
    }

    func cancelVerify() {
        if WindowsTransport.shared.isVerifyActive {
            WindowsTransport.shared.cancelVerify()
            return
        }

        verifyTask?.terminate()
        verifyTask = nil
        verifyStatus = .idle
        isRemoteVerify = false
    }

    // Called by BonjourBrowser when Backup requests a verify via TXT record.
    // Returns true only when a verify actually STARTED. verifyNow() can bail on
    // its own guards (isReadyToSync / already verifying / active sync); leaving
    // isRemoteVerify latched true on a bail killed every later Backup request
    // for the session (the guard below swallowed them). Callers must not
    // consume the request nonce unless this returns true, so a bailed request
    // can be retried on the next poll/resolve.
    @discardableResult
    func triggerRemoteVerify() -> Bool {
        guard !isRemoteVerify else { return false }  // Already handling a remote verify
        guard !status.isActive else { return false }  // Verify yields to sync
        isRemoteVerify = true
        verifyNow(config: ConfigStore.shared.config)
        // Both engines set their "verifying" state synchronously on start; if
        // neither did, verifyNow bailed — unlatch so the next request works.
        let started = verifyStatus == .verifying || WindowsTransport.shared.isVerifyActive
        if !started { isRemoteVerify = false }
        return started
    }

    private func countDifferingFiles(_ output: String) -> Int {
        // rsync -avc --dry-run output: files that would transfer appear as regular file lines
        // Lines that start with typical rsync prefixes or are file paths indicate differences
        // Count lines that look like file paths (not summary/stats lines)
        let lines = output.components(separatedBy: .newlines)
        var count = 0

        var inFileList = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // GNU rsync: files after "sending incremental file list"
            if trimmed.contains("sending incremental file list") {
                inFileList = true
                continue
            }
            // openrsync: files after "Transfer starting:"
            if trimmed.hasPrefix("Transfer starting:") {
                inFileList = true
                continue
            }
            // End of file list markers
            if trimmed.hasPrefix("sent ") || trimmed.hasPrefix("total size") ||
               trimmed.hasPrefix("Number of") || trimmed.contains("speedup is") {
                inFileList = false
                continue
            }

            // Count file lines (not directories ending in /)
            if inFileList && !trimmed.hasSuffix("/") && !trimmed.isEmpty {
                count += 1
            }
        }
        return count
    }

    // Called when rsync (prepare or transfer) cannot be launched at all — distinct from
    // rsync running and exiting non-zero, which is handled by its terminationHandler.
    // Resets engine state, surfaces an inline error, and asks the Backup to drop any
    // signal files we may have written before the failure (FIX 5).
    private func handleRsyncLaunchFailure() {
        task?.terminate()
        task = nil
        stopDuPolling()
        syncProgress = nil
        status = .error("Couldn't start the backup — check that rsync is installed")
        hasUnacknowledgedError = true
        ConfigStore.shared.isSyncing = false
        ConfigStore.shared.iconState = .error
        cleanupSignalFiles()
    }

    // MARK: - Dry run output parsing

    // openrsync (macOS /usr/bin/rsync) format — lists files after "Transfer starting:".
    private static func parseDryRunOutput(_ output: String) -> (files: [String], transferBytes: Int64?) {
        let lines = output.components(separatedBy: .newlines)
        var files: [String] = []
        var transferBytes: Int64? = nil
        var collectingFiles = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Transfer starting:") { collectingFiles = true; continue }
            if collectingFiles && t.isEmpty { collectingFiles = false; continue }
            if collectingFiles && !t.isEmpty && t != "./" && !t.hasSuffix("/")
                && !t.contains(": ") && !t.hasSuffix(" B") {
                files.append(t)
            }
            if t.hasPrefix("total size is ") {
                let numStr = t.dropFirst("total size is ".count)
                    .components(separatedBy: " ").first?
                    .replacingOccurrences(of: ",", with: "") ?? ""
                transferBytes = Int64(numStr)
            }
        }
        return (files, transferBytes)
    }

    // Cross-version file count: GNU rsync "Number of regular files transferred" or
    // openrsync file-list fallback.
    private static func parseDryRunFileCount(_ output: String) -> Int {
        for line in output.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Number of regular files transferred:") {
                let numStr = t.dropFirst("Number of regular files transferred:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: CharacterSet(charactersIn: " (")).first ?? ""
                if let n = Int(numStr) { return n }
            }
        }
        return parseDryRunOutput(output).files.count
    }

    private static func formatDryRunMessage(files: [String], transferBytes: Int64?) -> (title: String, body: String) {
        guard !files.isEmpty else {
            return ("Check Files Complete", "Everything is up to date.\nNo files need to be transferred.")
        }
        var lines: [String] = []
        lines.append("\(files.count) file\(files.count == 1 ? "" : "s") will be transferred")
        if let bytes = transferBytes { lines.append("Total size: \(formatBytes(bytes))") }
        lines.append("")
        let names = files.map { URL(fileURLWithPath: $0).lastPathComponent }
        for (i, name) in names.prefix(5).enumerated() {
            let display = name.count > 35
                ? String(name.prefix(15)) + "..." + String(name.suffix(12))
                : name
            lines.append("  \(i + 1). \(display)")
        }
        if names.count > 5 { lines.append("  + \(names.count - 5) more") }
        return ("Check Files Complete", lines.joined(separator: "\n"))
    }

    // MARK: - Stats output parsing (from --stats flag)

    static func parseStatsFileCount(_ output: String) -> Int {
        for line in output.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            // GNU rsync 3.x: "Number of regular files transferred:"
            if t.hasPrefix("Number of regular files transferred:") {
                let numStr = t.dropFirst("Number of regular files transferred:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ",", with: "")
                    .components(separatedBy: CharacterSet.decimalDigits.inverted).first ?? ""
                if let n = Int(numStr) { return n }
            }
            // openrsync / Apple: "Number of files transferred:"
            if t.hasPrefix("Number of files transferred:") {
                let numStr = t.dropFirst("Number of files transferred:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ",", with: "")
                    .components(separatedBy: CharacterSet.decimalDigits.inverted).first ?? ""
                if let n = Int(numStr) { return n }
            }
        }
        return 0
    }

    static func parseStatsTotalBytes(_ output: String) -> Int64 {
        for line in output.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Total transferred file size:") {
                let numStr = t.dropFirst("Total transferred file size:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ",", with: "")
                    .components(separatedBy: CharacterSet.decimalDigits.inverted).first ?? ""
                if let n = Int64(numStr) { return n }
            }
        }
        return 0
    }

    // Transient "why the sync was refused" notice (lowSpaceNotice pattern) —
    // replaces the old silent returns. Self-clears so the dropdown stays calm.
    private func surfaceBlockedNotice(_ text: String) {
        syncBlockedNotice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.syncBlockedNotice == text { self?.syncBlockedNotice = nil }
        }
    }

    // MARK: - SSH du polling for byte-accurate progress

    private var expectedSize:      Int64 = 0
    private var duPollTimer:       Timer?
    private var duInFlight:        Bool  = false
    private var baselineSyncBytes: Int64 = 0
    private var rateSamples: [(time: Date, bytes: Int64)] = []  // rolling window for smoothed rate
    private var lastWrittenProgress: (percent: Int, bytesDone: Int64)? = nil

    // Pre-sync transfer estimate — runs concurrently with the write-test and never
    // delays or blocks the sync. Parses the transfer DELTA ("Total transferred file
    // size"), not the full source size (parseTotalSize reads the wrong field for
    // progress: on an additive sync most bytes already exist at the destination).
    private func runTransferEstimate(config: Config) {
        let rawSource = config.sourceFolder.hasPrefix("~")
            ? (NSHomeDirectory() as NSString).appendingPathComponent(String(config.sourceFolder.dropFirst()))
            : config.sourceFolder
        let source = rawSource.hasSuffix("/") ? rawSource : rawSource + "/"
        let rsyncCandidates = ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/usr/bin/rsync"]
        let rsyncPath = rsyncCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/rsync"
        // R1: escape the remote path for the remote shell (spaces in dest names)
        let dest = "\(syncUsername)@\(syncIP):\(rsyncEscapedRemotePath(syncRemotePath, rsyncPath: rsyncPath))/"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rsyncPath)
        // No -v: stats only, no file list — output stays tiny (no pipe-drain risk)
        var args = ["-a", "--dry-run", "--stats"] + RsyncExclusions.args
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !ConfigStore.shared.config.preferredInterfaceMAC.isEmpty {
            args.insert(contentsOf: ["-e", "ssh -b \(bindIP)"], at: 0)
        }
        args.append(contentsOf: [source, dest])
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] p in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard p.terminationStatus == 0 else { return }  // estimate failed → indeterminate bar
                guard self.status == .preparing || self.status == .syncing else { return }
                if let delta = Self.parseTransferDelta(output) {
                    self.expectedSize = delta
                }
                if let files = Self.parseTransferredFileCount(output) {
                    self.syncTotalFiles = files
                }
            }
        }
        DispatchQueue.global(qos: .utility).async { try? proc.run() }
    }

    // "Total transferred file size: 51200 B" (openrsync) / "...: 51,200 bytes" (GNU)
    private static func parseTransferDelta(_ output: String) -> Int64? {
        for line in output.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Total transferred file size:") {
                let numStr = t.dropFirst("Total transferred file size:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ").first?
                    .replacingOccurrences(of: ",", with: "") ?? ""
                if let n = Int64(numStr) { return n }
            }
        }
        return nil
    }

    // "Number of files transferred: 1" (openrsync) / "Number of regular files transferred: 1" (GNU)
    private static func parseTransferredFileCount(_ output: String) -> Int? {
        for line in output.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Number of regular files transferred:") || t.hasPrefix("Number of files transferred:") {
                let numStr = t.components(separatedBy: ":").last?
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ").first?
                    .replacingOccurrences(of: ",", with: "") ?? ""
                if let n = Int(numStr) { return n }
            }
        }
        return nil
    }

    private func startDuPolling(username: String, ip: String) {
        duInFlight = false
        rateSamples = []
        lastWrittenProgress = nil
        runDu(username: username, ip: ip) { [weak self] baseline in
            guard let self else { return }
            self.baselineSyncBytes = baseline
            self.duPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.pollDu(username: username, ip: ip)
            }
        }
    }

    private func pollDu(username: String, ip: String) {
        runDu(username: username, ip: ip) { [weak self] current in
            guard let self else { return }
            let transferred = max(0, current - self.baselineSyncBytes)
            var capped = self.expectedSize > 0 ? min(transferred, self.expectedSize) : transferred
            capped = max(capped, self.syncProgress?.transferred ?? 0)  // bar never moves backward

            // Rolling rate window (5 samples ≈ 5 s) for a smoothed ETA
            rateSamples.append((time: Date(), bytes: capped))
            if rateSamples.count > 5 { rateSamples.removeFirst() }
            var rate: Double? = nil
            if rateSamples.count >= 3,
               let first = rateSamples.first, let last = rateSamples.last {
                let dt = last.time.timeIntervalSince(first.time)
                if dt > 0 { rate = Double(last.bytes - first.bytes) / dt }
            }

            let newProgress = SyncProgress(transferred: capped,
                                           expected: self.expectedSize,
                                           startTime: self.syncStartTime,
                                           bytesPerSec: rate)
            if self.syncProgress != newProgress { self.syncProgress = newProgress }

            let percent: Int = self.expectedSize > 0
                ? Int(min(Double(capped) / Double(self.expectedSize), 1.0) * 100)
                : -1
            // Skip the ssh write when nothing changed (e.g. stalled transfer)
            if self.lastWrittenProgress?.percent != percent || self.lastWrittenProgress?.bytesDone != capped {
                self.lastWrittenProgress = (percent, capped)
                self.writeSyncProgress(percent: percent, bytesDone: capped, bytesTotal: self.expectedSize)
            }
        }
    }

    private func stopDuPolling() {
        duPollTimer?.invalidate()
        duPollTimer = nil
        duInFlight  = false
        rateSamples = []
    }

    private func runDu(username: String, ip: String, completion: @escaping (Int64) -> Void) {
        guard !duInFlight else { return }
        duInFlight = true
        let escaped = remoteShellPath(syncRemotePath)  // R2: "~/Sync" → "$HOME/Sync" (tilde won't expand in quotes)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var duArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "StrictHostKeyChecking=no"]
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !ConfigStore.shared.config.preferredInterfaceMAC.isEmpty {
            duArgs.insert(contentsOf: ["-b", bindIP], at: 0)
        }
        duArgs.append(contentsOf: ["--", "\(username)@\(ip)", "du -sk \"\(escaped)\" 2>/dev/null | cut -f1"])
        proc.arguments = duArgs
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let str  = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let kb = Int64(str) ?? 0
            Task { @MainActor [weak self] in
                self?.duInFlight = false
                completion(kb * 1024)
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try proc.run()
            } catch {
                NSLog("[Sync/du] launch failed: %@", error.localizedDescription)
                Task { @MainActor [weak self] in
                    // Reset the in-flight guard so the next poll tick can retry.
                    self?.duInFlight = false
                }
            }
        }
    }

    private static func parseTotalSize(_ output: String) -> Int64? {
        for line in output.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("total size is ") {
                let numStr = t.dropFirst("total size is ".count)
                    .components(separatedBy: " ").first?
                    .replacingOccurrences(of: ",", with: "") ?? ""
                if let n = Int64(numStr) { return n }
            }
            if t.hasPrefix("Total file size:") {
                let numStr = t.dropFirst("Total file size:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " ").first?
                    .replacingOccurrences(of: ",", with: "") ?? ""
                if let n = Int64(numStr) { return n }
            }
        }
        return nil
    }

    private func writeSyncStart(totalBytes: Int64, totalFiles: Int) {
        let escaped = remoteShellPath(syncRemotePath)  // R2: "~/Sync" → "$HOME/Sync" (tilde won't expand in quotes)
        sshWrite("echo '{\"totalBytes\":\(totalBytes),\"totalFiles\":\(totalFiles)}' > \"\(escaped)/\(SignalFile.start)\"", label: SignalFile.start)
    }

    // Extended payload: bytesDone/bytesTotal let the Backup draw a bar + ETA.
    // percent -1 / bytesTotal 0 = delta unknown (estimate pending or failed).
    private func writeSyncProgress(percent: Int, bytesDone: Int64, bytesTotal: Int64) {
        let escaped = remoteShellPath(syncRemotePath)  // R2: "~/Sync" → "$HOME/Sync" (tilde won't expand in quotes)
        sshWrite("echo '{\"percent\":\(percent),\"bytesDone\":\(bytesDone),\"bytesTotal\":\(bytesTotal)}' > \"\(escaped)/\(SignalFile.progress)\"", label: SignalFile.progress)
    }

    private func writeSyncComplete(totalFiles: Int, totalBytes: Int64, duration: Int) {
        let escaped = remoteShellPath(syncRemotePath)  // R2: "~/Sync" → "$HOME/Sync" (tilde won't expand in quotes)
        sshWrite("echo '{\"totalFiles\":\(totalFiles),\"totalBytes\":\(totalBytes),\"duration\":\(duration)}' > \"\(escaped)/\(SignalFile.complete)\"; rm -f \"\(escaped)/\(SignalFile.start)\" \"\(escaped)/\(SignalFile.progress)\"", label: SignalFile.complete)
    }

    private func cleanupSignalFiles() {
        let escaped = remoteShellPath(syncRemotePath)  // R2: "~/Sync" → "$HOME/Sync" (tilde won't expand in quotes)
        sshWrite("rm -f \"\(escaped)/\(SignalFile.start)\" \"\(escaped)/\(SignalFile.progress)\" \"\(escaped)/\(SignalFile.complete)\"", label: "signal cleanup")
    }

    // Write verify result to Backup (for remote-initiated verify)
    private func writeVerifyResult(_ result: String) {
        let config = ConfigStore.shared.config
        guard !config.username.isEmpty, !config.destinationIP.isEmpty else { return }
        // SYNC-SPEC §8.10: a Windows Backup's default shell can't run the POSIX
        // echo/rm below — route through the Windows transport's PowerShell
        // signal write instead (same payload; Mac path below untouched).
        if config.backupPlatform == "windows" {
            WindowsTransport.writeVerifyResultSignal(
                username: config.username, ip: config.destinationIP,
                destination: config.backupDestination,
                usingFallback: usingFallback, resultCode: result)
            return
        }
        let remotePath = usingFallback ? "~/Sync" : (config.backupDestination.isEmpty ? "~/Sync" : config.backupDestination)
        let escaped = remoteShellPath(remotePath)  // R2: "~/Sync" → "$HOME/Sync" (tilde won't expand in quotes)
        let timestamp = Int(Date().timeIntervalSince1970)
        let cmd = "echo '{\"result\":\"\(result)\",\"ts\":\(timestamp)}' > \"\(escaped)/\(SignalFile.verifyResult)\"; rm -f \"\(escaped)/\(SignalFile.verifyRequest)\""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var sshArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=2", "-o", "StrictHostKeyChecking=no"]
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !config.preferredInterfaceMAC.isEmpty {
            sshArgs.insert(contentsOf: ["-b", bindIP], at: 0)
        }
        sshArgs.append(contentsOf: ["--", "\(config.username)@\(config.destinationIP)", cmd])
        proc.arguments = sshArgs
        proc.standardOutput = FileHandle.nullDevice
        // Never-silent (R3): a denied/failed .verify_result write was previously
        // indistinguishable from a delivered one — the exact failure that cost
        // the external-drive round-trip. Outcome is logged either way.
        let errPipe = Pipe()
        proc.standardError = errPipe
        let target = remotePath
        proc.terminationHandler = { p in
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            if p.terminationStatus == 0 {
                NSLog("[Sync/verify] .verify_result delivered to '%@' (result=%@)", target, result)
            } else {
                let err = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                NSLog("[Sync/verify] .verify_result write FAILED to '%@' (exit %d): %@",
                      target, p.terminationStatus, err)
            }
        }
        DispatchQueue.global(qos: .utility).async { try? proc.run() }
    }

    private func sshWrite(_ command: String, label: String = "") {
        guard !syncUsername.isEmpty, !syncIP.isEmpty else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var sshArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=2", "-o", "StrictHostKeyChecking=no"]
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !ConfigStore.shared.config.preferredInterfaceMAC.isEmpty {
            sshArgs.insert(contentsOf: ["-b", bindIP], at: 0)
        }
        sshArgs.append(contentsOf: ["--", "\(syncUsername)@\(syncIP)", command])
        proc.arguments = sshArgs
        proc.standardOutput = FileHandle.nullDevice
        // Never-silent (R3): failures are logged with the caller's label —
        // fire-and-forget behavior unchanged, but no longer invisible.
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.terminationHandler = { p in
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            if p.terminationStatus != 0 {
                let err = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                NSLog("[Sync/signal] %@ write failed (exit %d): %@",
                      label.isEmpty ? "remote command" : label, p.terminationStatus, err)
            }
        }
        DispatchQueue.global(qos: .utility).async { try? proc.run() }
    }

    // MARK: - Sync-time write-test with fallback

    enum WriteTestResult {
        case writable
        case unwritable   // clear failure — folder gone or permission denied
        case testFailed   // SSH error or timeout — don't block, proceed with sync
    }

    private func runSyncTimeWriteTest(
        username: String,
        ip: String,
        remotePath: String,
        completion: @escaping (WriteTestResult, String) -> Void
    ) {
        let escaped = remoteShellPath(remotePath)  // R2: "~/Sync" → "$HOME/Sync" (tilde won't expand in quotes)
        let testFile = "\(escaped)/.sync_writetest_\(Int.random(in: 1000...9999))"
        let cmd = "touch \"\(testFile)\" && rm -f \"\(testFile)\" && echo OK || echo FAIL"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var testArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=2", "-o", "ServerAliveInterval=2",
                        "-o", "ServerAliveCountMax=2", "-o", "StrictHostKeyChecking=no"]
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !ConfigStore.shared.config.preferredInterfaceMAC.isEmpty {
            testArgs.insert(contentsOf: ["-b", bindIP], at: 0)
        }
        testArgs.append(contentsOf: ["--", "\(username)@\(ip)", cmd])
        proc.arguments = testArgs
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        var completed = false
        let completionLock = NSLock()

        let safeComplete: (WriteTestResult) -> Void = { result in
            completionLock.lock()
            defer { completionLock.unlock() }
            guard !completed else { return }
            completed = true
            Task { @MainActor in
                completion(result, remotePath)
            }
        }

        let timeoutItem = DispatchWorkItem { [weak proc] in
            if let p = proc, p.isRunning {
                NSLog("[Sync] write-test timeout (10s), killing process")
                p.terminate()
            }
            safeComplete(.testFailed)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeoutItem)

        proc.terminationHandler = { p in
            timeoutItem.cancel()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if p.terminationStatus != 0 {
                safeComplete(.testFailed)
            } else if output.contains("OK") {
                safeComplete(.writable)
            } else {
                safeComplete(.unwritable)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try proc.run()
            } catch {
                timeoutItem.cancel()
                NSLog("[Sync] write-test launch failed: %@", error.localizedDescription)
                safeComplete(.testFailed)
            }
        }
    }

    // MARK: - .sync_refused detection

    private func checkSyncRefused(
        username: String,
        ip: String,
        remotePath: String,
        completion: @escaping (Bool) -> Void
    ) {
        let escaped = remoteShellPath(remotePath)  // R2: "~/Sync" → "$HOME/Sync" (tilde won't expand in quotes)
        let refusedPath = "\(escaped)/\(SignalFile.refused)"
        let cmd = "test -f \"\(refusedPath)\" && echo YES || echo NO"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var refuseArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=2", "-o", "StrictHostKeyChecking=no"]
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !ConfigStore.shared.config.preferredInterfaceMAC.isEmpty {
            refuseArgs.insert(contentsOf: ["-b", bindIP], at: 0)
        }
        refuseArgs.append(contentsOf: ["--", "\(username)@\(ip)", cmd])
        proc.arguments = refuseArgs
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { p in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in
                completion(output.contains("YES"))
            }
        }
        DispatchQueue.global(qos: .utility).async {
            do {
                try proc.run()
            } catch {
                NSLog("[Sync] sync_refused check failed: %@", error.localizedDescription)
                Task { @MainActor in
                    completion(false)
                }
            }
        }
    }

    private func clearSyncRefused() {
        let escaped = remoteShellPath(syncRemotePath)  // R2: "~/Sync" → "$HOME/Sync" (tilde won't expand in quotes)
        sshWrite("rm -f \"\(escaped)/\(SignalFile.refused)\"", label: "refused cleanup")
    }

    // MARK: - Auto sync

    // delay: explicit fire interval (timer just fired, or interval changed).
    // nil:   restore saved countdown if still valid and interval unchanged; else full interval.
    func startAutoSync(delay: TimeInterval? = nil) {
        autoSyncTimer?.invalidate()
        autoSyncTimer = nil
        let config = ConfigStore.shared.config
        guard config.autoSyncEnabled else { return }
        let interval: TimeInterval = config.autoSyncInterval == 0 ? 30 : TimeInterval(config.autoSyncInterval * 60)
        let now = Date()

        let fireIn: TimeInterval
        if let d = delay {
            fireIn = max(1.0, d)
        } else if let saved = config.nextAutoSyncDate,
                  saved > now,
                  config.nextAutoSyncScheduledInterval == config.autoSyncInterval {
            fireIn = saved.timeIntervalSince(now)
        } else {
            fireIn = interval
        }

        let fireDate = now.addingTimeInterval(fireIn)
        nextAutoSyncDate = fireDate
        ConfigStore.shared.config.nextAutoSyncDate = fireDate
        ConfigStore.shared.config.nextAutoSyncScheduledInterval = config.autoSyncInterval

        autoSyncTimer = Timer.scheduledTimer(withTimeInterval: fireIn, repeats: false) { [weak self] _ in
            self?.autoSyncTimerFired()
        }
        NSLog("[AutoSync] Next fire in %.0f s", fireIn)
    }

    func stopAutoSync() {
        autoSyncTimer?.invalidate()
        autoSyncTimer    = nil
        nextAutoSyncDate = nil
        ConfigStore.shared.config.nextAutoSyncDate = nil
    }

    private func autoSyncTimerFired() {
        let config = ConfigStore.shared.config
        // Reschedule first so nextAutoSyncDate is always set before sync starts
        let nextInterval: TimeInterval = config.autoSyncInterval == 0 ? 30 : TimeInterval(config.autoSyncInterval * 60)
        startAutoSync(delay: nextInterval)

        // Auto Sync: Independent system with only basic guards
        guard config.autoSyncEnabled, config.isReadyToSync, !status.isActive else { return }
        sync(config: config, isAuto: true)
    }

    // MARK: - Push Sync

    func stopPushSyncDebounce() {
        nextPushSyncDate = nil
    }

    func triggerPushSync() {
        let config = ConfigStore.shared.config
        nextPushSyncDate = nil
        guard config.pushSyncEnabled, config.isReadyToSync, !status.isActive else {
            NSLog("[PushSync] Guard failed - enabled: %@, ready: %@, active: %@",
                  config.pushSyncEnabled ? "YES" : "NO", config.isReadyToSync ? "YES" : "NO", status.isActive ? "YES" : "NO")
            return
        }
        NSLog("[PushSync] Triggering sync")
        sync(config: config, isPush: true)
    }

    private static func hasChangedFiles(sourceFolder: String, since date: Date?) -> Bool {
        let rawSource = sourceFolder.hasPrefix("~")
            ? (NSHomeDirectory() as NSString).appendingPathComponent(String(sourceFolder.dropFirst()))
            : sourceFolder
        guard !rawSource.isEmpty else { return false }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: rawSource),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: .skipsHiddenFiles
        ) else { return false }
        let threshold = date ?? .distantPast
        for case let url as URL in enumerator {
            guard let res = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  res.isRegularFile == true,
                  let mtime = res.contentModificationDate else { continue }
            if mtime > threshold { return true }
        }
        return false
    }

    // MARK: - Version history (inline marker-based)

    // ISOLATION: Ensures completion fires exactly once and allows timeout termination of stuck processes
    private final class VersioningGuard {
        private let lock = NSLock()
        private var completed = false
        private var currentProcess: Process?
        private let completion: () -> Void

        var isCompleted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return completed
        }

        init(completion: @escaping () -> Void) {
            self.completion = completion
        }

        func setProcess(_ proc: Process) {
            lock.lock()
            currentProcess = proc
            lock.unlock()
        }

        func complete() {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            currentProcess = nil
            lock.unlock()
            DispatchQueue.main.async { self.completion() }
        }

        func timeoutFired(reason: String) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            let proc = currentProcess
            currentProcess = nil
            lock.unlock()

            NSLog("[Version] Timeout (%@), abandoning versioning - backup will proceed", reason)
            if let proc = proc, proc.isRunning {
                proc.terminate()
                NSLog("[Version] Terminated stuck process")
            }
            DispatchQueue.main.async { self.completion() }
        }
    }

    private func createInlineVersions(config: Config, source: String, rsyncPath: String, completion: @escaping () -> Void) {
        let timestamp: String = {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            return fmt.string(from: Date())
        }()

        // R1: escape the remote path for the remote shell (spaces in dest names)
        let dest = "\(config.username)@\(config.destinationIP):\(rsyncEscapedRemotePath(syncRemotePath, rsyncPath: rsyncPath))/"

        // ISOLATION: completion-once guard and process tracking for timeout termination
        let guard_ = VersioningGuard(completion: completion)

        // ISOLATION: Master 60s timeout - backup ALWAYS proceeds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
            guard_.timeoutFired(reason: "master 60s")
        }

        NSLog("[Version] Running dry-run to identify changed files")
        let dryRunProc = Process()
        dryRunProc.executableURL = URL(fileURLWithPath: rsyncPath)
        var dryRunArgs = ["-av", "--dry-run", "--out-format=%n"] + RsyncExclusions.args
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !config.preferredInterfaceMAC.isEmpty {
            dryRunArgs.insert(contentsOf: ["-e", "ssh -b \(bindIP)"], at: 0)
        }
        dryRunArgs.append(contentsOf: [source, dest])
        dryRunProc.arguments = dryRunArgs

        let pipe = Pipe()
        dryRunProc.standardOutput = pipe
        dryRunProc.standardError = FileHandle.nullDevice

        dryRunProc.terminationHandler = { [weak self] p in
            guard let self else {
                guard_.complete()
                return
            }

            // ISOLATION: Check if already timed out
            if guard_.isCompleted { return }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if p.terminationStatus != 0 {
                NSLog("[Version] Dry-run failed (exit %d), proceeding without versioning", p.terminationStatus)
                guard_.complete()
                return
            }

            let files = output.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.hasSuffix("/") }
            NSLog("[Version] %d files will change", files.count)

            if files.isEmpty {
                guard_.complete()
                return
            }

            self.copyFilesToVersions(
                files: files,
                timestamp: timestamp,
                username: config.username,
                ip: config.destinationIP,
                remotePath: self.syncRemotePath,
                guard_: guard_
            )
        }

        guard_.setProcess(dryRunProc)

        // ISOLATION: Individual 30s timeout for dry-run
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak dryRunProc] in
            guard let proc = dryRunProc, proc.isRunning else { return }
            guard_.timeoutFired(reason: "dry-run 30s")
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try dryRunProc.run()
            } catch {
                NSLog("[Version] Dry-run launch failed: %@", error.localizedDescription)
                guard_.complete()
            }
        }
    }

    private func copyFilesToVersions(files: [String], timestamp: String, username: String, ip: String, remotePath: String, guard_: VersioningGuard) {
        // ISOLATION: Check if already timed out before starting cp
        if guard_.isCompleted {
            NSLog("[Version] Skipping cp - already timed out")
            return
        }

        let escaped = remoteShellPath(remotePath)  // R2: "~/Sync" → "$HOME/Sync" (tilde won't expand in quotes)

        var copyCommands: [String] = []
        for file in files {
            let escapedFile = shellEscapeForDoubleQuotes(file)

            let base: String
            let ext: String
            if let dotIndex = file.lastIndex(of: "."), dotIndex != file.startIndex {
                base = String(file[..<dotIndex])
                ext = String(file[dotIndex...])
            } else {
                base = file
                ext = ""
            }
            let escapedBase = shellEscapeForDoubleQuotes(base)

            let versionName: String
            if ext.isEmpty {
                versionName = "\(escapedBase)~sync-v~\(timestamp)"
            } else {
                versionName = "\(escapedBase)~sync-v~\(timestamp)\(shellEscapeForDoubleQuotes(ext))"
            }

            copyCommands.append("[ -e \"\(escaped)/\(escapedFile)\" ] && cp -R \"\(escaped)/\(escapedFile)\" \"\(escaped)/\(versionName)\"")
        }

        let cmd = copyCommands.joined(separator: "; ")
        NSLog("[Version] Creating %d inline versions", copyCommands.count)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var sshArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=30", "-o", "StrictHostKeyChecking=no"]
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !ConfigStore.shared.config.preferredInterfaceMAC.isEmpty {
            sshArgs.insert(contentsOf: ["-b", bindIP], at: 0)
        }
        sshArgs.append(contentsOf: ["--", "\(username)@\(ip)", cmd])
        proc.arguments = sshArgs
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { p in
            NSLog("[Version] Copy versions exit=%d", p.terminationStatus)
            guard_.complete()
        }

        guard_.setProcess(proc)

        // ISOLATION: Individual 45s timeout for cp
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45) { [weak proc] in
            guard let proc = proc, proc.isRunning else { return }
            guard_.timeoutFired(reason: "cp 45s")
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try proc.run()
            } catch {
                NSLog("[Version] Copy versions launch failed: %@", error.localizedDescription)
                guard_.complete()
            }
        }
    }

    private func pruneVersions(username: String, ip: String, remotePath: String, maxCount: Int) {
        let N = min(max(maxCount, 3), 20)
        let escaped = remoteShellPath(remotePath)  // R2: "~/Sync" → "$HOME/Sync" (tilde won't expand in quotes)
        // BSD-safe prune: newline-based (no awk RS="\0" which BSD awk doesn't support)
        let cmd = """
cd "\(escaped)" 2>/dev/null || exit 0; \
find . \\( -type f -o -type d \\) -name '*~sync-v~????-??-??_??-??-??*' | \
while IFS= read -r v; do \
original=$(echo "$v" | sed 's/~sync-v~[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}_[0-9]\\{2\\}-[0-9]\\{2\\}-[0-9]\\{2\\}//'); \
printf '%s\\t%s\\n' "$original" "$v"; \
done | sort -t '\t' -k1,1 -k2,2r | \
awk -F'\\t' -v N=\(N) '{if($1!=prev){c=0;prev=$1}c++;if(c>N)print $2}' | \
while IFS= read -r f; do rm -rf "$f"; done
"""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var sshArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=no"]
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !ConfigStore.shared.config.preferredInterfaceMAC.isEmpty {
            sshArgs.insert(contentsOf: ["-b", bindIP], at: 0)
        }
        sshArgs.append(contentsOf: ["--", "\(username)@\(ip)", cmd])
        proc.arguments = sshArgs
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { p in
            NSLog("[VersionPrune] exit=%d", p.terminationStatus)
        }

        // ISOLATION: 30s timeout for prune (fire-and-forget, backup already done)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak proc] in
            guard let proc = proc, proc.isRunning else { return }
            NSLog("[VersionPrune] Timeout 30s, terminating stuck prune")
            proc.terminate()
        }

        DispatchQueue.global(qos: .utility).async {
            do {
                try proc.run()
            } catch {
                NSLog("[VersionPrune] launch failed: %@", error.localizedDescription)
            }
        }
    }

}

// MARK: - Main view

// SSH reachability moved to ConnectionStatus.swift — one shared checker
// feeds the dot here AND the Settings "Secure Connection" label.

struct MainView: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var engine = SyncEngine.shared
    @ObservedObject private var connectionStatus = ConnectionStatus.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var interfaceManager = NetworkInterfaceManager.shared
    @ObservedObject private var fsEventsWatcher = FSEventsWatcher.shared
    @ObservedObject private var bonjourBrowser = BonjourBrowser.shared
    @State private var viewState: MainViewState = .normal
    @State private var clockTick  = Date()
    @State private var clockTimer: Timer? = nil
    @State private var syncEtaText = ""  // smoothed ETA; frozen on stall, never bounces
    @State private var sourceFolderSummary: String? = nil  // "N files · X" — computed on popover open / sync done, never polled
    @State private var connectionInfoHovering = false  // hover highlight on the Connection Info disclosure row
    // Three-state connection badge: ssh measures the MACHINE (sshd survives the
    // app quitting), Bonjour measures the APP. When the targeted peer's
    // advertisement has been absent >5 s (grace kills the TXT-restart churn
    // flicker) while ssh still answers, the truth is "machine up, Backup app not
    // running". Maintained by the existing 1 s clockTick — no new timers.
    @State private var peerAbsentSince: Date? = nil
    var onSettingsTapped: () -> Void = {}

    var body: some View {
        if viewState == .dryRunResult {
            dryRunResultView
                .frame(width: popoverWidth)
                .background(darkBg)
                .preferredColorScheme(.dark)
                .ignoresSafeArea()
        } else if viewState == .confirmCancel {
            InlineConfirm(
                title: "Cancel sync in progress?",
                message: "The sync will be stopped immediately.",
                confirmLabel: "Cancel Sync",
                confirmColor: .red,
                onCancel: { viewState = .normal },
                onConfirm: {
                    viewState = .normal
                    engine.cancel()
                }
            )
            .frame(width: popoverWidth)
            .background(darkBg)
            .preferredColorScheme(.dark)
            .ignoresSafeArea()
        } else if viewState == .confirmQuit {
            InlineConfirm(
                title: "Quit ShowSync?",
                message: isSyncing
                    ? "A backup is in progress and will be interrupted."
                    : "Any sync in progress will stop.",
                confirmLabel: "Quit",
                confirmColor: .red,
                onCancel: {
                    store.pendingQuitConfirm = false
                    viewState = .normal
                },
                onConfirm: {
                    store.pendingQuitConfirm = false
                    if isSyncing { engine.cancel() }  // Clean up signal files before quit
                    (NSApp.delegate as? AppDelegate)?.quitConfirmed = true
                    NSApp.terminate(nil)
                }
            )
            .frame(width: popoverWidth)
            .background(darkBg)
            .preferredColorScheme(.dark)
            .ignoresSafeArea()
        } else if viewState == .history {
            HistoryView(onBack: { viewState = .normal })
                .environmentObject(store)
                .frame(width: popoverWidth)
                .background(darkBg)
                .preferredColorScheme(.dark)
                .ignoresSafeArea()
        } else {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Circle()
                    .fill(engine.status.color)
                    .frame(width: 8, height: 8)
                Text("ShowSync")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                HStack(spacing: 4) {
                    Text(engine.status.label)
                        .font(.system(size: 12))
                        .foregroundColor(engine.status.color)
                    if store.config.autoSyncEnabled && engine.status == .ready {
                        Text("· Auto")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.45))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            // Connection info disclosure row
            Button {
                store.config.mainShowConnectionInfo.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: store.config.mainShowConnectionInfo ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(white: 0.4))
                        .frame(width: 12)
                    Text("Connection Info")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.45))
                    Spacer()
                    if let rs = connectionStatus.state {
                        Circle()
                            .fill(reachDotColor(rs))
                            .frame(width: 6, height: 6)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(connectionInfoHovering ? 0.06 : 0))
            .onHover { connectionInfoHovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: connectionInfoHovering)

            if store.config.mainShowConnectionInfo {
                Divider()

                VStack(spacing: 12) {
                    if store.config.discoveryMode == "automatic" {
                        VStack(spacing: 3) {
                            Text("Backup Network Discovery")
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.45))
                            Text(store.config.lastBackupDiscoveryName.isEmpty ? "Not set" : store.config.lastBackupDiscoveryName)
                                .font(.system(size: 15, weight: .medium, design: .monospaced))
                                .foregroundColor(store.config.lastBackupDiscoveryName.isEmpty ? Color(white: 0.38) : .white)
                                .multilineTextAlignment(.center)
                        }
                    }

                    VStack(spacing: 3) {
                        Text("Backup User")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.45))
                        Text(store.config.username.isEmpty ? "Not set" : store.config.username)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundColor(store.config.username.isEmpty ? Color(white: 0.38) : .white)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 3) {
                        Text("Backup IP")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.45))
                        Text(backupIPDisplay)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundColor(store.config.destinationIP.isEmpty ? Color(white: 0.38) : .white)
                            .multilineTextAlignment(.center)
                    }

                    if let rs = connectionStatus.state {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(reachDotColor(rs))
                                .frame(width: 6, height: 6)
                            Text(reachLabel(rs))
                                .font(.system(size: 11))
                                .foregroundColor(reachDotColor(rs))
                        }
                        // Long-form truth for the amber state: not an error —
                        // the transport works; only app-layer protection is off.
                        if rs == .reachable && backupAppGone {
                            Text("Files still sync, but low-space protection is off.")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(spacing: 3) {
                        Text("Backup Folder")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.45))
                        if engine.usingFallback {
                            VStack(spacing: 1) {
                                Text(store.config.backupDestination.isEmpty ? "~/Sync" : store.config.backupDestination)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("(drive unavailable)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                            }
                        } else {
                            Text(store.config.backupDestination.isEmpty ? "~/Sync" : store.config.backupDestination)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let connectedBackup = bonjourBrowser.services.first(where: { $0.resolvedIP == store.config.destinationIP }),
                           connectedBackup.freeSpaceBytes > 0 {
                            let isLow = connectedBackup.freeSpaceBytes < Int64(store.config.minFreeSpaceGB) * 1024 * 1024 * 1024
                            Text("\(formatBytes(connectedBackup.freeSpaceBytes)) free")
                                .font(.system(size: 10))
                                .foregroundColor(isLow ? .orange : Color(white: 0.45))
                        } else if store.config.discoveryMode == "automatic", !store.config.destinationIP.isEmpty {
                            // Free space is TXT-only (live) — when the Backup's
                            // advertisement is gone (quit/offline) the value is
                            // UNKNOWN, not zero: show "?" per the honesty invariant
                            // instead of silently dropping the row. Automatic mode
                            // only — manual mode never had this row (its free space
                            // lives in Settings via the ssh poll).
                            Text("? free")
                                .font(.system(size: 10))
                                .foregroundColor(Color(white: 0.45))
                        }
                    }

                    VStack(spacing: 3) {
                        Text("This Mac's IP")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.45))
                        Text(effectiveDisplayIP == "—" ? "Not set" : effectiveDisplayIP)
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .foregroundColor(effectiveDisplayIP == "—" ? Color(white: 0.38) : .white)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }

            Divider()

            // Info rows
            VStack(alignment: .leading, spacing: 10) {
                infoRow(
                    label: "Last sync",
                    value: lastSyncDisplay
                )
                if let summary = sourceFolderSummary {
                    infoRow(label: "Source", value: summary)
                }
                if store.config.autoSyncEnabled, !engine.status.isActive,
                   let countdown = nextAutoSyncCountdown {
                    infoRow(label: "Next auto sync", value: countdown)
                }
                if store.config.pushSyncEnabled, !engine.status.isActive,
                   let countdown = nextPushSyncCountdown {
                    infoRow(label: "Next push sync", value: countdown)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if engine.status == .syncing, let sp = engine.syncProgress {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    if sp.expected > 0 {
                        ProgressView(value: min(Double(sp.transferred) / Double(sp.expected), 1.0))
                            .progressViewStyle(.linear)
                            .tint(.yellow)
                        HStack {
                            Text("Syncing… \(Int(min(Double(sp.transferred) / Double(sp.expected), 1.0) * 100))% · \(formatBytes(sp.transferred)) of \(formatBytes(sp.expected))")
                            Spacer()
                            Text(syncEtaText)
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.yellow)
                    } else {
                        // Delta unknown (estimate pending or failed) — honest indeterminate bar
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(.yellow)
                        HStack {
                            Text("Syncing… \(formatBytes(sp.transferred)) moved")
                            Spacer()
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.yellow)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            } else if let (text, color) = activeProgressText {
                Divider()
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }

            // Sync-refused notice (was a silent return inside sync())
            if let notice = engine.syncBlockedNotice {
                Divider()
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }

            // Fallback notice (destination unwritable, fell back to ~/Sync)
            if let notice = engine.fallbackNotice {
                Divider()
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundColor(.yellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }

            // Low space notice (Backup refused due to <2GB free)
            if let notice = engine.lowSpaceNotice {
                Divider()
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }

            Divider()

            // Actions
            VStack(alignment: .leading, spacing: 8) {
                if engine.status.isActive {
                    Button { viewState = .confirmCancel } label: {
                        Text("Cancel Sync")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else if engine.verifyStatus == .verifying {
                    // Verifying in progress - show cancel button
                    Text(engine.verifyStatus.label)
                        .font(.system(size: 12))
                        .foregroundColor(engine.verifyStatus.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { engine.cancelVerify() } label: {
                        Text("Cancel Verify")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                } else {
                    // Normal state - show Sync and Verify buttons
                    HStack(spacing: 8) {
                        Button {
                            engine.sync(config: store.config)
                        } label: {
                            Text(store.config.dryRunEnabled ? "Check Files" : "Sync Now")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.config.isReadyToSync || syncButtonDisabled || !peerReachableForSync)

                        Button {
                            engine.verifyNow(config: store.config)
                        } label: {
                            Text("Verify")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .disabled(!store.config.isReadyToSync)
                        .help("Checksum every file to confirm Backup matches")
                    }

                    // Why Sync Now is disabled — inline, not hover-only
                    if !syncButtonDisabled, let reason = syncDisabledReason {
                        Text(reason)
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.5))
                    }

                    // Show verify result if any (not idle)
                    if engine.verifyStatus != .idle {
                        Text(engine.verifyStatus.label)
                            .font(.system(size: 12))
                            .foregroundColor(engine.verifyStatus.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

                Button { viewState = .history } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14))
                        .foregroundColor(Color(white: 0.6))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("History")

                Spacer()

                Button("Quit") { viewState = .confirmQuit }
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
            Task { @MainActor in
                ConfigStore.shared.iconState = store.config.isReadyToSync ? .idle : .notConfigured
                clockTick = Date()
                if clockTimer == nil {
                    clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                        clockTick = Date()
                    }
                }
            }
            connectionStatus.start("main")
            NetworkInterfaceManager.shared.refreshAvailability()  // fresh IP label
            if sourceFolderSummary == nil { refreshSourceSummary() }
            if store.config.autoSyncEnabled { engine.startAutoSync() }
            startPushSyncIfNeeded()
        }
        .onDisappear {
            connectionStatus.stop("main")
            // Push Sync timer and watcher must survive view lifecycle — do not stop here
            clockTimer?.invalidate()
            clockTimer = nil
        }
        .onChange(of: connectionStatus.state) { newState in
            if newState == .reachable, ConfigStore.shared.iconState == .error {
                Task { @MainActor in
                    ConfigStore.shared.iconState = store.config.isReadyToSync ? .idle : .notConfigured
                }
            }
        }
        .onChange(of: engine.dryRunResult) { newVal in
            if newVal != nil {
                Task { @MainActor in
                    viewState = .dryRunResult
                }
            }
        }
        .onChange(of: engine.syncProgress) { sp in
            // ETA smoothing: update only while moving with a known total; freeze on
            // stall (rate ≈ 0) rather than inflate; clear when the sync ends.
            guard let sp, engine.status == .syncing, sp.expected > 0 else {
                syncEtaText = ""
                return
            }
            if let rate = sp.bytesPerSec {
                if rate > 1024 {
                    let remaining = Double(sp.expected - sp.transferred) / rate
                    syncEtaText = formatETA(remaining)
                }
                // else: stalled — keep the last ETA text
            } else if syncEtaText.isEmpty {
                syncEtaText = "calculating…"
            }
        }
        .onChange(of: engine.status) { newStatus in
            if !newStatus.isActive, viewState == .confirmCancel {
                Task { @MainActor in
                    viewState = .normal
                }
            }
            if newStatus == .done {
                refreshSourceSummary()  // source may have grown during the sync
            }
        }
        .onChange(of: clockTick) { _ in
            // Badge absence tracking (popover-scoped: the tick only runs while
            // open). Sets the date on the first tick the targeted peer's Bonjour
            // entry is missing; clears it the moment it's back — the 5 s grace
            // comparison lives in backupAppGone.
            let absent = store.config.discoveryMode == "automatic"
                && !store.config.destinationIP.isEmpty
                && !bonjourBrowser.services.contains { $0.resolvedIP == store.config.destinationIP }
            if absent {
                if peerAbsentSince == nil { peerAbsentSince = Date() }
            } else if peerAbsentSince != nil {
                peerAbsentSince = nil
            }
        }
        .onChange(of: store.config.pushSyncEnabled) { enabled in
            if enabled {
                startPushSyncIfNeeded()
            } else {
                engine.stopPushSyncDebounce()
                stopPushSync()
            }
        }
        .onChange(of: store.config.pushSyncDebounce) { newDebounce in
            if store.config.pushSyncEnabled {
                engine.stopPushSyncDebounce()  // Stop current debounce
                startPushSyncIfNeeded() // Restart with new debounce setting
            }
        }
        .onChange(of: store.config.sourceFolder) { newFolder in
            if store.config.pushSyncEnabled {
                engine.stopPushSyncDebounce()  // Stop current debounce
                startPushSyncIfNeeded() // Restart with new source folder
            }
        }
        .onChange(of: store.pendingQuitConfirm) { newValue in
            if newValue {
                Task { @MainActor in
                    viewState = .confirmQuit
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { _ in
            Task { @MainActor in
                clockTick = Date()
                if clockTimer == nil {
                    clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                        clockTick = Date()
                    }
                }
            }
            connectionStatus.start("main")
            NetworkInterfaceManager.shared.refreshAvailability()  // fresh IP label
            refreshSourceSummary()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in
            Task { @MainActor in
                clockTimer?.invalidate()
                clockTimer = nil
            }
            connectionStatus.stop("main")
        }
        } // end else
    }

    // MARK: - Dry run result view

    @ViewBuilder private var dryRunResultView: some View {
        VStack(spacing: 0) {
            HStack {
                Text(engine.dryRunResult?.title ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                Text(engine.dryRunResult?.body ?? "")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }

            Divider()

            Button {
                engine.dryRunResult = nil
                viewState = .normal
            } label: {
                Text("OK")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Helpers

    private var isSyncing: Bool { engine.status.isActive }

    private var backupIPDisplay: String {
        if store.config.destinationIP.isEmpty { return "Not set" }
        return store.config.discoveryMode == "automatic"
            ? "\(store.config.destinationIP) (auto)"
            : store.config.destinationIP
    }

    private var nextAutoSyncCountdown: String? {
        guard let next = engine.nextAutoSyncDate else { return nil }
        let secs = max(0, next.timeIntervalSince(clockTick))
        if secs < 60 { return "in 0:\(String(format: "%02d", Int(secs)))" }
        return "in \(Int(secs / 60)) min"
    }

    private var nextPushSyncCountdown: String? {
        guard let next = engine.nextPushSyncDate else { return nil }
        let secs = max(0, next.timeIntervalSince(clockTick))
        return "in 0:\(String(format: "%02d", Int(secs)))"
    }

    // Reconciled automatic-mode reachability: browser heuristic OR a live
    // bound-interface ssh probe — the probe binds -b to the chosen NIC, so a
    // green ConnectionStatus is *stronger* proof of on-interface reachability.
    private var peerReachableForSync: Bool {
        guard store.config.discoveryMode == "automatic" else { return true }
        return bonjourBrowser.isCurrentPeerReachable || connectionStatus.state == .reachable
    }

    // First failing readiness gate, in user-fixable order. nil = ready.
    private var syncDisabledReason: String? {
        if store.config.sourceFolder.isEmpty { return "Choose a source folder" }
        if store.config.destinationIP.isEmpty { return "No Backup selected" }
        if store.config.username.isEmpty { return "No Backup user set" }
        if !store.config.sshKeysConfigured { return "Connection not yet set up" }
        if !peerReachableForSync { return "Backup not reachable on selected network" }
        return nil
    }

    // Sync Now button disabled when a sync is running OR in the brief post-sync cool-down.
    private var syncButtonDisabled: Bool {
        switch engine.status {
        case .ready, .cancelled, .error: return false
        default: return true
        }
    }

    private var activeProgressText: (String, Color)? {
        switch engine.status {
        case .preparing:
            return ("Preparing...", .yellow)
        case .syncing:
            if let pct = syncPercent {
                return ("Syncing... \(pct)%", .yellow)
            }
            return ("Syncing...", .yellow)
        case .done:
            return ("✓ Synced", .green)
        case .error(let msg):
            return ("✗ Sync Failed — \(msg)", .red)
        default:
            return nil
        }
    }

    private var syncPercent: Int? {
        guard let sp = engine.syncProgress, sp.expected > 0, sp.transferred > 0 else { return nil }
        return Int(min(Double(sp.transferred) / Double(sp.expected), 1.0) * 100)
    }

    // Display the IP of the interface the engine actually binds with — same truth
    // as getEffectiveIP (e.g. 169.254.x when the cable is selected), not the
    // system's satisfied-path IP (which is Wi-Fi when the cable has no internet).
    private var effectiveDisplayIP: String {
        interfaceManager.getEffectiveIP() ?? "—"
    }

    // "<time> · 11 files · 41.3 MB" from the newest successful transfer_log entry.
    // The log is persisted, so this survives relaunch (engine.lastSyncTime doesn't).
    private var lastSyncDisplay: String {
        let lastSuccess = store.transferLog.first(where: { $0.result == "success" })
        let time: String? = engine.lastSyncTime.map { formatTime($0) }
            ?? lastSuccess.map { formatTime($0.date) }
        guard let time else { return "Never" }
        guard let entry = lastSuccess else { return time }
        let fileWord = entry.fileCount == 1 ? "file" : "files"
        return "\(time) · \(entry.fileCount) \(fileWord) · \(formatBytes(entry.totalBytes))"
    }

    // Source folder contents — same enumeration the Backup uses for its sync-folder
    // row (skipsHiddenFiles, consistent with the .DS_Store exclusion). Computed only
    // when the popover opens or a sync completes; cached; zero cost while closed.
    private func refreshSourceSummary() {
        let folder = store.config.sourceFolder
        guard !folder.isEmpty else {
            sourceFolderSummary = nil
            return
        }
        let path = folder.hasPrefix("~")
            ? (NSHomeDirectory() as NSString).appendingPathComponent(String(folder.dropFirst()))
            : folder
        let url = URL(fileURLWithPath: path)
        DispatchQueue.global(qos: .utility).async {
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: .skipsHiddenFiles
            ) else {
                Task { @MainActor in sourceFolderSummary = nil }
                return
            }
            var count = 0
            var totalBytes: Int64 = 0
            for case let fileURL as URL in enumerator {
                guard let res = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      res.isRegularFile == true else { continue }
                count += 1
                totalBytes += Int64(res.fileSize ?? 0)
            }
            let fileWord = count == 1 ? "file" : "files"
            let result = count == 0 ? "0 files · empty" : "\(count) \(fileWord) · \(formatBytes(totalBytes))"
            Task { @MainActor in sourceFolderSummary = result }
        }
    }

    // Amber composite for the three-state badge: ssh reachable = the MACHINE
    // answers; Bonjour absence (persisted >5 s, via clockTick re-evaluation) =
    // the Backup APP is not advertising. Automatic mode only — manual mode has
    // no Bonjour to consult, so pure ssh truth stays correct there. Live-checks
    // the services list so a returned peer clears the state instantly even if
    // the tick hasn't cleared the date yet.
    private var backupAppGone: Bool {
        guard store.config.discoveryMode == "automatic",
              !store.config.destinationIP.isEmpty,
              !bonjourBrowser.services.contains(where: { $0.resolvedIP == store.config.destinationIP }),
              let since = peerAbsentSince else { return false }
        return clockTick.timeIntervalSince(since) > 5
    }

    private func reachDotColor(_ state: ConnectionState) -> Color {
        // Machine reachable but app gone → amber, not green: "Connected" in
        // app-layer words was overstating a machine-layer truth.
        if state == .reachable && backupAppGone { return .orange }
        switch state {
        case .checking:    return Color(white: 0.55)
        case .reachable:   return .green
        case .unreachable: return .red
        }
    }

    private func reachLabel(_ state: ConnectionState) -> String {
        if state == .reachable && backupAppGone { return "Backup app not running" }
        switch state {
        case .checking:    return "Checking..."
        case .reachable:   return "Connected"
        case .unreachable: return "Not Connected"
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
        }
    }

    // MARK: - Push Sync

    // Start Push Sync file watcher if enabled and configured
    private func startPushSyncIfNeeded() {
        guard store.config.pushSyncEnabled,
              !store.config.sourceFolder.isEmpty else {
            stopPushSync()
            return
        }

        fsEventsWatcher.start(path: store.config.sourceFolder, debounceSeconds: store.config.pushSyncDebounce)
    }

    // Stop Push Sync file watcher
    private func stopPushSync() {
        fsEventsWatcher.stop()
    }

}

// MARK: - Inline confirmation

struct InlineConfirm: View {
    let title: String
    let message: String
    let confirmLabel: String
    let confirmColor: Color
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.55))
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button(confirmLabel, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(confirmColor)
                    .frame(maxWidth: .infinity)
            }
            .font(.system(size: 12))
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - History view

struct HistoryView: View {
    @EnvironmentObject var store: ConfigStore
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 13))
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("History")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                // Invisible spacer to balance the Back button
                Text("Back")
                    .font(.system(size: 13))
                    .opacity(0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if store.transferLog.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 32))
                        .foregroundColor(Color(white: 0.4))
                    Text("No sync history yet")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.transferLog) { entry in
                            HistoryRow(entry: entry)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

struct HistoryRow: View {
    let entry: TransferLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Result icon
            Image(systemName: resultIcon)
                .font(.system(size: 14))
                .foregroundColor(resultColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                // Time + trigger
                HStack(spacing: 6) {
                    Text(formattedTime)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                    Text(triggerLabel)
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.5))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color(white: 0.2))
                        .cornerRadius(3)
                }

                // File count + bytes
                HStack(spacing: 4) {
                    Text(filesDisplay)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(white: 0.7))
                    if entry.durationSeconds > 0 {
                        Text("·")
                            .foregroundColor(Color(white: 0.4))
                        Text(durationDisplay)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(white: 0.5))
                    }
                }

                // Destination
                HStack(spacing: 4) {
                    Text(truncatedDestination)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(white: 0.45))
                        .lineLimit(1)
                    if entry.usedFallback {
                        Text("(fallback)")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var resultIcon: String {
        switch entry.result {
        case "success":   return "checkmark.circle.fill"
        case "fallback":  return "exclamationmark.triangle.fill"
        case "failed":    return "xmark.circle.fill"
        case "refused":   return "nosign"
        case "cancelled": return "stop.circle.fill"
        default:          return "questionmark.circle"
        }
    }

    private var resultColor: Color {
        switch entry.result {
        case "success":   return .green
        case "fallback":  return .orange
        case "failed":    return .red
        case "refused":   return .red
        case "cancelled": return Color(white: 0.5)
        default:          return .gray
        }
    }

    private var triggerLabel: String {
        switch entry.trigger {
        case "auto":   return "Auto"
        case "push":   return "Push"
        case "manual": return "Manual"
        default:       return entry.trigger.capitalized
        }
    }

    private var formattedTime: String {
        let cal = Calendar.current
        let fmt = DateFormatter()
        if cal.isDateInToday(entry.date) {
            fmt.dateStyle = .none
            fmt.timeStyle = .short
        } else {
            fmt.dateStyle = .short
            fmt.timeStyle = .short
        }
        return fmt.string(from: entry.date)
    }

    private var filesDisplay: String {
        let files = entry.fileCount == 1 ? "1 file" : "\(entry.fileCount) files"
        let bytes = formatBytes(entry.totalBytes)
        return "\(files) · \(bytes)"
    }

    private var durationDisplay: String {
        if entry.durationSeconds < 60 {
            return "\(entry.durationSeconds)s"
        }
        let mins = entry.durationSeconds / 60
        let secs = entry.durationSeconds % 60
        return "\(mins)m \(secs)s"
    }

    private var truncatedDestination: String {
        let dest = entry.destination
        if dest.count <= 25 { return dest }
        return String(dest.prefix(10)) + "..." + String(dest.suffix(10))
    }
}
