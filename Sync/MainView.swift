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

// MARK: - Sync engine

final class SyncEngine: ObservableObject {
    @Published var status: SyncStatus = .ready
    @Published var lastSyncTime: Date?
    @Published var dryRunResult: DryRunResult? = nil
    @Published var syncProgress: SyncProgress? = nil

    // Auto Sync - Independent timer system
    @Published var nextAutoSyncDate: Date?
    private var autoSyncTimer: Timer?

    // Push Sync - Independent debounce system
    @Published var nextPushSyncDate: Date?
    private var pushSyncDebounceTimer: Timer?

    // Set true when an rsync launch failure has not yet been acknowledged by a
    // dropdown open. Cleared on next successful sync or when the user opens the popover.
    @Published var hasUnacknowledgedError: Bool = false
    private var task: Process?
    private var syncTotalFiles: Int    = 0
    private var syncStartTime:  Date   = Date()
    private var syncUsername:   String = ""
    private var syncIP:         String = ""
    private var isAutoSync:     Bool   = false
    private var isPushSync:     Bool   = false

    deinit {
        task?.terminate()
        duPollTimer?.invalidate()
        autoSyncTimer?.invalidate()
        pushSyncDebounceTimer?.invalidate()
        Task { @MainActor in
            ConfigStore.shared.isSyncing = false
        }
    }

    // Single entry point for both preview (config.dryRunEnabled=true) and real sync.
    // Phase 1 always runs a dry run to get accurate totals and show "Preparing...".
    // Phase 2 starts the real transfer once totals are known (skipped in preview mode).
    func sync(config: Config, isAuto: Bool = false, isPush: Bool = false) {
        guard config.isReadyToSync else { return }
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

        let rawSource = config.sourceFolder.hasPrefix("~")
            ? (NSHomeDirectory() as NSString).appendingPathComponent(String(config.sourceFolder.dropFirst()))
            : config.sourceFolder
        let source = rawSource.hasSuffix("/") ? rawSource : rawSource + "/"
        let dest   = "\(config.username)@\(config.destinationIP):~/Sync/"

        let rsyncCandidates = ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/usr/bin/rsync"]
        let rsyncPath = rsyncCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/rsync"

        // Phase 1: dry run — accurate file count + total bytes before starting transfer
        let prepProc = Process()
        prepProc.executableURL = URL(fileURLWithPath: rsyncPath)
        prepProc.arguments = ["-av", "--dry-run", "--stats", source, dest]
        let prepPipe = Pipe()
        prepProc.standardOutput = prepPipe
        prepProc.standardError  = prepPipe
        task = prepProc
        prepProc.terminationHandler = { [weak self] p in
            let data   = prepPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            // Only log on non-zero exit; suppress full output (may contain paths).
            if p.terminationStatus != 0 {
                NSLog("[Prepare] exit=%d", p.terminationStatus)
            }
            Task { @MainActor [weak self] in
                guard let self, self.status == .preparing else { return }

                if p.terminationStatus != 0 {
                    let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    self.status = .error(lines.last ?? "Prepare failed")
                    ConfigStore.shared.isSyncing = false
                    ConfigStore.shared.iconState = .error
                    return
                }

                let fileCount  = Self.parseDryRunFileCount(output)
                let totalBytes = Self.parseTotalSize(output) ?? 0
                NSLog("[Prepare] fileCount=%d totalBytes=%lld", fileCount, totalBytes)

                if config.dryRunEnabled && !self.isAutoSync {
                    // Preview mode: show file list, no transfer
                    self.status = .ready
                    ConfigStore.shared.isSyncing = false
                    ConfigStore.shared.iconState = ConfigStore.shared.config.isReadyToSync ? .idle : .notConfigured
                    let (previewFiles, _) = Self.parseDryRunOutput(output)
                    if fileCount > 0 && previewFiles.isEmpty {
                        // GNU rsync: file list parser doesn't apply, but count is known
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
                    return
                }

                // Phase 2: real transfer — totals are accurate from dry run
                self.syncTotalFiles = fileCount
                self.expectedSize   = totalBytes
                self.syncStartTime  = Date()
                self.status         = .syncing
                self.writeSyncStart(totalBytes: totalBytes, totalFiles: fileCount)

                let launchRsync = { [weak self] in
                    guard let self else { return }
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: rsyncPath)
                    proc.arguments = ["-av", source, dest]
                    proc.standardOutput = FileHandle.nullDevice
                    let errPipe = Pipe()
                    proc.standardError  = errPipe

                    proc.terminationHandler = { [weak self] p in
                        let errData   = errPipe.fileHandleForReading.readDataToEndOfFile()
                        let errOutput = String(data: errData, encoding: .utf8) ?? ""
                        // Only log on non-zero exit; suppress stderr body (may contain paths/hostnames).
                        if p.terminationStatus != 0 {
                            NSLog("[Sync] exit %d", p.terminationStatus)
                        }
                        Task { @MainActor [weak self] in
                            self?.stopDuPolling()
                            self?.syncProgress = nil
                            ConfigStore.shared.isSyncing = false
                            if p.terminationStatus == 0 {
                                let duration = Int(Date().timeIntervalSince(self?.syncStartTime ?? Date()))
                                self?.lastSyncTime = Date()
                                ConfigStore.shared.config.sshKeysConfigured = true
                                ConfigStore.shared.iconState = .success
                                self?.status = .done
                                self?.writeSyncComplete(
                                    totalFiles: self?.syncTotalFiles ?? 0,
                                    totalBytes: self?.expectedSize   ?? 0,
                                    duration:   duration)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                                    guard self?.status == .done else { return }
                                    self?.status = .ready
                                }
                            } else {
                                self?.cleanupSignalFiles()
                                let errLines = errOutput.components(separatedBy: .newlines).filter { !$0.isEmpty }
                                self?.status = .error(errLines.last ?? "Unknown error")
                                ConfigStore.shared.iconState = .error
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
                    let changedFiles = Self.parseChangedFiles(output)
                    if !changedFiles.isEmpty {
                        self.runVersioning(
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
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try prepProc.run()
            } catch {
                NSLog("[Prepare] rsync launch failed: %@", error.localizedDescription)
                Task { @MainActor [weak self] in
                    self?.handleRsyncLaunchFailure()
                }
            }
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

    // Called when rsync (prepare or transfer) cannot be launched at all — distinct from
    // rsync running and exiting non-zero, which is handled by its terminationHandler.
    // Resets engine state, surfaces an inline error, and asks the Backup to drop any
    // signal files we may have written before the failure (FIX 5).
    private func handleRsyncLaunchFailure() {
        task?.terminate()
        task = nil
        stopDuPolling()
        syncProgress = nil
        status = .error("Could not launch rsync")
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=3",
            "-o", "StrictHostKeyChecking=no",
            "\(username)@\(ip)",
            "du -sk ~/Sync 2>/dev/null | cut -f1"
        ]
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
        sshWrite("echo '{\"totalBytes\":\(totalBytes),\"totalFiles\":\(totalFiles)}' > ~/Sync/.sync_start")
    }

    private func writeSyncProgress(percent: Int) {
        sshWrite("echo '{\"percent\":\(percent)}' > ~/Sync/.sync_progress")
    }

    private func writeSyncComplete(totalFiles: Int, totalBytes: Int64, duration: Int) {
        sshWrite("echo '{\"totalFiles\":\(totalFiles),\"totalBytes\":\(totalBytes),\"duration\":\(duration)}' > ~/Sync/.sync_complete; rm -f ~/Sync/.sync_start ~/Sync/.sync_progress")
    }

    private func cleanupSignalFiles() {
        sshWrite("rm -f ~/Sync/.sync_start ~/Sync/.sync_progress ~/Sync/.sync_complete")
    }

    private func sshWrite(_ command: String) {
        guard !syncUsername.isEmpty, !syncIP.isEmpty else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=2",
            "-o", "StrictHostKeyChecking=no",
            "\(syncUsername)@\(syncIP)",
            command
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        DispatchQueue.global(qos: .utility).async { try? proc.run() }
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

    // MARK: - Push Sync - Independent debounce system

    func startPushSyncDebounce(debounceSeconds: Int) {
        pushSyncDebounceTimer?.invalidate()
        pushSyncDebounceTimer = nil

        let debounceTime = TimeInterval(debounceSeconds)
        let fireDate = Date().addingTimeInterval(debounceTime)
        nextPushSyncDate = fireDate

        pushSyncDebounceTimer = Timer.scheduledTimer(withTimeInterval: debounceTime, repeats: false) { [weak self] _ in
            self?.pushSyncTimerFired()
        }
        NSLog("[PushSync] Debounce started, will fire in %d seconds", debounceSeconds)
    }

    func stopPushSyncDebounce() {
        pushSyncDebounceTimer?.invalidate()
        pushSyncDebounceTimer = nil
        nextPushSyncDate = nil
        NSLog("[PushSync] Debounce stopped")
    }

    private func pushSyncTimerFired() {
        let config = ConfigStore.shared.config
        nextPushSyncDate = nil

        // Push Sync: Independent system with only basic guards
        guard config.pushSyncEnabled, config.isReadyToSync, !status.isActive else { return }
        NSLog("[PushSync] Timer fired, starting sync")
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
                maxVersionCount: maxVersionCount
            )
            group.enter()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=3",
                "-o", "StrictHostKeyChecking=no",
                "\(username)@\(ip)",
                cmd
            ]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError  = FileHandle.nullDevice
            proc.terminationHandler = { p in
                // Filename redacted — paths are PII in syslog.
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
        maxVersionCount: Int
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

        // ~/Sync/ prefix is kept unquoted so tilde expands; only the variable parts are quoted.
        // Adjacent quoted/unquoted segments concatenate in shell, so glob wildcards still expand.
        let fullPath = "~/Sync/\(shellEscape(relativePath))"
        let syncDir  = dirPart.isEmpty ? "~/Sync" : "~/Sync/\(shellEscape(dirPart))"

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
        state = nil
    }

    private func check(username: String, ip: String) {
        cancelInFlight()
        state = .checking
        let currentID = checkID

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-o", "ConnectTimeout=2",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=no",
            "\(username)@\(ip)",
            "exit"
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                guard let self, self.checkID == currentID else { return }
                self.state   = p.terminationStatus == 0 ? .reachable : .unreachable
                self.process = nil
            }
        }
        process = proc
        DispatchQueue.global(qos: .utility).async { try? proc.run() }
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
    @StateObject private var engine = SyncEngine()
    @StateObject private var sshChecker = SSHChecker()
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var fsEventsWatcher = FSEventsWatcher()
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
                message: "Any sync in progress will stop.",
                confirmLabel: "Quit",
                confirmColor: .red,
                onCancel: {
                    store.pendingQuitConfirm = false
                    viewState = .normal
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
                            Text(store.config.backupHostname.isEmpty ? "Not set" : store.config.backupHostname)
                                .font(.system(size: 15, weight: .medium, design: .monospaced))
                                .foregroundColor(store.config.backupHostname.isEmpty ? Color(white: 0.38) : .white)
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
                } else {
                    Button {
                        // Manual Sync: Direct engine call with no additional guards
                        engine.sync(config: store.config)
                    } label: {
                        Text(store.config.dryRunEnabled ? "Check Files" : "Sync Now")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.config.isReadyToSync || syncButtonDisabled)
                    .help(store.config.isReadyToSync ? "" : "Set source folder and BACKUP IP in Settings first")
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
                    .foregroundColor(isSyncing ? Color(white: 0.25) : Color(white: 0.5))
                    .disabled(isSyncing)
                    .help(isSyncing ? "Cancel sync first" : "")
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
            sshChecker.startChecking(username: store.config.username, ip: store.config.destinationIP)
            if store.config.autoSyncEnabled { engine.startAutoSync() }
            startPushSyncIfNeeded()
        }
        .onDisappear {
            sshChecker.stopChecking()
            engine.stopPushSyncDebounce()
            stopPushSync()
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
        .onChange(of: fsEventsWatcher.syncTrigger) { _ in
            handlePushSyncTrigger()
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

    // Push Sync trigger — called by FSEventsWatcher when file changes detected
    private func handlePushSyncTrigger() {
        // Only start debounce if push sync is enabled and not already syncing
        guard store.config.pushSyncEnabled,
              !store.isSyncing else { return }

        NSLog("[PushSync] File changes detected, starting debounce timer")
        // Use the engine's independent Push Sync debounce system
        engine.startPushSyncDebounce(debounceSeconds: store.config.pushSyncDebounce)
    }

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
