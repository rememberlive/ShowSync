// Copyright © 2026 Remember Chaitezvi. All rights reserved.
// Part of ShowSync — Remember Live.
//
// V1.1 Mac-Main → Windows-Backup transport. HARDWARE COVERAGE (live ShowSync-Win,
// 2026-07): PROVEN — discovery + pairing (both directions), sync happy path
// (multi-file, subfolders, auto mode), fast verify, Confirm Destination,
// drive-qualified/spaced destination paths, ±2 s mtime tolerance. NOT YET
// EXERCISED — mid-sync cancel, unwritable-dest fallback, low-space refusal,
// Backup-initiated verify. UNCONFIRMED — Check Files preview, deep verify,
// manual-mode 3 s poll.
//
// Transport for a Mac Main pushing to a ShowSync-Win Backup (selected by the
// platform=windows key in the Backup's TXT record, or by the manual-mode
// "Windows Backup" toggle). Windows Backups receive over plain OpenSSH sshd —
// there is NO rsync on Windows — so this module:
//
//   • pushes with sftp batches (`put -p`, recursive via depth-sorted `-mkdir`,
//     mtime-preserving, one-way, additive — never deletes remote user files);
//   • queries the remote side with PowerShell via `-EncodedCommand` (base64
//     UTF-16LE — immune to cmd-vs-PowerShell default-shell quoting);
//   • deep-verifies with `Get-FileHash -Algorithm SHA256` against local
//     CryptoKit hashes; fast verify compares size + mtime with the ±2 s
//     tolerance confirmed against ShowSync-Win (V1.1-SPEC.md §8);
//   • speaks the identical signal-file protocol (.sync_start/.sync_progress/
//     .sync_complete/.sync_refused/.verify_request/.verify_result — same names,
//     same JSON payloads) that ShowSync-Win consumes 1:1 (sync signals
//     hardware-proven via the happy path; verify-request/result and refusal
//     signals not yet exercised — see the coverage note above).
//
// Remote paths use forward slashes (C:/Users/<user>/Sync/…). An empty or
// home-relative destination resolves to "Sync" in the sshd home folder — the
// Windows analogue of the Mac path's ~/Sync fallback.
//
// This file is the ONLY home of Windows-target logic. It is unreachable unless
// Config.backupPlatform == "windows", which no Mac Backup can ever set — the
// proven rsync path and all Mac→Mac behavior are untouched (V1.1-SPEC.md §5).
// Version history / prune are NOT supported for Windows targets in V1.1
// (POSIX cp/find protocol) — skipped with a log line (V1.2 item).

import Foundation
import CryptoKit

final class WindowsTransport {
    static let shared = WindowsTransport()
    private init() {}

    // MARK: - Run state (read/written on the main thread; background stages hop to main)

    // Read by the gated early-exits in SyncEngine.cancel()/cancelVerify(): false
    // whenever no Windows-target run is active, so the Mac path falls through.
    private(set) var isSyncActive = false
    private(set) var isVerifyActive = false

    private var syncProc: Process?     // current child of the sync pipeline (ssh or sftp)
    private var verifyProc: Process?   // current child of the verify pipeline
    private var syncCancelled = false
    private var verifyCancelled = false

    // Per-run metadata. The engine's private mac-path fields (task, isAutoSync,
    // syncRemotePath, …) are never populated for a Windows run — cancel and the
    // transfer-log entry read these instead.
    private var runTrigger = "manual"
    private var runDest = "Sync"
    // The raw configured destination string this run targeted (pre-normalization)
    // — the key lastRealDestWriteTest is recorded under, so the first-hand
    // verdict string-matches what reconcileFallback receives from TXT adoption.
    private var runConfiguredDest = ""
    private var runStart = Date()
    private var runUsername = ""
    private var runIP = ""
    private var runUsedFallback = false

    // .sync_progress throttle (each write is a separate short sftp session).
    private var lastProgressSignal = Date.distantPast
    private var progressSignalInFlight = false

    // Remote-size progress poll — DELIBERATE COPY of the Mac engine's proven
    // du-poll mechanism (MainView.swift startDuPolling/pollDu/runDu/stopDuPolling),
    // NOT a refactor of it: at lock, protecting the hardware-tested Mac→Mac path
    // beats DRY, so MainView's poll stays byte-identical and this path carries its
    // own copy (shared-helper extraction is a v1.1 item). Same baseline
    // subtraction, same clamps (cap at expected + never-backward — the monotonic
    // clamp also absorbs a Windows-specific wrinkle: -ErrorAction SilentlyContinue
    // skipping a transiently-locked file can make a raw sample DIP), same 5-sample
    // rolling rate, same single-flight guard (a slow ~1-1.5s PowerShell poll
    // stretches the cadence instead of overlapping). Replaces the echo-counting
    // design, which never worked: sftp's batch echoes are block-buffered when
    // stdout is a pipe and flush only at process exit (hardware-proven — 4×700MB,
    // all four echoes in the final 6ms), so bytesDone stayed 0 all transfer.
    private var winPollTimer: Timer?
    private var winPollInFlight = false
    private var winBaselineBytes: Int64 = 0
    private var winExpectedBytes: Int64 = 0
    private var winRateSamples: [(time: Date, bytes: Int64)] = []  // rolling window for smoothed rate
    private var winLastWrittenProgress: (percent: Int, bytesDone: Int64)? = nil
    private var winLastPolledTransferred: Int64 = 0  // honest failure reporting (replaces echo under-count)

    // MARK: - Manifest types

    private struct LocalFile {
        let rel: String    // forward-slash path relative to the source root
        let abs: String    // absolute local path
        let size: Int64
        let mtime: Int64   // unix seconds, UTC
    }

    private struct RemoteFile {
        let size: Int64
        let mtime: Int64   // unix seconds, UTC (LastWriteTimeUtc)
    }

    // MARK: - Path helpers

    // User-entered or TXT-provided Windows path → canonical forward-slash form.
    static func normalizeRemotePath(_ raw: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        // "~/Sync" (the Mac default that may linger in backupDestination) and any
        // "~/" prefix mean "relative to the sshd home folder" on Windows.
        if p == "~" { p = "" }
        if p.hasPrefix("~/") { p = String(p.dropFirst(2)) }
        while p.hasSuffix("/") && p.count > 1 { p.removeLast() }
        return p
    }

    // Effective remote destination for a run. Empty → "Sync" in the sshd home
    // folder; fallback (drive unavailable semantics) → "Sync" as well.
    private static func effectiveDest(_ configured: String, usingFallback: Bool) -> String {
        if usingFallback { return "Sync" }
        let p = normalizeRemotePath(configured)
        return p.isEmpty ? "Sync" : p
    }

    private static func expandSource(_ sourceFolder: String) -> String {
        let raw = sourceFolder.hasPrefix("~")
            ? (NSHomeDirectory() as NSString).appendingPathComponent(String(sourceFolder.dropFirst()))
            : sourceFolder
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    // sftp batch-file quoting: wrap in double quotes, escape backslash + quote.
    private static func sftpQuote(_ path: String) -> String {
        "\"" + path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // PowerShell single-quoted string literal: only ' needs doubling.
    private static func psQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }

    // Exclusion parity with the Mac path: RsyncExclusions.patterns is the single
    // source of comparison criteria; a match on ANY path component excludes the
    // file (mirrors rsync --exclude semantics for these basename patterns).
    private static func isExcluded(_ rel: String) -> Bool {
        for component in rel.split(separator: "/") {
            for pattern in RsyncExclusions.patterns {
                if fnmatch(pattern, String(component), 0) == 0 { return true }
            }
        }
        return false
    }

    // MARK: - SSH / sftp process builders (same trust + NIC pinning as the Mac engine)

    // Same option set as the existing engine: BatchMode, ConnectTimeout,
    // StrictHostKeyChecking=no (Mac-native semantics per V1.1-SPEC §8), and
    // BindAddress when a preferred interface is pinned (ssh -b equivalent that
    // sftp also accepts via -o).
    private static func sshBaseArgs(connectTimeout: Int) -> [String] {
        var args = ["-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=\(connectTimeout)",
                    "-o", "StrictHostKeyChecking=no"]
        if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
           !ConfigStore.shared.config.preferredInterfaceMAC.isEmpty {
            args.insert(contentsOf: ["-o", "BindAddress=\(bindIP)"], at: 0)
        }
        return args
    }

    // Remote PowerShell via -EncodedCommand: works whether the account's sshd
    // default shell is cmd.exe or PowerShell (no remote quoting layer at all).
    // stderr rides its own pipe so remote errors can be logged on failure
    // instead of collapsing to exit-status-only (audit §1 — never-silent).
    private static func makePowerShellProcess(username: String, ip: String,
                                              script: String, connectTimeout: Int) -> (Process, Pipe, Pipe) {
        let b64 = script.data(using: .utf16LittleEndian)?.base64EncodedString() ?? ""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = sshBaseArgs(connectTimeout: connectTimeout)
        args.append(contentsOf: ["--", "\(username)@\(ip)",
                                 "powershell.exe -NoProfile -NonInteractive -EncodedCommand \(b64)"])
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        let errPipe = Pipe()
        proc.standardError = errPipe
        return (proc, pipe, errPipe)
    }

    private static func makeSftpProcess(username: String, ip: String,
                                        batchFile: URL, connectTimeout: Int) -> (Process, Pipe) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        var args = sshBaseArgs(connectTimeout: connectTimeout)
        args.append(contentsOf: ["-b", batchFile.path, "\(username)@\(ip)"])
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        return (proc, pipe)
    }

    // Run a child, draining stdout concurrently until EOF (no pipe-full deadlock —
    // manifests can be hundreds of KB). Completion fires on a background queue.
    // errPipe (when given) is drained on its own queue — a full stderr pipe would
    // deadlock the child just like stdout — and logged on nonzero exit with the
    // caller-supplied context label (audit §1 — never-silent).
    private static func run(_ proc: Process, pipe: Pipe,
                            errPipe: Pipe? = nil, context: String = "",
                            completion: @escaping (Int32, String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                try proc.run()
            } catch {
                NSLog("[V1.1/Win] launch failed: %@", error.localizedDescription)
                completion(-1, "")
                return
            }
            var errData = Data()
            let errGroup = DispatchGroup()
            if let errPipe {
                errGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    errGroup.leave()
                }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            errGroup.wait()
            if proc.terminationStatus != 0 {
                let errStr = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !errStr.isEmpty {
                    NSLog("[V1.1/Win] %@ failed (exit %d), stderr: %@",
                          context.isEmpty ? "remote command" : context,
                          proc.terminationStatus, errStr)
                }
            }
            completion(proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private static func writeBatchFile(_ lines: [String]) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("showsync_sftp_\(UUID().uuidString).batch")
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSLog("[V1.1/Win] batch file write failed: %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - PowerShell scripts

    // Anchor a possibly home-relative destination ("Sync") to $HOME; leaves
    // drive-qualified paths (C:/…) alone. Shared preamble for all scripts.
    private static func psResolvePreamble(dest: String) -> String {
        """
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $r = '\(psQuote(dest))'
        if (-not ($r -match '^[A-Za-z]:')) { $r = Join-Path $HOME $r }
        """
    }

    // One line per file: "<unix-mtime>\t<bytes>\t<relpath>" (forward slashes).
    private static func manifestScript(dest: String) -> String {
        psResolvePreamble(dest: dest) + """

        if (Test-Path -LiteralPath $r) {
          $rp = (Get-Item -LiteralPath $r).FullName
          Get-ChildItem -LiteralPath $rp -Recurse -File -Force | ForEach-Object {
            $rel = $_.FullName.Substring($rp.Length).TrimStart('\\','/').Replace('\\','/')
            $mt = [System.DateTimeOffset]::new($_.LastWriteTimeUtc, [System.TimeSpan]::Zero).ToUnixTimeSeconds()
            "$mt`t$($_.Length)`t$rel"
          }
        }
        """
    }

    // One line per file: "<SHA256-uppercase-hex>\t<relpath>".
    private static func hashScript(dest: String) -> String {
        psResolvePreamble(dest: dest) + """

        if (Test-Path -LiteralPath $r) {
          $rp = (Get-Item -LiteralPath $r).FullName
          Get-ChildItem -LiteralPath $rp -Recurse -File -Force | ForEach-Object {
            $h = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            $rel = $_.FullName.Substring($rp.Length).TrimStart('\\','/').Replace('\\','/')
            "$h`t$rel"
          }
        }
        """
    }

    // Manual-mode 3 s poll payload: free space on the destination's drive and any
    // pending .verify_request (Windows sshd has no POSIX cat/$HOME, so the Mac
    // manual-poll pipeline can't run there).
    private static func manualPollScript(dest: String) -> String {
        psResolvePreamble(dest: dest) + """

        try { $free = (Get-PSDrive -Name ((Split-Path -Qualifier $r).TrimEnd(':'))).Free } catch { $free = 0 }
        "FREE`t$free"
        $vf = Join-Path $r '.verify_request'
        if (Test-Path -LiteralPath $vf) {
          $c = (Get-Content -LiteralPath $vf -Raw -ErrorAction SilentlyContinue)
          if ($c) { "VREQ`t" + $c.Trim() }
        }
        """
    }

    // "YES"/"NO" for the post-transfer .sync_refused check.
    private static func refusedScript(dest: String) -> String {
        psResolvePreamble(dest: dest) + """

        if (Test-Path -LiteralPath (Join-Path $r '\(SignalFile.refused)')) { 'YES' } else { 'NO' }
        """
    }

    // Destination tree byte total for the progress poll — the Windows analogue of
    // the Mac poll's `du -sk`. ⚠️ Returns BYTES directly (Length sums), NOT KB:
    // the Mac multiplies by 1024 because du -sk reports KB — this must NOT.
    // Missing dest / locked files → Sum is $null → [int64] coerces to 0.
    private static func sizeScript(dest: String) -> String {
        psResolvePreamble(dest: dest) + """

        [int64]((Get-ChildItem -LiteralPath $r -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum)
        """
    }

    private static func parseManifest(_ output: String) -> [String: RemoteFile] {
        var result: [String: RemoteFile] = [:]
        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 3,
                  let mtime = Int64(parts[0].trimmingCharacters(in: .whitespaces)),
                  let size = Int64(parts[1]) else { continue }
            let rel = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rel.isEmpty else { continue }
            result[rel] = RemoteFile(size: size, mtime: mtime)
        }
        return result
    }

    private static func parseHashes(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2, parts[0].count == 64 else { continue }
            let rel = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rel.isEmpty else { continue }
            result[rel] = parts[0].uppercased()
        }
        return result
    }

    // MARK: - Local side

    // Regular files only (symlinks skipped — the additive push has no meaningful
    // symlink representation on the Windows side), hidden files included, shared
    // exclusions applied — the same comparison set as sync AND verify.
    private static func localManifest(source: String) -> [LocalFile]? {
        let rootURL = URL(fileURLWithPath: source)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let rootPath = rootURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: keys) else { return nil }
        var files: [LocalFile] = []
        for case let url as URL in enumerator {
            guard let res = try? url.resourceValues(forKeys: Set(keys)),
                  res.isRegularFile == true else { continue }
            let abs = url.path
            guard abs.hasPrefix(rootPath) else { continue }
            var rel = String(abs.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            guard !rel.isEmpty, !isExcluded(rel) else { continue }
            files.append(LocalFile(
                rel: rel,
                abs: abs,
                size: Int64(res.fileSize ?? 0),
                mtime: Int64((res.contentModificationDate ?? .distantPast).timeIntervalSince1970)))
        }
        return files.sorted { $0.rel < $1.rel }
    }

    // Additive diff: upload files that are missing remotely, differ in size, or
    // differ in mtime beyond ±2 s (UTC epoch seconds — tolerance confirmed against
    // ShowSync-Win, V1.1-SPEC §8). Extra remote files are ignored (push-direction
    // rsync semantics; never deleted).
    private static func computeUploads(local: [LocalFile], remote: [String: RemoteFile]) -> [LocalFile] {
        local.filter { f in
            guard let r = remote[f.rel] else { return true }
            if r.size != f.size { return true }
            return abs(r.mtime - f.mtime) > 2
        }
    }

    private static func sha256Hex(path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk = fh.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - Signal files (identical names + JSON payloads to the Mac engine)

    // Upload a small locally-written file as <dest>/<name>, optionally removing
    // other signal files in the same session. Fire-and-forget unless completion given.
    private func putSignalFile(name: String, contents: String,
                               removing: [String] = [],
                               logOutcome: Bool = false,
                               completion: ((Bool) -> Void)? = nil) {
        Self.putSignalFile(username: runUsername, ip: runIP, dest: runDest,
                           name: name, contents: contents, removing: removing) { status, output in
            // audit §1 — never-silent: .sync_start/.sync_complete opt in; the
            // throttled .sync_progress stays quiet (3 s cadence would spam).
            if logOutcome {
                if status == 0 {
                    NSLog("[V1.1/Win] %@ delivered", name)
                } else {
                    NSLog("[V1.1/Win] %@ write FAILED (exit %d): %@", name, status,
                          output.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            completion?(status == 0)
        }
    }

    // sftp batch path form: the OpenSSH server resolves "C:/…" as HOME-relative
    // (home prefix gets doubled: "/C:/Users/u/C:/Users/u/…"); a drive-qualified
    // dest must be written "/C:/…" (hardware-confirmed). Relative dests ("Sync")
    // pass through untouched — the proven form the sync signals always used.
    private static func sftpPathForm(_ dest: String) -> String {
        if dest.range(of: "^[A-Za-z]:", options: .regularExpression) != nil {
            return "/" + dest
        }
        return dest
    }

    // Core signal-write primitive: the same sftp batch shape that lands
    // .sync_start/.sync_complete on ShowSync-Win. Static (and internal) so the
    // engine's writeVerifyResult AND control-plane writers (the Settings rename —
    // BUG A: its POSIX `echo -n '…' > file` ran under cmd.exe, which has no -n
    // and treats single quotes as literals, corrupting the delivered name) can
    // use it outside a WindowsTransport-driven run.
    // Completion receives the sftp exit status and combined stdout/stderr.
    static func putSignalFile(username: String, ip: String, dest: String,
                                      name: String, contents: String,
                                      removing: [String] = [],
                                      completion: @escaping (Int32, String) -> Void) {
        let dest = sftpPathForm(dest)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("showsync_sig_\(UUID().uuidString)")
        do {
            try contents.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            completion(-1, "local temp write failed: \(error.localizedDescription)"); return
        }
        var lines = ["-mkdir \(sftpQuote(dest))",
                     // ATOMIC signal write: put to a .tmp name, then rename into place.
                     // A direct put is OPEN(TRUNC)→WRITE→CLOSE as separate SFTP packets,
                     // leaving the destination EMPTY for milliseconds per write — and the
                     // Windows Backup polls every 0.5s, so it could read mid-write. The
                     // benign symptom was progress flicker; the serious one was a torn
                     // .verify_result turning a SUCCESSFUL verify into a customer-visible
                     // red "Verify failed" (file deleted + nonce cleared → no retry).
                     // sftp's rename uses posix-rename@openssh.com when the server offers
                     // it (OpenSSH for Windows does — atomic NTFS replace), so readers see
                     // the old file or the new file, never a torn one. Both readers key on
                     // exact filenames, so the transient .tmp is invisible to them. Note:
                     // the rename line has NO leading dash — if it ever failed (a server
                     // without the extension can't rename onto an existing target), the
                     // batch must FAIL VISIBLY (nonzero exit → logged), not fall through.
                     "put \(sftpQuote(tmp.path)) \(sftpQuote(dest + "/" + name + ".tmp"))",
                     "rename \(sftpQuote(dest + "/" + name + ".tmp")) \(sftpQuote(dest + "/" + name))"]
        for r in removing { lines.append("-rm \(sftpQuote(dest + "/" + r))") }
        guard let batch = writeBatchFile(lines) else { completion(-1, "batch file write failed"); return }
        let (proc, pipe) = makeSftpProcess(username: username, ip: ip,
                                           batchFile: batch, connectTimeout: 2)
        run(proc, pipe: pipe) { status, output in
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: batch)
            completion(status, output)
        }
    }

    // SYNC-SPEC §8.10: standalone .verify_result write for the engine's
    // writeVerifyResult — its POSIX `echo … > file; rm -f …` dies silently in
    // cmd.exe, so a Backup-initiated verify answered by the MAC engine path
    // never got its outcome. Same JSON payload as the Mac path, delivered
    // through the same signal-write primitive that lands .sync_start/
    // .sync_complete. Outcome is logged either way — a failed verify-result
    // write must never be silent.
    static func writeVerifyResultSignal(username: String, ip: String, destination: String,
                                        usingFallback: Bool, resultCode: String) {
        let dest = effectiveDest(destination, usingFallback: usingFallback)
        let ts = Int(Date().timeIntervalSince1970)
        putSignalFile(username: username, ip: ip, dest: dest,
                      name: SignalFile.verifyResult,
                      contents: "{\"result\":\"\(resultCode)\",\"ts\":\(ts)}",
                      removing: [SignalFile.verifyRequest]) { status, output in
            if status == 0 {
                NSLog("[V1.1/Win] .verify_result delivered to '%@' (result=%@)", dest, resultCode)
            } else {
                NSLog("[V1.1/Win] .verify_result write FAILED (exit %d) to '%@': %@",
                      status, dest, output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private func removeSignalFiles(_ names: [String]) {
        let dest = Self.sftpPathForm(runDest)
        let lines = names.map { "-rm \(Self.sftpQuote(dest + "/" + $0))" }
        guard let batch = Self.writeBatchFile(lines) else { return }
        let (proc, pipe) = Self.makeSftpProcess(username: runUsername, ip: runIP,
                                                batchFile: batch, connectTimeout: 2)
        let joined = names.joined(separator: ", ")
        Self.run(proc, pipe: pipe) { status, output in
            try? FileManager.default.removeItem(at: batch)
            // Per-file misses are ignored by design (`-rm`); a nonzero exit here
            // is connection-level — log it (audit §1 — never-silent).
            if status != 0 {
                NSLog("[V1.1/Win] signal cleanup (%@) FAILED (exit %d): %@", joined, status,
                      output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    // MARK: - Sync (called from SyncEngine.sync() gate, main thread; status is
    // already .preparing / isSyncing=true / icon .syncing from the shared preamble)

    func startSync(config: Config, isAuto: Bool, isPush: Bool) {
        guard !isSyncActive else { return }
        isSyncActive = true
        syncCancelled = false
        runTrigger = isAuto ? "auto" : (isPush ? "push" : "manual")
        runUsername = config.username
        runIP = config.destinationIP
        // BUG C fix — the Mac engine's own written rule now applies here too:
        // fallback is decided by THIS attempt's write-test, not a cached flag.
        // The old `runDest = effectiveDest(_, usingFallback: cached)` self-sealed:
        // once latched, every later sync derived runDest = "Sync" from the flag,
        // the write-test then tested "Sync" (writable → no news), and the only
        // self-clear was gated `runDest != "Sync"` — unreachable forever. Both
        // sync AND verify silently redirected to the home folder on a custom
        // destination, and verify green-lit the wrong folder. Only a relaunch
        // (fresh SyncEngine, usingFallback=false) broke the loop.
        runUsedFallback = false
        runConfiguredDest = config.backupDestination
        runDest = Self.effectiveDest(config.backupDestination, usingFallback: false)
        runStart = Date()
        lastProgressSignal = .distantPast
        progressSignalInFlight = false

        let isPreviewOnly = config.dryRunEnabled && !isAuto
        let source = Self.expandSource(config.sourceFolder)
        let versionsRequested = config.versionHistoryEnabled

        NSLog("[V1.1/Win] sync start: dest='%@', trigger=%@, preview=%d", runDest, runTrigger, isPreviewOnly ? 1 : 0)
        if versionsRequested && !isPreviewOnly {
            NSLog("[V1.1/Win] Version history is not supported for Windows targets — skipped (V1.2)")
        }

        // Stage 1 — local manifest (background; source missing → error out).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let local = Self.localManifest(source: source) else {
                self.finishSyncFailure(message: "Sync interrupted — files may be incomplete")
                return
            }
            // Stage 2 — remote manifest.
            let (proc, pipe, errPipe) = Self.makePowerShellProcess(
                username: self.runUsername, ip: self.runIP,
                script: Self.manifestScript(dest: self.runDest), connectTimeout: 5)
            DispatchQueue.main.async { self.syncProc = proc }
            Self.run(proc, pipe: pipe, errPipe: errPipe, context: "sync manifest") { [weak self] status, output in
                guard let self, !self.syncCancelled else { return }
                guard status == 0 else {
                    if isPreviewOnly {
                        self.finishPreview(result: DryRunResult(
                            title: "Check Files Failed",
                            body: "Couldn't connect to the backup. Check your connection."))
                    } else {
                        self.finishSyncFailure(message: "Sync interrupted — files may be incomplete")
                    }
                    return
                }
                let remote = Self.parseManifest(output)
                let uploads = Self.computeUploads(local: local, remote: remote)

                if isPreviewOnly {
                    // Same-comparator preview (approved §8): the diff that WOULD sync.
                    self.finishPreview(result: Self.previewResult(uploads: uploads))
                    return
                }
                self.runWriteTestThenTransfer(uploads: uploads)
            }
        }
    }

    // Stage 3 — write-test with the same fallback semantics as the Mac engine:
    // clear unwritable → fall back to the default folder; connection-level failure
    // → proceed anyway (.testFailed spirit).
    private func runWriteTestThenTransfer(uploads: [LocalFile]) {
        let testName = ".sync_writetest_\(Int.random(in: 1000...9999))"
        let dest = Self.sftpPathForm(runDest)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("showsync_wt_\(UUID().uuidString)")
        try? "test".write(to: tmp, atomically: true, encoding: .utf8)
        let lines = ["-mkdir \(Self.sftpQuote(dest))",
                     "put \(Self.sftpQuote(tmp.path)) \(Self.sftpQuote(dest + "/" + testName))",
                     "rm \(Self.sftpQuote(dest + "/" + testName))"]
        guard let batch = Self.writeBatchFile(lines) else {
            finishSyncFailure(message: "Sync interrupted — files may be incomplete")
            return
        }
        let (proc, pipe) = Self.makeSftpProcess(username: runUsername, ip: runIP,
                                                batchFile: batch, connectTimeout: 5)
        DispatchQueue.main.async { self.syncProc = proc }
        Self.run(proc, pipe: pipe) { [weak self] status, output in
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: batch)
            guard let self, !self.syncCancelled else { return }
            if status == 0 {
                // First-hand verdict: the configured dest IS writable. Record it
                // for the 2ae7839 reconcile (this transport previously never fed
                // lastRealDestWriteTest — the flag could be set here but no
                // first-hand truth ever countered a stale advertisement) and
                // self-heal a latched flag, mirroring the Mac write-test exactly.
                let configuredDest = self.runConfiguredDest
                DispatchQueue.main.async {
                    SyncEngine.shared.lastRealDestWriteTest = (configuredDest, true)
                    if SyncEngine.shared.usingFallback { SyncEngine.shared.usingFallback = false }
                }
            }
            if status != 0 {
                if output.contains("sftp>") && self.runDest != "Sync" {
                    // Connected but couldn't write → same fallback as the Mac path.
                    NSLog("[V1.1/Win] Destination unwritable, falling back to Sync (home folder)")
                    let previousDest = self.runDest
                    let configuredDest = self.runConfiguredDest
                    DispatchQueue.main.async {
                        // First-hand verdict: the configured dest is NOT writable.
                        SyncEngine.shared.lastRealDestWriteTest = (configuredDest, false)
                        self.runDest = "Sync"
                        self.runUsedFallback = true
                        SyncEngine.shared.usingFallback = true
                        SyncEngine.shared.fallbackNotice = "Couldn't write to the chosen folder — backing up to the default Sync folder instead."
                        // The diff was computed against the old dest — recompute against Sync.
                        NSLog("[V1.1/Win] re-running manifest against fallback (was '%@')", previousDest)
                        self.restartAfterFallback()
                    }
                    return
                }
                NSLog("[V1.1/Win] Write-test failed (connection-level), proceeding anyway")
            }
            self.beginTransfer(uploads: uploads)
        }
    }

    // Fallback changes the destination, so the additive diff must be recomputed
    // against the new remote root before transferring.
    private func restartAfterFallback() {
        let config = ConfigStore.shared.config
        let source = Self.expandSource(config.sourceFolder)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, !self.syncCancelled else { return }
            guard let local = Self.localManifest(source: source) else {
                self.finishSyncFailure(message: "Sync interrupted — files may be incomplete")
                return
            }
            let (proc, pipe, errPipe) = Self.makePowerShellProcess(
                username: self.runUsername, ip: self.runIP,
                script: Self.manifestScript(dest: self.runDest), connectTimeout: 5)
            DispatchQueue.main.async { self.syncProc = proc }
            Self.run(proc, pipe: pipe, errPipe: errPipe, context: "fallback re-manifest") { [weak self] status, output in
                guard let self, !self.syncCancelled else { return }
                guard status == 0 else {
                    self.finishSyncFailure(message: "Sync interrupted — files may be incomplete")
                    return
                }
                self.beginTransfer(uploads: Self.computeUploads(local: local, remote: Self.parseManifest(output)))
            }
        }
    }

    // Stage 4 — signal .sync_start, then the sftp transfer batch, with progress
    // from the remote-size poll (the ported Mac du-poll mechanism — see the poll
    // fields above for why the old per-file echo counting was removed).
    private func beginTransfer(uploads: [LocalFile]) {
        let expectedBytes = uploads.reduce(Int64(0)) { $0 + $1.size }
        let expectedFiles = uploads.count

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.syncCancelled else { return }
            SyncEngine.shared.status = .syncing
            SyncEngine.shared.syncProgress = SyncProgress(
                transferred: 0, expected: expectedBytes, startTime: self.runStart, bytesPerSec: nil)
            // Ported du-poll: baseline snapshot first, then the 1s cadence —
            // same launch ordering as the Mac path (poll starts, transfer follows).
            self.winExpectedBytes = expectedBytes
            self.startWinPolling()
        }

        // Same payload as the Mac engine's writeSyncStart.
        putSignalFile(name: SignalFile.start,
                      contents: "{\"totalBytes\":\(expectedBytes),\"totalFiles\":\(expectedFiles)}",
                      logOutcome: true)

        guard !uploads.isEmpty else {
            // Nothing to transfer — still a successful (empty) sync, like rsync exit 0.
            checkRefusedThenFinish(uploadedFiles: 0, uploadedBytes: 0)
            return
        }

        // Depth-sorted -mkdir set (ignore already-exists), then mtime-preserving puts.
        let dest = Self.sftpPathForm(runDest)
        var dirs = Set<String>()
        for f in uploads {
            var path = dest
            for c in f.rel.split(separator: "/").dropLast() {
                path += "/" + c
                dirs.insert(path)
            }
        }
        var lines = ["-mkdir \(Self.sftpQuote(dest))"]
        for d in dirs.sorted(by: { (a, b) in
            let da = a.filter { $0 == "/" }.count, db = b.filter { $0 == "/" }.count
            return da == db ? a < b : da < db
        }) {
            lines.append("-mkdir \(Self.sftpQuote(d))")
        }
        for f in uploads {
            lines.append("put -p \(Self.sftpQuote(f.abs)) \(Self.sftpQuote(dest + "/" + f.rel))")
        }
        guard let batch = Self.writeBatchFile(lines) else {
            finishSyncFailure(message: "Sync interrupted — files may be incomplete")
            return
        }

        let (proc, pipe) = Self.makeSftpProcess(username: runUsername, ip: runIP,
                                                batchFile: batch, connectTimeout: 5)
        DispatchQueue.main.async { self.syncProc = proc }

        // Drain stdout — the handler MUST keep reading: a full pipe DEADLOCKS the
        // sftp child and Mac→Windows transfers stop entirely. The batch echoes it
        // drains are useless for progress (block-buffered when stdout is a pipe;
        // they flush only at process exit — hardware-proven: 4×700MB showed all
        // four echoes in the final 6ms), so they are read and discarded; progress
        // comes from the remote-size poll started above.
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fh in
            _ = fh.availableData   // read-and-discard; handler cleared in termination
        }

        proc.terminationHandler = { [weak self] p in
            handle.readabilityHandler = nil
            try? FileManager.default.removeItem(at: batch)
            guard let self else { return }
            let exit = p.terminationStatus
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stopWinPolling()
                if self.syncCancelled { return }
                if exit == 0 {
                    // Batch exit 0 ⇒ every put completed.
                    NSLog("[V1.1/Win] sftp batch complete: %d files, %lld bytes", uploads.count, expectedBytes)
                    self.checkRefusedThenFinish(uploadedFiles: uploads.count, uploadedBytes: expectedBytes)
                } else {
                    // Honest failure accounting: the last polled remote-size delta
                    // replaces the old echo-derived count (which was always 0).
                    let moved = self.winLastPolledTransferred
                    NSLog("[V1.1/Win] sftp exit %d after ~%lld of %lld bytes moved", exit, moved, expectedBytes)
                    self.finishSyncFailure(message: "Sync interrupted — files may be incomplete",
                                           movedBytes: moved)
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try proc.run()
            } catch {
                handle.readabilityHandler = nil
                try? FileManager.default.removeItem(at: batch)
                NSLog("[V1.1/Win] sftp launch failed: %@", error.localizedDescription)
                DispatchQueue.main.async { self?.stopWinPolling() }
                self?.finishSyncFailure(message: "Sync interrupted — files may be incomplete")
            }
        }
    }

    // MARK: - Remote-size progress poll (ported Mac du-poll — see field comments)

    // Baseline snapshot, then 1s cadence. Called on main (Timer needs the main
    // runloop), mirroring MainView.startDuPolling.
    private func startWinPolling() {
        winPollInFlight = false
        winRateSamples = []
        winLastWrittenProgress = nil
        winLastPolledTransferred = 0
        runWinSize { [weak self] baseline in
            guard let self, self.isSyncActive, !self.syncCancelled else { return }
            self.winBaselineBytes = baseline
            self.winPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.pollWinSize()
            }
        }
    }

    private func pollWinSize() {
        runWinSize { [weak self] current in
            guard let self, self.isSyncActive, !self.syncCancelled else { return }
            let transferred = max(0, current - self.winBaselineBytes)
            var capped = self.winExpectedBytes > 0 ? min(transferred, self.winExpectedBytes) : transferred
            capped = max(capped, SyncEngine.shared.syncProgress?.transferred ?? 0)  // bar never moves backward
            self.winLastPolledTransferred = capped

            // Rolling rate window (5 samples ≈ 5 s) for a smoothed ETA
            self.winRateSamples.append((time: Date(), bytes: capped))
            if self.winRateSamples.count > 5 { self.winRateSamples.removeFirst() }
            var rate: Double? = nil
            if self.winRateSamples.count >= 3,
               let first = self.winRateSamples.first, let last = self.winRateSamples.last {
                let dt = last.time.timeIntervalSince(first.time)
                if dt > 0 { rate = Double(last.bytes - first.bytes) / dt }
            }

            let newProgress = SyncProgress(transferred: capped,
                                           expected: self.winExpectedBytes,
                                           startTime: self.runStart,
                                           bytesPerSec: rate)
            if SyncEngine.shared.syncProgress != newProgress { SyncEngine.shared.syncProgress = newProgress }

            let percent: Int = self.winExpectedBytes > 0
                ? Int(min(Double(capped) / Double(self.winExpectedBytes), 1.0) * 100)
                : -1
            // Skip the signal write when nothing changed (stalled transfer);
            // maybeSignalProgress adds its own 3s throttle on top.
            if self.winLastWrittenProgress?.percent != percent || self.winLastWrittenProgress?.bytesDone != capped {
                self.winLastWrittenProgress = (percent, capped)
                self.maybeSignalProgress(bytesDone: capped, bytesTotal: self.winExpectedBytes)
            }
        }
    }

    private func stopWinPolling() {
        winPollTimer?.invalidate()
        winPollTimer = nil
        winPollInFlight = false
        winRateSamples = []
    }

    // One remote size sample via the existing PowerShell plumbing. Single-flight
    // (ported duInFlight guard): a slow poll (~1-1.5s: ssh handshake + PowerShell
    // cold start + tree walk) stretches the cadence to ~1.5-2s instead of
    // overlapping. Completion always fires on main; failed/unparseable samples
    // report 0 — harmless, exactly like the Mac poll: for the baseline it means
    // whole-dest counting capped by expected, for a mid-run sample the monotonic
    // never-backward clamp eats it.
    private func runWinSize(completion: @escaping (Int64) -> Void) {
        guard !winPollInFlight else { return }
        winPollInFlight = true
        let (proc, pipe, errPipe) = Self.makePowerShellProcess(
            username: runUsername, ip: runIP,
            script: Self.sizeScript(dest: runDest), connectTimeout: 3)
        Self.run(proc, pipe: pipe, errPipe: errPipe, context: "size poll") { [weak self] status, output in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.winPollInFlight = false
                let line = output.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty } ?? ""
                // BYTES directly (PowerShell Length sums) — no ×1024 (that is du -sk's KB quirk).
                let bytes = (status == 0) ? (Int64(line) ?? 0) : 0
                completion(bytes)
            }
        }
    }

    // Throttled .sync_progress writes (each is a short separate sftp session; the
    // Backup's signal poll is 0.5 s but 3 s granularity here keeps SSH churn sane).
    private func maybeSignalProgress(bytesDone: Int64, bytesTotal: Int64) {
        guard !progressSignalInFlight, Date().timeIntervalSince(lastProgressSignal) > 3 else { return }
        progressSignalInFlight = true
        lastProgressSignal = Date()
        let percent = bytesTotal > 0 ? Int(min(Double(bytesDone) / Double(bytesTotal), 1.0) * 100) : -1
        putSignalFile(
            name: SignalFile.progress,
            contents: "{\"percent\":\(percent),\"bytesDone\":\(bytesDone),\"bytesTotal\":\(bytesTotal)}"
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.progressSignalInFlight = false }
        }
    }

    // Stage 5 — .sync_refused check (same timing as the Mac path: after transfer),
    // then completion bookkeeping.
    private func checkRefusedThenFinish(uploadedFiles: Int, uploadedBytes: Int64) {
        let (proc, pipe, errPipe) = Self.makePowerShellProcess(
            username: runUsername, ip: runIP,
            script: Self.refusedScript(dest: runDest), connectTimeout: 2)
        DispatchQueue.main.async { self.syncProc = proc }
        Self.run(proc, pipe: pipe, errPipe: errPipe, context: "refused check") { [weak self] status, output in
            guard let self, !self.syncCancelled else { return }
            let refused = (status == 0) && output.contains("YES")
            if refused {
                self.removeSignalFiles([SignalFile.start, SignalFile.progress])
                self.finishSyncRefused()
            } else {
                self.finishSyncSuccess(uploadedFiles: uploadedFiles, uploadedBytes: uploadedBytes)
            }
        }
    }

    // MARK: - Sync completion paths (mirror the Mac engine's state machine)

    private func finishPreview(result: DryRunResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSyncActive = false
            self.syncProc = nil
            guard SyncEngine.shared.status == .preparing else { return }
            SyncEngine.shared.status = .ready
            ConfigStore.shared.isSyncing = false
            ConfigStore.shared.iconState = ConfigStore.shared.config.isReadyToSync ? .idle : .notConfigured
            SyncEngine.shared.dryRunResult = result
        }
    }

    // Same strings as the Mac preview so the dropdown reads identically.
    private static func previewResult(uploads: [LocalFile]) -> DryRunResult {
        guard !uploads.isEmpty else {
            return DryRunResult(title: "Check Files Complete",
                                body: "Everything is up to date.\nNo files need to be transferred.")
        }
        let totalBytes = uploads.reduce(Int64(0)) { $0 + $1.size }
        var lines = ["\(uploads.count) file\(uploads.count == 1 ? "" : "s") will be transferred",
                     "Total size: \(formatBytes(totalBytes))", ""]
        let names = uploads.map { URL(fileURLWithPath: $0.rel).lastPathComponent }
        for (i, name) in names.prefix(5).enumerated() {
            let display = name.count > 35
                ? String(name.prefix(15)) + "..." + String(name.suffix(12))
                : name
            lines.append("  \(i + 1). \(display)")
        }
        if names.count > 5 { lines.append("  + \(names.count - 5) more") }
        return DryRunResult(title: "Check Files Complete", body: lines.joined(separator: "\n"))
    }

    private func finishSyncSuccess(uploadedFiles: Int, uploadedBytes: Int64) {
        let duration = Int(Date().timeIntervalSince(runStart))
        // Same payload as the Mac engine's writeSyncComplete (+ removes start/progress).
        putSignalFile(name: SignalFile.complete,
                      contents: "{\"totalFiles\":\(uploadedFiles),\"totalBytes\":\(uploadedBytes),\"duration\":\(duration)}",
                      removing: [SignalFile.start, SignalFile.progress],
                      logOutcome: true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stopWinPolling()
            self.isSyncActive = false
            self.syncProc = nil
            let engine = SyncEngine.shared
            engine.syncProgress = nil
            ConfigStore.shared.isSyncing = false
            engine.lastSyncTime = Date()
            ConfigStore.shared.config.sshKeysConfigured = true
            ConfigStore.shared.iconState = self.runUsedFallback ? .warning : .success
            engine.status = .done
            ConfigStore.shared.appendTransferLogEntry(TransferLogEntry(
                id: UUID(), date: Date(), trigger: self.runTrigger,
                result: self.runUsedFallback ? "fallback" : "success",
                fileCount: uploadedFiles, totalBytes: uploadedBytes,
                durationSeconds: duration, destination: self.runDest,
                usedFallback: self.runUsedFallback))
            // Synced to the chosen (non-default) folder → the drive is back.
            if self.runDest != "Sync" {
                engine.usingFallback = false
            }
            NSLog("[V1.1/Win] sync done: %d files, %lld bytes, %ds", uploadedFiles, uploadedBytes, duration)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard engine.status == .done else { return }
                engine.status = .ready
                engine.fallbackNotice = nil
            }
        }
    }

    private func finishSyncRefused() {
        let duration = Int(Date().timeIntervalSince(runStart))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stopWinPolling()
            self.isSyncActive = false
            self.syncProc = nil
            let engine = SyncEngine.shared
            engine.syncProgress = nil
            ConfigStore.shared.isSyncing = false
            engine.lowSpaceNotice = "Not enough space on the backup drive. Free up space to resume backups."
            engine.status = .error("Backup drive low on space")
            ConfigStore.shared.iconState = .error
            ConfigStore.shared.appendTransferLogEntry(TransferLogEntry(
                id: UUID(), date: Date(), trigger: self.runTrigger, result: "refused",
                fileCount: 0, totalBytes: 0, durationSeconds: duration,
                destination: self.runDest, usedFallback: self.runUsedFallback))
        }
    }

    // movedBytes: last polled remote-size delta at failure time — honest
    // accounting for the transfer log (the old echo-derived count was always 0).
    // Non-transfer failure sites (manifest, batch-file, launch) pass the default.
    private func finishSyncFailure(message: String, movedBytes: Int64 = 0) {
        let duration = Int(Date().timeIntervalSince(runStart))
        removeSignalFiles([SignalFile.start, SignalFile.progress])
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stopWinPolling()
            self.isSyncActive = false
            self.syncProc = nil
            let engine = SyncEngine.shared
            engine.syncProgress = nil
            ConfigStore.shared.isSyncing = false
            engine.status = .error(message)
            ConfigStore.shared.iconState = .error
            ConfigStore.shared.appendTransferLogEntry(TransferLogEntry(
                id: UUID(), date: Date(), trigger: self.runTrigger, result: "failed",
                fileCount: 0, totalBytes: movedBytes, durationSeconds: duration,
                destination: self.runDest, usedFallback: self.runUsedFallback))
        }
    }

    // Called from the gated early-exit in SyncEngine.cancel() (main thread).
    func cancelSync() {
        guard isSyncActive else { return }
        syncCancelled = true
        stopWinPolling()
        syncProc?.terminate()
        syncProc = nil
        isSyncActive = false
        removeSignalFiles([SignalFile.start, SignalFile.progress, SignalFile.complete])
        let duration = Int(Date().timeIntervalSince(runStart))
        let engine = SyncEngine.shared
        engine.status = .cancelled
        engine.syncProgress = nil
        ConfigStore.shared.isSyncing = false
        ConfigStore.shared.iconState = ConfigStore.shared.config.isReadyToSync ? .idle : .notConfigured
        ConfigStore.shared.appendTransferLogEntry(TransferLogEntry(
            id: UUID(), date: Date(), trigger: runTrigger, result: "cancelled",
            fileCount: 0, totalBytes: 0, durationSeconds: duration,
            destination: runDest, usedFallback: runUsedFallback))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if engine.status == .cancelled { engine.status = .ready }
        }
    }

    // MARK: - Verify (called from SyncEngine.verifyNow() gate, main thread)

    func startVerify(config: Config) {
        guard !isVerifyActive else { return }
        isVerifyActive = true
        verifyCancelled = false
        runUsername = config.username
        runIP = config.destinationIP
        runDest = Self.effectiveDest(config.backupDestination,
                                     usingFallback: SyncEngine.shared.usingFallback)
        let source = Self.expandSource(config.sourceFolder)
        let fast = config.fastVerify
        SyncEngine.shared.verifyStatus = .verifying
        NSLog("[V1.1/Win] verify start: dest='%@', fast=%d", runDest, fast ? 1 : 0)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let local = Self.localManifest(source: source) else {
                self.finishVerify(.failed("Verify failed — couldn't read source folder"), resultCode: "error")
                return
            }
            let script = fast ? Self.manifestScript(dest: self.runDest)
                              : Self.hashScript(dest: self.runDest)
            let (proc, pipe, errPipe) = Self.makePowerShellProcess(
                username: self.runUsername, ip: self.runIP, script: script, connectTimeout: 5)
            DispatchQueue.main.async { self.verifyProc = proc }
            Self.run(proc, pipe: pipe, errPipe: errPipe, context: fast ? "fast-verify manifest" : "deep-verify hashes") { [weak self] status, output in
                guard let self, !self.verifyCancelled else { return }
                guard status == 0 else {
                    self.finishVerify(.failed("Verify failed — couldn't reach Backup"), resultCode: "error")
                    return
                }
                var differs = 0
                if fast {
                    // Fast: size + mtime ±2 s — the same comparator the sync diff uses.
                    let remote = Self.parseManifest(output)
                    differs = Self.computeUploads(local: local, remote: remote).count
                } else {
                    // Deep: SHA256 — Get-FileHash remotely, CryptoKit locally.
                    let remote = Self.parseHashes(output)
                    for f in local {
                        if self.verifyCancelled { return }
                        guard let remoteHash = remote[f.rel] else { differs += 1; continue }
                        guard let localHash = Self.sha256Hex(path: f.abs) else { differs += 1; continue }
                        if localHash != remoteHash { differs += 1 }
                    }
                }
                if differs == 0 {
                    self.finishVerify(.verified(deep: !fast), resultCode: "ok")
                } else {
                    self.finishVerify(.differs(differs), resultCode: "differs:\(differs)")
                }
            }
        }
    }

    private func finishVerify(_ status: VerifyStatus, resultCode: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isVerifyActive = false
            self.verifyProc = nil
            let engine = SyncEngine.shared
            engine.verifyStatus = status
            // Backup-requested verify: write .verify_result + clear the request,
            // same payload as the Mac engine's writeVerifyResult. Outcome logged
            // either way — a failed verify-result write must never be silent.
            if engine.isRemoteVerify {
                engine.isRemoteVerify = false
                let ts = Int(Date().timeIntervalSince1970)
                Self.putSignalFile(username: self.runUsername, ip: self.runIP, dest: self.runDest,
                                   name: SignalFile.verifyResult,
                                   contents: "{\"result\":\"\(resultCode)\",\"ts\":\(ts)}",
                                   removing: [SignalFile.verifyRequest]) { pStatus, pOutput in
                    if pStatus == 0 {
                        NSLog("[V1.1/Win] .verify_result delivered (result=%@)", resultCode)
                    } else {
                        NSLog("[V1.1/Win] .verify_result write FAILED (exit %d): %@",
                              pStatus, pOutput.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
            NSLog("[V1.1/Win] verify done: %@", resultCode)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if case .verified = engine.verifyStatus { engine.verifyStatus = .idle }
                if case .differs = engine.verifyStatus { engine.verifyStatus = .idle }
                if case .failed = engine.verifyStatus { engine.verifyStatus = .idle }
            }
        }
    }

    // Called from the gated early-exit in SyncEngine.cancelVerify() (main thread).
    func cancelVerify() {
        guard isVerifyActive else { return }
        verifyCancelled = true
        verifyProc?.terminate()
        verifyProc = nil
        isVerifyActive = false
        SyncEngine.shared.verifyStatus = .idle
        SyncEngine.shared.isRemoteVerify = false
    }

    // MARK: - Settings support (manual mode)

    // "Confirm Destination" for a Windows target: SFTP write-test of the
    // user-entered path (no remote config read in V1.1 — approved §8.1).
    func probeDestination(username: String, ip: String, destination: String,
                          completion: @escaping (Bool) -> Void) {
        let dest = Self.sftpPathForm(Self.effectiveDest(destination, usingFallback: false))
        let testName = ".sync_writetest_\(Int.random(in: 1000...9999))"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("showsync_probe_\(UUID().uuidString)")
        do {
            try "test".write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            completion(false); return
        }
        let lines = ["-mkdir \(Self.sftpQuote(dest))",
                     "put \(Self.sftpQuote(tmp.path)) \(Self.sftpQuote(dest + "/" + testName))",
                     "rm \(Self.sftpQuote(dest + "/" + testName))"]
        guard let batch = Self.writeBatchFile(lines) else {
            try? FileManager.default.removeItem(at: tmp)
            completion(false); return
        }
        let (proc, pipe) = Self.makeSftpProcess(username: username, ip: ip,
                                                batchFile: batch, connectTimeout: 3)
        Self.run(proc, pipe: pipe) { status, _ in
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: batch)
            completion(status == 0)
        }
    }

    // Manual-mode 3 s poll for ConnectionStatus: one PowerShell round-trip that
    // proves reachability and returns free space + any pending verify request.
    // The caller owns the Process (stores it so cancelInFlight() can terminate it)
    // and hops to the main actor in the completion.
    // Poll-failure stderr dedupe: 3 s cadence would flood the log while the PC is
    // off — log only when the error text changes (best-effort; benign if racy).
    private static var lastPollStderr = ""

    func makeManualPollProcess(username: String, ip: String, destination: String,
                               completion: @escaping (_ reachable: Bool, _ freeBytes: Int64?, _ verifyNonce: String?) -> Void) -> Process {
        let dest = Self.effectiveDest(destination, usingFallback: false)
        let (proc, pipe, errPipe) = Self.makePowerShellProcess(
            username: username, ip: ip,
            script: Self.manualPollScript(dest: dest), connectTimeout: 2)
        proc.terminationHandler = { p in
            // Output is two short lines — safe to drain after termination.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            guard p.terminationStatus == 0 else {
                let errStr = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !errStr.isEmpty, errStr != Self.lastPollStderr {
                    Self.lastPollStderr = errStr
                    NSLog("[V1.1/Win] manual poll failed (exit %d), stderr: %@", p.terminationStatus, errStr)
                }
                completion(false, nil, nil)
                return
            }
            Self.lastPollStderr = ""
            var free: Int64? = nil
            var nonce: String? = nil
            for line in output.components(separatedBy: .newlines) {
                if line.hasPrefix("FREE\t") {
                    free = Int64(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                }
                if line.hasPrefix("VREQ\t") {
                    let json = String(line.dropFirst(5))
                    if let d = json.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       let n = obj["nonce"] as? String, !n.isEmpty {
                        nonce = n
                    }
                }
            }
            completion(true, free, nonce)
        }
        return proc
    }
}
