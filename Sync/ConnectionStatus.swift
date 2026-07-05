// Copyright © 2026 Remember Chaitezvi. All rights reserved.
// Part of ShowSync — Remember Live.

import Foundation
import SwiftUI

// MARK: - Unified connection state

// THE single source of truth for "is the Backup reachable over SSH".
// Replaces the old ReachabilityState (MainView dot) and SSHConnectionState
// (Settings "Secure Connection" label), which were fed by two separate
// checkers and could disagree.
enum ConnectionState {
    case checking, reachable, unreachable
}

// MARK: - Shared SSH reachability checker

// Checks SSH connectivity using the same username + IP that rsync uses.
// Singleton observed by MainView (dot) and SettingsView (label + pairing gate).
// Lifecycle is ref-counted by client name: each view start()s on appear and
// stop()s on disappear/popover-close; the 3 s poll runs while at least one
// client is visible and stops completely — zero CPU — when none are.
//
// Status stays OFF ConfigStore on purpose: a 3 s poll must not re-render
// every ConfigStore observer in the app.
@MainActor
final class ConnectionStatus: ObservableObject {
    static let shared = ConnectionStatus()

    // nil = not polling (popover closed) or username/IP unset.
    @Published var state: ConnectionState? = nil

    private var clients = Set<String>()
    private var process: Process?
    private var checkID = 0
    private var timer:   Timer?
    private var lastHandledVerifyNonce: String = ""  // Dedupe for manual mode verify requests

    private init() {}

    // MARK: Lifecycle — ref-counted, idempotent per client

    func start(_ client: String) {
        let wasIdle = clients.isEmpty
        clients.insert(client)
        guard wasIdle else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.check() }
        }
    }

    func stop(_ client: String) {
        clients.remove(client)
        guard clients.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        cancelInFlight()
        // Preserve-state-on-pause: do NOT reset state here. The Main ↔ Settings
        // swap can pass through zero clients across run-loop turns; wiping the
        // established truth made Settings flash "Checking…" against a live
        // connection. State changes only on a probe result, an explicit
        // recheck(), or the empty username/IP path in check().
    }

    // Immediate re-test: destination IP/username changed, pairing finished,
    // or SSH keys were reset. Shows "Checking…" until the new result lands.
    func recheck() {
        guard !clients.isEmpty else { return }
        cancelInFlight()
        state = .checking
        check()
    }

    // MARK: Check

    private func check() {
        let username = ConfigStore.shared.config.username
        let ip       = ConfigStore.shared.config.destinationIP
        guard !username.isEmpty, !ip.isEmpty else {
            cancelInFlight()
            if state != nil { state = nil }
            return
        }
        cancelInFlight()
        // Publish .checking only before the first determination. Subsequent
        // polls update silently so the dot and the Settings pairing gate
        // don't flicker through "Checking…" every 3 s.
        if state == nil { state = .checking }

        let currentID = checkID
        let isManualMode = ConfigStore.shared.config.discoveryMode == "manual"

        // V1.1 Windows-target path — UNTESTED against live Windows Backup as of this commit (Windows sshd pending).
        // Windows sshd has no POSIX cat/$HOME, so the manual-mode cat pipeline below would read
        // a live Windows Backup as unreachable. Gated early-exit: reachability + free space +
        // verify request come from one PowerShell call built by the transport module. The
        // no-flag path falls through to the existing code, untouched.
        if isManualMode && ConfigStore.shared.config.backupPlatform == "windows" {
            let winProc = WindowsTransport.shared.makeManualPollProcess(
                username: username,
                ip: ip,
                destination: ConfigStore.shared.config.backupDestination
            ) { [weak self] reachable, freeBytes, verifyNonce in
                Task { @MainActor [weak self] in
                    guard let self, self.checkID == currentID else { return }
                    self.process = nil
                    guard reachable else {
                        self.publish(.unreachable)
                        return
                    }
                    self.publish(.reachable)
                    self.markKeysConfigured()
                    if let freeBytes, SyncEngine.shared.manualModeFreeSpace != freeBytes {
                        SyncEngine.shared.manualModeFreeSpace = freeBytes
                    }
                    if let nonce = verifyNonce, !nonce.isEmpty, nonce != self.lastHandledVerifyNonce {
                        self.lastHandledVerifyNonce = nonce
                        NSLog("[ConnectionStatus] Manual mode verify request (Windows): nonce=%@", nonce)
                        SyncEngine.shared.triggerRemoteVerify()
                    }
                }
            }
            process = winProc
            DispatchQueue.global(qos: .utility).async { try? winProc.run() }
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        if isManualMode {
            // Manual mode: read config + free space + check for verify request in one call
            let cmd = "cat \"$HOME/Library/Application Support/Sync/config_backup.json\" 2>/dev/null || echo '{}'; echo '---DF---'; df -k ~ 2>/dev/null | awk 'NR==2 {print $4}'; echo '---VERIFY---'; cat ~/Sync/\(SignalFile.verifyRequest) 2>/dev/null || echo ''"
            var manualArgs = ["-o", "ConnectTimeout=2", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no"]
            if let bindIP = NetworkInterfaceManager.shared.getEffectiveIP(),
               !ConfigStore.shared.config.preferredInterfaceMAC.isEmpty {
                manualArgs.insert(contentsOf: ["-b", bindIP], at: 0)
            }
            manualArgs.append(contentsOf: ["--", "\(username)@\(ip)", cmd])
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
                        self.publish(.unreachable)
                        return
                    }

                    self.publish(.reachable)
                    self.markKeysConfigured()

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
                        // Write-on-change: this runs every 3 s — unguarded writes would
                        // re-render every observer and schedule a config save per tick.
                        if ConfigStore.shared.config.backupDestination != dest {
                            ConfigStore.shared.config.backupDestination = dest
                        }
                        if SyncEngine.shared.usingFallback != isFallback {
                            SyncEngine.shared.usingFallback = isFallback
                        }
                    }
                    // On parse failure: keep last-known values (no else branch needed)
                    // Parse free space (only update if parse succeeds)
                    if parts.count > 1 {
                        let dfAndVerify = parts[1].components(separatedBy: "---VERIFY---")
                        if let kbStr = dfAndVerify[0].trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first,
                           let kb = Int64(kbStr) {
                            if SyncEngine.shared.manualModeFreeSpace != kb * 1024 {
                                SyncEngine.shared.manualModeFreeSpace = kb * 1024
                            }
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
                                NSLog("[ConnectionStatus] Manual mode verify request: nonce=%@", nonce)
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
               !ConfigStore.shared.config.preferredInterfaceMAC.isEmpty {
                autoArgs.insert(contentsOf: ["-b", bindIP], at: 0)
            }
            autoArgs.append(contentsOf: ["--", "\(username)@\(ip)", "exit"])
            proc.arguments = autoArgs
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            proc.terminationHandler = { [weak self] p in
                Task { @MainActor [weak self] in
                    guard let self, self.checkID == currentID else { return }
                    if p.terminationStatus == 0 {
                        self.publish(.reachable)
                        self.markKeysConfigured()
                    } else {
                        self.publish(.unreachable)
                    }
                    self.process = nil
                }
            }
            process = proc
            DispatchQueue.global(qos: .utility).async { try? proc.run() }
        }
    }

    // Assign only on change so observers don't re-render on every 3 s poll.
    private func publish(_ new: ConnectionState) {
        if state != new { state = new }
    }

    // Folded in from the old runLiveSSHTest: a successful SSH round-trip
    // proves key auth works. Guarded so the 3 s poll doesn't churn ConfigStore.
    private func markKeysConfigured() {
        if !ConfigStore.shared.config.sshKeysConfigured {
            ConfigStore.shared.config.sshKeysConfigured = true
        }
    }

    private func cancelInFlight() {
        checkID += 1
        if let proc = process, proc.isRunning { proc.terminate() }
        process = nil
    }
}
