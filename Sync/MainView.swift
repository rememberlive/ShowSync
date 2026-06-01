import SwiftUI
import AppKit
import CoreServices

private let darkBg = Color(red: 0.12, green: 0.12, blue: 0.12)
private let popoverWidth: CGFloat = 360

// MARK: - Types

struct DryRunResult: Equatable {
    let title: String
    let body: String
}

struct SyncProgress: Equatable {
    let transferred: Int64   // bytes received by Backup (SSH du polling)
    let expected: Int64      // total size from dry run (0 = not yet known)
}

enum MainViewState {
    case normal, dryRunResult, confirmCancel, confirmQuit
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
    case verified
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
        case .verified:         return "Verified — all files match"
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
    @Published var usingFallback: Bool = false    // True when sync redirected to ~/Sync due to unavailable drive
    @Published var manualModeFreeSpace: Int64 = 0 // Free space from manual-mode config poll (bytes)

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
    private var isRemoteVerify: Bool = false  // True when triggered by Backup via Bonjour

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
        guard config.isReadyToSync else { return }
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
        // If usingFallback already set (from manual mode config read), sync to ~/Sync directly
        if usingFallback {
            syncRemotePath = "~/Sync"
        } else {
            syncRemotePath = config.backupDestination.isEmpty ? "~/Sync" : config.backupDestination
        }

        let mode = config.discoveryMode
        NSLog("[SyncTrace] 1 sync requested, mode=%@, remotePath='%@', usingFallback=%d, dryRunEnabled=%d, isAuto=%d",
              mode, syncRemotePath, usingFallback ? 1 : 0, config.dryRunEnabled ? 1 : 0, isAuto ? 1 : 0)

        // Check if this is a "Check Files" preview request
        let isPreviewOnly = config.dryRunEnabled && !isAuto

        if isPreviewOnly {
            // Preview mode: run dry-run to show file list (uses fixed pipe drain)
            runDryRunPreview(config: config)
        } else {
            // Normal sync: SKIP dry-run entirely, go straight to write-test and rsync
            NSLog("[SyncTrace] 2 SKIPPING dry-run (normal sync path)")
            syncTotalFiles = 0
            expectedSize   = 0
            syncStartTime  = Date()
            fallbackNotice = nil
            lowSpaceNotice = nil

            // Write-test then rsync
            let originalRemotePath = syncRemotePath
            NSLog("[SyncTrace] 4 starting write-test, remotePath='%@'", originalRemotePath)
            runSyncTimeWriteTest(username: config.username, ip: config.destinationIP, remotePath: originalRemotePath) { [weak self] result, _ in
                guard let self else {
                    NSLog("[SyncTrace] 5 write-test callback but self is nil")
                    return
                }
                NSLog("[SyncTrace] 5 write-test result=%d (0=writable, 1=unwritable, 2=testFailed)", result == .writable ? 0 : (result == .unwritable ? 1 : 2))
                switch result {
                case .writable:
                    break
                case .unwritable:
                    self.syncRemotePath = "~/Sync"
                    self.usingFallback = true
                    self.fallbackNotice = "Couldn't write to the chosen folder — backing up to the default Sync folder instead."
                    NSLog("[Sync] Destination unwritable, falling back to ~/Sync")
                case .testFailed:
                    NSLog("[Sync] Write-test failed (SSH error), proceeding anyway")
                }
                NSLog("[SyncTrace] 6 calling continueSyncAfterWriteTest")
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
        let dest = "\(syncUsername)@\(syncIP):\(syncRemotePath)/"

        let rsyncCandidates = ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/usr/bin/rsync"]
        let rsyncPath = rsyncCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/rsync"

        NSLog("[SyncTrace] 2 starting dry-run PREVIEW, rsyncPath=%@", rsyncPath)
        let prepProc = Process()
        prepProc.executableURL = URL(fileURLWithPath: rsyncPath)
        var prepArgs = ["-av", "--dry-run", "--stats"]
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !ConfigStore.shared.config.preferredInterface.isEmpty {
            prepArgs.insert(contentsOf: ["-e", "ssh -b \(bindIP)"], at: 0)
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
                NSLog("[SyncTrace] 2f dry-run PREVIEW TIMEOUT (30s)")
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
            NSLog("[SyncTrace] 3 dry-run PREVIEW terminated, exit=%d", p.terminationStatus)
            let output = outputBuffer.getString()

            Task { @MainActor [weak self] in
                guard let self, self.status == .preparing else {
                    NSLog("[SyncTrace] 3b dry-run guard FAILED")
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
                NSLog("[SyncTrace] 3c preview parsed: fileCount=%d totalBytes=%lld", fileCount, totalBytes)

                let (previewFiles, _) = Self.parseDryRunOutput(output)
                if fileCount > 0 && previewFiles.isEmpty {
                    let note = totalBytes > 0 ? "\nTotal size: \(SyncEngine.formatBytes(totalBytes))" : ""
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
            NSLog("[SyncTrace] 2b dry-run PREVIEW dispatch executing")
            do {
                try prepProc.run()
                NSLog("[SyncTrace] 2c dry-run PREVIEW process started")
            } catch {
                timeoutItem.cancel()
                NSLog("[SyncTrace] 2d dry-run PREVIEW launch FAILED: %@", error.localizedDescription)
                Task { @MainActor [weak self] in
                    self?.handleRsyncLaunchFailure()
                }
            }
        }
    }

    private func continueSyncAfterWriteTest(config: Config, totalBytes: Int64, fileCount: Int, dryRunOutput: String) {
        NSLog("[SyncTrace] 7 continueSyncAfterWriteTest entered, setting status=syncing")
        status = .syncing
        writeSyncStart(totalBytes: totalBytes, totalFiles: fileCount)

        // Rebuild dest with potentially updated syncRemotePath
        let rawSource = config.sourceFolder.hasPrefix("~")
            ? (NSHomeDirectory() as NSString).appendingPathComponent(String(config.sourceFolder.dropFirst()))
            : config.sourceFolder
        let source = rawSource.hasSuffix("/") ? rawSource : rawSource + "/"
        let dest = "\(syncUsername)@\(syncIP):\(syncRemotePath)/"

        let rsyncCandidates = ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/usr/bin/rsync"]
        let rsyncPath = rsyncCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/rsync"

        NSLog("[SyncTrace] 8 about to launch rsync, source='%@', dest='%@'", source, dest)

                let launchRsync = { [weak self] in
                    guard let self else { return }
                    NSLog("[SyncTrace] 9 launchRsync closure executing")
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: rsyncPath)
                    var rsyncArgs = ["-av"]
                    if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
                       !ConfigStore.shared.config.preferredInterface.isEmpty {
                        rsyncArgs.insert(contentsOf: ["-e", "ssh -b \(bindIP)"], at: 0)
                    }
                    rsyncArgs.append(contentsOf: [source, dest])
                    proc.arguments = rsyncArgs
                    proc.standardOutput = FileHandle.nullDevice
                    let errPipe = Pipe()
                    proc.standardError  = errPipe

                    proc.terminationHandler = { [weak self] p in
                        NSLog("[SyncTrace] 10 rsync terminated, exit=%d", p.terminationStatus)
                        _ = errPipe.fileHandleForReading.readDataToEndOfFile() // drain pipe
                        if p.terminationStatus != 0 {
                            NSLog("[Sync] exit %d", p.terminationStatus)
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
                                    return
                                }

                                if p.terminationStatus == 0 {
                                    let duration = Int(Date().timeIntervalSince(self.syncStartTime))
                                    self.lastSyncTime = Date()
                                    ConfigStore.shared.config.sshKeysConfigured = true
                                    ConfigStore.shared.iconState = self.usingFallback ? .warning : .success
                                    self.status = .done
                                    self.writeSyncComplete(
                                        totalFiles: self.syncTotalFiles,
                                        totalBytes: self.expectedSize,
                                        duration:   duration)
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

        if config.versionHistoryEnabled && fileCount > 0 {
            let changedFiles = Self.parseChangedFiles(dryRunOutput)
            if !changedFiles.isEmpty {
                runVersioning(
                    files: changedFiles,
                    username: config.username,
                    ip: config.destinationIP,
                    maxVersionCount: config.maxVersionCount,
                    completion: launchRsync
                )
            } else {
                launchRsync()
            }
        } else {
            launchRsync()
        }
    }

    func cancel() {
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

        verifyStatus = .verifying

        let rawSource = config.sourceFolder
        let source = rawSource.hasSuffix("/") ? rawSource : rawSource + "/"
        let remotePath = usingFallback ? "~/Sync" : (config.backupDestination.isEmpty ? "~/Sync" : config.backupDestination)
        let dest = "\(config.username)@\(config.destinationIP):\(remotePath)/"

        let rsyncCandidates = ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/usr/bin/rsync"]
        let rsyncPath = rsyncCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/rsync"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rsyncPath)

        var args = ["-avc", "--dry-run"]
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !config.preferredInterface.isEmpty {
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
                            self.verifyStatus = .verified
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
        verifyTask?.terminate()
        verifyTask = nil
        verifyStatus = .idle
        isRemoteVerify = false
    }

    // Called by BonjourBrowser when Backup requests a verify via TXT record
    func triggerRemoteVerify() {
        guard !isRemoteVerify else { return }  // Already handling a remote verify
        guard !status.isActive else { return }  // Verify yields to sync
        isRemoteVerify = true
        verifyNow(config: ConfigStore.shared.config)
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

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1_024           { return "\(bytes) bytes" }
        if bytes < 1_048_576       { return String(format: "%.1f KB", Double(bytes) / 1_024) }
        if bytes < 1_073_741_824   { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    // MARK: - SSH du polling for byte-accurate progress

    private var expectedSize:      Int64 = 0
    private var duPollTimer:       Timer?
    private var duInFlight:        Bool  = false
    private var baselineSyncBytes: Int64 = 0

    private func startDuPolling(username: String, ip: String) {
        duInFlight = false
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
            let capped = self.expectedSize > 0 ? min(transferred, self.expectedSize) : transferred
            self.syncProgress = SyncProgress(transferred: capped, expected: self.expectedSize)
            if self.expectedSize > 0 {
                let percent = Int(min(Double(capped) / Double(self.expectedSize), 1.0) * 100)
                self.writeSyncProgress(percent: percent)
            }
        }
    }

    private func stopDuPolling() {
        duPollTimer?.invalidate()
        duPollTimer = nil
        duInFlight  = false
    }

    private func runDu(username: String, ip: String, completion: @escaping (Int64) -> Void) {
        guard !duInFlight else { return }
        duInFlight = true
        let escaped = Self.shellEscapeForDoubleQuotes(syncRemotePath)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var duArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "StrictHostKeyChecking=no"]
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !ConfigStore.shared.config.preferredInterface.isEmpty {
            duArgs.insert(contentsOf: ["-b", bindIP], at: 0)
        }
        duArgs.append(contentsOf: ["\(username)@\(ip)", "du -sk \"\(escaped)\" 2>/dev/null | cut -f1"])
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
        let escaped = Self.shellEscapeForDoubleQuotes(syncRemotePath)
        sshWrite("echo '{\"totalBytes\":\(totalBytes),\"totalFiles\":\(totalFiles)}' > \"\(escaped)/.sync_start\"")
    }

    private func writeSyncProgress(percent: Int) {
        let escaped = Self.shellEscapeForDoubleQuotes(syncRemotePath)
        sshWrite("echo '{\"percent\":\(percent)}' > \"\(escaped)/.sync_progress\"")
    }

    private func writeSyncComplete(totalFiles: Int, totalBytes: Int64, duration: Int) {
        let escaped = Self.shellEscapeForDoubleQuotes(syncRemotePath)
        sshWrite("echo '{\"totalFiles\":\(totalFiles),\"totalBytes\":\(totalBytes),\"duration\":\(duration)}' > \"\(escaped)/.sync_complete\"; rm -f \"\(escaped)/.sync_start\" \"\(escaped)/.sync_progress\"")
    }

    private func cleanupSignalFiles() {
        let escaped = Self.shellEscapeForDoubleQuotes(syncRemotePath)
        sshWrite("rm -f \"\(escaped)/.sync_start\" \"\(escaped)/.sync_progress\" \"\(escaped)/.sync_complete\"")
    }

    // Write verify result to Backup (for remote-initiated verify)
    private func writeVerifyResult(_ result: String) {
        let config = ConfigStore.shared.config
        guard !config.username.isEmpty, !config.destinationIP.isEmpty else { return }
        let remotePath = usingFallback ? "~/Sync" : (config.backupDestination.isEmpty ? "~/Sync" : config.backupDestination)
        let escaped = Self.shellEscapeForDoubleQuotes(remotePath)
        let timestamp = Int(Date().timeIntervalSince1970)
        let cmd = "echo '{\"result\":\"\(result)\",\"ts\":\(timestamp)}' > \"\(escaped)/.verify_result\"; rm -f \"\(escaped)/.verify_request\""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var sshArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=2", "-o", "StrictHostKeyChecking=no"]
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !config.preferredInterface.isEmpty {
            sshArgs.insert(contentsOf: ["-b", bindIP], at: 0)
        }
        sshArgs.append(contentsOf: ["\(config.username)@\(config.destinationIP)", cmd])
        proc.arguments = sshArgs
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        DispatchQueue.global(qos: .utility).async { try? proc.run() }
    }

    private func sshWrite(_ command: String) {
        guard !syncUsername.isEmpty, !syncIP.isEmpty else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var sshArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=2", "-o", "StrictHostKeyChecking=no"]
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !ConfigStore.shared.config.preferredInterface.isEmpty {
            sshArgs.insert(contentsOf: ["-b", bindIP], at: 0)
        }
        sshArgs.append(contentsOf: ["\(syncUsername)@\(syncIP)", command])
        proc.arguments = sshArgs
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        DispatchQueue.global(qos: .utility).async { try? proc.run() }
    }

    // MARK: - Shell path escaping (double-quoted, allows ~ expansion)

    private static func shellEscapeForDoubleQuotes(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
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
        let escaped = Self.shellEscapeForDoubleQuotes(remotePath)
        let testFile = "\(escaped)/.sync_writetest_\(Int.random(in: 1000...9999))"
        let cmd = "touch \"\(testFile)\" && rm -f \"\(testFile)\" && echo OK || echo FAIL"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var testArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=2", "-o", "ServerAliveInterval=2",
                        "-o", "ServerAliveCountMax=2", "-o", "StrictHostKeyChecking=no"]
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !ConfigStore.shared.config.preferredInterface.isEmpty {
            testArgs.insert(contentsOf: ["-b", bindIP], at: 0)
        }
        testArgs.append(contentsOf: ["\(username)@\(ip)", cmd])
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
        let escaped = Self.shellEscapeForDoubleQuotes(remotePath)
        let refusedPath = "\(escaped)/.sync_refused"
        let cmd = "test -f \"\(refusedPath)\" && echo YES || echo NO"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var refuseArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=2", "-o", "StrictHostKeyChecking=no"]
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !ConfigStore.shared.config.preferredInterface.isEmpty {
            refuseArgs.insert(contentsOf: ["-b", bindIP], at: 0)
        }
        refuseArgs.append(contentsOf: ["\(username)@\(ip)", cmd])
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
        let escaped = Self.shellEscapeForDoubleQuotes(syncRemotePath)
        sshWrite("rm -f \"\(escaped)/.sync_refused\"")
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

    // MARK: - Version history

    private func runVersioning(
        files: [String],
        username: String,
        ip: String,
        maxVersionCount: Int,
        completion: @escaping () -> Void
    ) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm"
        let timestamp = fmt.string(from: Date())
        let group = DispatchGroup()
        for relativePath in files {
            let cmd = Self.versioningCommand(
                relativePath: relativePath,
                timestamp: timestamp,
                maxVersionCount: maxVersionCount,
                remotePath: syncRemotePath
            )
            group.enter()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var versionArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "StrictHostKeyChecking=no"]
            if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
               !ConfigStore.shared.config.preferredInterface.isEmpty {
                versionArgs.insert(contentsOf: ["-b", bindIP], at: 0)
            }
            versionArgs.append(contentsOf: ["\(username)@\(ip)", cmd])
            proc.arguments = versionArgs
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError  = FileHandle.nullDevice
            proc.terminationHandler = { p in
                NSLog("[Version] exit=%d", p.terminationStatus)
                group.leave()
            }
            DispatchQueue.global(qos: .utility).async {
                do { try proc.run() } catch {
                    NSLog("[Version] launch failed: %@", error.localizedDescription)
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { completion() }
    }

    // Wrap s in single quotes and escape any embedded single quotes using the '\'' idiom.
    // Safe for all POSIX shell metacharacters. Never used on glob wildcards — those stay unquoted.
    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func versioningCommand(
        relativePath: String,
        timestamp: String,
        maxVersionCount: Int,
        remotePath: String
    ) -> String {
        let filename: String
        let dirPart: String
        if let slashIdx = relativePath.lastIndex(of: "/") {
            filename = String(relativePath[relativePath.index(after: slashIdx)...])
            dirPart  = String(relativePath[..<slashIdx])
        } else {
            filename = relativePath
            dirPart  = ""
        }
        let ext  = URL(fileURLWithPath: filename).pathExtension
        let base = ext.isEmpty ? filename : String(filename.dropLast(ext.count + 1))

        // Remote path prefix is kept unquoted so tilde expands; only the variable parts are quoted.
        // Adjacent quoted/unquoted segments concatenate in shell, so glob wildcards still expand.
        let fullPath = "\(remotePath)/\(shellEscape(relativePath))"
        let syncDir  = dirPart.isEmpty ? remotePath : "\(remotePath)/\(shellEscape(dirPart))"

        let versionedName: String
        let glob: String
        if ext.isEmpty {
            versionedName = "\(shellEscape(base))_\(timestamp)"
            glob          = "\(shellEscape(base))_????-??-??_??-??"
        } else {
            versionedName = "\(shellEscape(base))_\(timestamp).\(shellEscape(ext))"
            glob          = "\(shellEscape(base))_????-??-??_??-??.\(shellEscape(ext))"
        }

        var cmd = "if [ -f \(fullPath) ]; then mv \(fullPath) \(syncDir)/\(versionedName)"
        if maxVersionCount > 0 {
            cmd += "; extra=$(ls \(syncDir)/\(glob) 2>/dev/null | sort | wc -l | tr -d ' ')"
            cmd += "; if [ \"$extra\" -gt \(maxVersionCount) ]; then"
            cmd += " ls \(syncDir)/\(glob) 2>/dev/null | sort"
            cmd += " | head -n $(($extra - \(maxVersionCount))) | tr '\\n' '\\0' | xargs -0 rm -f; fi"
        }
        cmd += "; fi"
        return cmd
    }

    private static func parseChangedFiles(_ output: String) -> [String] {
        let lines = output.components(separatedBy: .newlines)
        // GNU rsync (Homebrew): files listed after "sending incremental file list"
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "sending incremental file list" }) {
            var collecting = false
            var files: [String] = []
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t == "sending incremental file list" { collecting = true; continue }
                if collecting {
                    guard !t.isEmpty else { break }
                    if !t.hasSuffix("/") && t != "./" { files.append(t) }
                }
            }
            return files
        }
        // openrsync (Apple /usr/bin/rsync): files listed after "Transfer starting:"
        var collecting = false
        var files: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Transfer starting:") { collecting = true; continue }
            if collecting && t.isEmpty { break }
            if collecting && !t.isEmpty && t != "./" && !t.hasSuffix("/")
                && !t.contains(": ") && !t.hasSuffix(" B") {
                files.append(t)
            }
        }
        return files
    }

}

// MARK: - SSH reachability

enum ReachabilityState {
    case checking, reachable, unreachable
}

// Checks SSH connectivity using the same username + IP that rsync uses.
// Fires immediately on startChecking(), then repeats every 3 s while the
// dropdown is open. Stops completely — zero CPU — when the dropdown closes.
final class SSHChecker: ObservableObject {
    @Published var state: ReachabilityState? = nil

    private var process: Process?
    private var checkID = 0
    private var timer:   Timer?
    private var lastHandledVerifyNonce: String = ""  // Dedupe for manual mode verify requests

    func startChecking(username: String, ip: String) {
        guard !username.isEmpty, !ip.isEmpty else { stopChecking(); return }
        stopChecking()
        check(username: username, ip: ip)
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.check(username: username, ip: ip)
        }
    }

    func stopChecking() {
        timer?.invalidate()
        timer = nil
        cancelInFlight()
        // Defer state change off layout pass to avoid recursion
        DispatchQueue.main.async { [weak self] in
            self?.state = nil
        }
    }

    private func check(username: String, ip: String) {
        cancelInFlight()
        DispatchQueue.main.async { [weak self] in
            self?.state = .checking
        }
        let currentID = checkID
        let isManualMode = ConfigStore.shared.config.discoveryMode == "manual"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        if isManualMode {
            // Manual mode: read config + free space + check for verify request in one call
            let cmd = "cat \"$HOME/Library/Application Support/Sync/config_backup.json\" 2>/dev/null || echo '{}'; echo '---DF---'; df -k ~ 2>/dev/null | awk 'NR==2 {print $4}'; echo '---VERIFY---'; cat ~/Sync/.verify_request 2>/dev/null || echo ''"
            var manualArgs = ["-o", "ConnectTimeout=2", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no"]
            if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
               !ConfigStore.shared.config.preferredInterface.isEmpty {
                manualArgs.insert(contentsOf: ["-b", bindIP], at: 0)
            }
            manualArgs.append(contentsOf: ["\(username)@\(ip)", cmd])
            proc.arguments = manualArgs
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            proc.terminationHandler = { [weak self] p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                Task { @MainActor [weak self] in
                    guard let self, self.checkID == currentID else { return }
                    self.process = nil

                    if p.terminationStatus != 0 {
                        // SSH failed — unreachable, but keep last-known config values
                        self.state = .unreachable
                        return
                    }

                    self.state = .reachable

                    // Parse output: JSON config, then ---DF---, then free space KB
                    let output = String(data: data, encoding: .utf8) ?? ""
                    let parts = output.components(separatedBy: "---DF---")

                    // Parse config JSON (only update if parse succeeds)
                    if let jsonPart = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                       let jsonData = jsonPart.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let dest = json["destinationFolder"] as? String, !dest.isEmpty {
                        let effectivePath = (json["effectivePath"] as? String) ?? dest
                        let isFallback = !effectivePath.isEmpty && effectivePath != dest
                        ConfigStore.shared.config.backupDestination = dest
                        SyncEngine.shared.usingFallback = isFallback
                    }
                    // On parse failure: keep last-known values (no else branch needed)
                    // Parse free space (only update if parse succeeds)
                    if parts.count > 1 {
                        let dfAndVerify = parts[1].components(separatedBy: "---VERIFY---")
                        if let kbStr = dfAndVerify[0].trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first,
                           let kb = Int64(kbStr) {
                            SyncEngine.shared.manualModeFreeSpace = kb * 1024
                        }
                        // Parse verify request (manual mode only)
                        if dfAndVerify.count > 1 {
                            let verifyContent = dfAndVerify[1].trimmingCharacters(in: .whitespacesAndNewlines)
                            if !verifyContent.isEmpty,
                               let verifyData = verifyContent.data(using: .utf8),
                               let verifyJson = try? JSONSerialization.jsonObject(with: verifyData) as? [String: Any],
                               let nonce = verifyJson["nonce"] as? String, !nonce.isEmpty,
                               nonce != self.lastHandledVerifyNonce {
                                // Found a new verify request - trigger remote verify
                                self.lastHandledVerifyNonce = nonce
                                NSLog("[SSHChecker] Manual mode verify request: nonce=%@", nonce)
                                SyncEngine.shared.triggerRemoteVerify()
                            }
                        }
                    }
                }
            }
            process = proc
            DispatchQueue.global(qos: .utility).async { try? proc.run() }
        } else {
            // Auto mode: simple exit test (TXT push handles config updates)
            var autoArgs = ["-o", "ConnectTimeout=2", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no"]
            if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
               !ConfigStore.shared.config.preferredInterface.isEmpty {
                autoArgs.insert(contentsOf: ["-b", bindIP], at: 0)
            }
            autoArgs.append(contentsOf: ["\(username)@\(ip)", "exit"])
            proc.arguments = autoArgs
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            proc.terminationHandler = { [weak self] p in
                Task { @MainActor [weak self] in
                    guard let self, self.checkID == currentID else { return }
                    self.state = p.terminationStatus == 0 ? .reachable : .unreachable
                    self.process = nil
                }
            }
            process = proc
            DispatchQueue.global(qos: .utility).async { try? proc.run() }
        }
    }

    private func cancelInFlight() {
        checkID += 1
        if let proc = process, proc.isRunning { proc.terminate() }
        process = nil
    }

    deinit { stopChecking() }
}

// MARK: - Main view

struct MainView: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var engine = SyncEngine.shared
    @StateObject private var sshChecker = SSHChecker()
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var fsEventsWatcher = FSEventsWatcher.shared
    @State private var viewState: MainViewState = .normal
    @State private var clockTick  = Date()
    @State private var clockTimer: Timer? = nil
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
                title: "Quit Sync?",
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
        } else {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Circle()
                    .fill(engine.status.color)
                    .frame(width: 8, height: 8)
                Text("Sync")
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
                    Text("Connection info")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.45))
                    Spacer()
                    if let rs = sshChecker.state {
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

            if store.config.mainShowConnectionInfo {
                Divider()

                VStack(spacing: 12) {
                    if store.config.discoveryMode == "automatic" {
                        VStack(spacing: 3) {
                            Text("BACKUP Network Discovery")
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.45))
                            Text(store.config.lastBackupDiscoveryName.isEmpty ? "Not set" : store.config.lastBackupDiscoveryName)
                                .font(.system(size: 15, weight: .medium, design: .monospaced))
                                .foregroundColor(store.config.lastBackupDiscoveryName.isEmpty ? Color(white: 0.38) : .white)
                                .multilineTextAlignment(.center)
                        }
                    }

                    VStack(spacing: 3) {
                        Text("BACKUP User")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.45))
                        Text(store.config.username.isEmpty ? "Not set" : store.config.username)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundColor(store.config.username.isEmpty ? Color(white: 0.38) : .white)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 3) {
                        Text("BACKUP IP")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.45))
                        Text(backupIPDisplay)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .foregroundColor(store.config.destinationIP.isEmpty ? Color(white: 0.38) : .white)
                            .multilineTextAlignment(.center)
                    }

                    if let rs = sshChecker.state {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(reachDotColor(rs))
                                .frame(width: 6, height: 6)
                            Text(reachLabel(rs))
                                .font(.system(size: 11))
                                .foregroundColor(reachDotColor(rs))
                        }
                    }

                    VStack(spacing: 3) {
                        Text("BACKUP Folder")
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
                    }

                    VStack(spacing: 3) {
                        Text("This Mac's IP")
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.45))
                        Text(networkMonitor.currentIP == "—" ? "Not set" : networkMonitor.currentIP)
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .foregroundColor(networkMonitor.currentIP == "—" ? Color(white: 0.38) : .white)
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
                    value: engine.lastSyncTime.map { formatTime($0) } ?? "Never"
                )
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

            if let (text, color) = activeProgressText {
                Divider()
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }

            // Fallback notice (destination unwritable, fell back to ~/Sync)
            if let notice = engine.fallbackNotice {
                Divider()
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundColor(.yellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                        .disabled(!store.config.isReadyToSync || syncButtonDisabled)
                        .help(store.config.isReadyToSync ? "" : "Set source folder and BACKUP IP in Settings first")

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

                    // Show verify result if any (not idle)
                    if engine.verifyStatus != .idle {
                        Text(engine.verifyStatus.label)
                            .font(.system(size: 12))
                            .foregroundColor(engine.verifyStatus.color)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

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
            NSLog("[DEBUG] Source folder path at app launch: %@", store.config.sourceFolder)
            sshChecker.startChecking(username: store.config.username, ip: store.config.destinationIP)
            if store.config.autoSyncEnabled { engine.startAutoSync() }
            startPushSyncIfNeeded()
        }
        .onDisappear {
            sshChecker.stopChecking()
            // Push Sync timer and watcher must survive view lifecycle — do not stop here
            clockTimer?.invalidate()
            clockTimer = nil
        }
        .onChange(of: sshChecker.state) { newState in
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
        .onChange(of: engine.status) { newStatus in
            if !newStatus.isActive, viewState == .confirmCancel {
                Task { @MainActor in
                    viewState = .normal
                }
            }
        }
        .onChange(of: store.config.autoSyncEnabled) { enabled in
            if enabled { engine.startAutoSync() } else { engine.stopAutoSync() }
        }
        .onChange(of: store.config.autoSyncInterval) { newInterval in
            if store.config.autoSyncEnabled {
                let delay: TimeInterval = newInterval == 0 ? 30 : TimeInterval(newInterval * 60)
                engine.startAutoSync(delay: delay)
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
            sshChecker.startChecking(username: store.config.username, ip: store.config.destinationIP)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in
            Task { @MainActor in
                clockTimer?.invalidate()
                clockTimer = nil
            }
            sshChecker.stopChecking()
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

    private func reachDotColor(_ state: ReachabilityState) -> Color {
        switch state {
        case .checking:    return Color(white: 0.55)
        case .reachable:   return .green
        case .unreachable: return .red
        }
    }

    private func reachLabel(_ state: ReachabilityState) -> String {
        switch state {
        case .checking:    return "Checking..."
        case .reachable:   return "Reachable"
        case .unreachable: return "Not set"
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

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f.string(from: date)
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

    private func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
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
