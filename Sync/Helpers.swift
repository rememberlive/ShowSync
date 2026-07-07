// Copyright © 2026 Remember Chaitezvi. All rights reserved.
// Part of ShowSync — Remember Live.

import Foundation
import AppKit

// Shared Remote Login helpers — used by the Backup's launch alert and the
// external-drive setup guide. No jargon leaks to the UI from here.
enum RemoteLogin {
    // Authoritative on/off: sshd listening on localhost:22 (systemsetup
    // -getremotelogin needs admin and its output isn't parseable on macOS 13+).
    // Completion is delivered on the main queue.
    static func probe(_ completion: @escaping (Bool) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        proc.arguments = ["-z", "-w1", "localhost", "22"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { p in
            let on = p.terminationStatus == 0
            DispatchQueue.main.async { completion(on) }
        }
        DispatchQueue.global(qos: .utility).async {
            do { try proc.run() } catch { DispatchQueue.main.async { completion(false) } }
        }
    }

    // Deep-link to System Settings → General → Sharing → Remote Login (where both
    // the Remote Login switch and "Allow full disk access for remote users" live).
    // macOS 26 uses the extension scheme; the legacy pane scheme is a fallback for
    // older systems that don't resolve the extension URL.
    static func openSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Sharing-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.sharing?Services_RemoteLogin"
        ]
        for s in candidates where NSWorkspace.shared.open(URL(string: s)!) { return }
    }
}

func appVersion() -> String {
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    return "\(v) (\(b))"
}

func shortenPath(_ path: String) -> String {
    path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

func formatTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .medium
    return f.string(from: date)
}

// Friendly transfer ETA: "Almost done" / "About 40 sec left" / "About 3 min left"
func formatETA(_ seconds: Double) -> String {
    if seconds < 10 { return "Almost done" }
    if seconds < 90 {
        let s = max(10, Int((seconds / 10).rounded() * 10))
        return "About \(s) sec left"
    }
    let m = max(2, Int((seconds / 60).rounded()))
    return "About \(m) min left"
}

func formatBytes(_ bytes: Int64) -> String {
    if bytes < 1_024           { return "\(bytes) bytes" }
    if bytes < 1_048_576       { return String(format: "%.1f KB", Double(bytes) / 1_024) }
    if bytes < 1_073_741_824   { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
    return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
}

func shellEscapeForDoubleQuotes(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "$", with: "\\$")
        .replacingOccurrences(of: "`", with: "\\`")
}

// Render a remote path for use INSIDE a double-quoted segment of an ssh
// command. A leading "~/" is rewritten to "$HOME/" — tilde does NOT expand
// inside double quotes but $HOME does — so fallback-form paths ("~/Sync")
// actually land in the remote home folder instead of silently failing.
// The $HOME token must be emitted here, after escaping the remainder:
// shellEscapeForDoubleQuotes would escape its "$".
func remoteShellPath(_ path: String) -> String {
    if path == "~" { return "$HOME" }
    if path.hasPrefix("~/") {
        return "$HOME/" + shellEscapeForDoubleQuotes(String(path.dropFirst(2)))
    }
    return shellEscapeForDoubleQuotes(path)
}

// rsync sends its remote path through the remote login shell UNQUOTED when
// the local binary is openrsync or rsync < 3.2.4 — spaces and shell specials
// must be backslash-escaped or the remote side splits the argument. rsync
// >= 3.2.4 protects args itself; pre-escaping there would double-escape.
// Detected once per binary path and cached (main-thread callers only).
private var rsyncEscapeCache: [String: Bool] = [:]

func rsyncNeedsRemoteEscaping(_ rsyncPath: String) -> Bool {
    if let cached = rsyncEscapeCache[rsyncPath] { return cached }
    var needsEscaping = true   // safe default: openrsync / rsync 2.x
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: rsyncPath)
    proc.arguments = ["--version"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let banner = String(data: data, encoding: .utf8) ?? ""
        if !banner.lowercased().contains("openrsync"),
           let match = banner.range(of: #"version\s+(\d+)\.(\d+)\.(\d+)"#, options: .regularExpression) {
            let nums = banner[match].components(separatedBy: CharacterSet.decimalDigits.inverted)
                .filter { !$0.isEmpty }.compactMap { Int($0) }
            if nums.count >= 3,
               nums[0] > 3 || (nums[0] == 3 && (nums[1] > 2 || (nums[1] == 2 && nums[2] >= 4))) {
                needsEscaping = false  // GNU rsync with built-in arg protection
            }
        }
    } catch {
        // Couldn't interrogate the binary — keep the safe default.
    }
    rsyncEscapeCache[rsyncPath] = needsEscaping
    return needsEscaping
}

// Escape a remote rsync destination path for the remote shell. Leaves
// [A-Za-z0-9 / . _ ~ -] untouched — a leading "~/" must keep expanding —
// and backslash-escapes everything else (spaces, quotes, $, parens, …).
func rsyncEscapedRemotePath(_ path: String, rsyncPath: String) -> String {
    guard rsyncNeedsRemoteEscaping(rsyncPath) else { return path }
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._~-"))
    var out = ""
    for scalar in path.unicodeScalars {
        if safe.contains(scalar) {
            out.unicodeScalars.append(scalar)
        } else {
            out += "\\" + String(scalar)
        }
    }
    return out
}

enum SignalFile {
    static let start = ".sync_start"
    static let progress = ".sync_progress"
    static let complete = ".sync_complete"
    static let refused = ".sync_refused"
    static let renameRequest = ".sync_rename_request"
    static let unpairRequest = ".sync_unpair_request"
    static let verifyRequest = ".verify_request"
    static let verifyResult = ".verify_result"
    // Main → Backup relay: the Main writes this to an external destination the
    // instant its authoritative readiness probe transitions to ready, so the
    // Backup's setup card can flip to ✓ without waiting for a full sync. Reuses
    // the existing signal-file poll channel — no new listener/protocol.
    static let externalReady = ".external_ready"
}

// Shared rsync exclusions — the single source of comparison criteria for sync,
// the pre-transfer preview, the version dry-run, and verify. All four must compare
// the same file set, or verify can flag noise sync never promised to copy
// (e.g. .DS_Store rewritten by Finder between sync and verify).
enum RsyncExclusions {
    static let patterns: [String] = [
        "*~sync-v~*",   // inline version files
        ".DS_Store",    // Finder metadata — churns whenever the user browses the folder
        // Signal files live in the destination, so a push-direction rsync never
        // compares them — excluded defensively in case one ever lands in a source.
        SignalFile.start,
        SignalFile.progress,
        SignalFile.complete,
        SignalFile.refused,
        SignalFile.renameRequest,
        SignalFile.unpairRequest,
        SignalFile.verifyRequest,
        SignalFile.verifyResult,
    ]
    static var args: [String] { patterns.map { "--exclude=\($0)" } }
}

// MARK: - Trust Foundation Types (Layer 1)

struct DeviceIdentity: Codable {
    let deviceId: String
    var deviceName: String
    let createdAt: Date
}

struct TrustedPeer: Codable, Identifiable {
    let id: UUID
    let peerDeviceId: String
    let peerName: String
    let peerPublicKey: String
    let peerFingerprint: String
    let role: PeerRole
    let direction: TrustDirection
    let pairedAt: Date
    var lastSeen: Date?
    var pinnedHostKey: String?
}

enum PeerRole: String, Codable {
    case backup
    case main
    case relay
}

enum TrustDirection: String, Codable {
    case outbound
    case inbound
    case both
}

struct TrustEvent: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let eventType: TrustEventType
    let peerDeviceId: String
    let peerName: String
    let peerFingerprint: String
    let details: String?
}

enum TrustEventType: String, Codable {
    case paired
    case unpaired
    case keyChanged
    case connectionRefused
    case pairingDeclined
}

func getSSHFingerprint() -> String? {
    let pubKeyPath = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/id_ed25519.pub")
    guard FileManager.default.fileExists(atPath: pubKeyPath) else { return nil }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    proc.arguments = ["-lf", pubKeyPath]

    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice

    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        return nil
    }

    guard proc.terminationStatus == 0 else { return nil }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }

    let components = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    guard components.count >= 2 else { return nil }

    let fingerprint = String(components[1])
    guard fingerprint.hasPrefix("SHA256:") else { return nil }

    return fingerprint
}

// MARK: - Authorized Keys Management (Layer 2a)

/// Appends a public key to ~/.ssh/authorized_keys safely.
/// Creates ~/.ssh (0700) and authorized_keys (0600) if missing.
/// IDEMPOTENT: if pubkey already present, returns true without appending.
/// APPEND-ONLY: never truncates or overwrites existing keys.
/// Returns false on any failure (caller should fall back to password wizard).
func appendPublicKeyToAuthorizedKeys(_ pubkey: String, comment: String) -> Bool {
    let fm = FileManager.default
    let home = NSHomeDirectory()
    let sshDir = (home as NSString).appendingPathComponent(".ssh")
    let authKeysPath = (sshDir as NSString).appendingPathComponent("authorized_keys")

    // 1. Create ~/.ssh if missing (0700)
    if !fm.fileExists(atPath: sshDir) {
        do {
            try fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true, attributes: nil)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir)
        } catch {
            NSLog("[Sync] Failed to create ~/.ssh: %@", error.localizedDescription)
            return false
        }
    }

    // 2. Trim and guard empty pubkey
    let trimmedKey = pubkey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else {
        NSLog("[Sync] Empty pubkey provided, aborting append")
        return false
    }

    // 3. Build the full line with comment
    let keyLine = "\(trimmedKey) \(comment)"

    // 4. Check if key already exists (IDEMPOTENT)
    if fm.fileExists(atPath: authKeysPath) {
        do {
            let existing = try String(contentsOfFile: authKeysPath, encoding: .utf8)
            if existing.contains(trimmedKey) {
                NSLog("[Sync] Key already in authorized_keys, skipping append")
                return true
            }
        } catch {
            NSLog("[Sync] Could not read authorized_keys: %@", error.localizedDescription)
            return false
        }
    }

    // 5. APPEND via read -> append -> atomic write
    if fm.fileExists(atPath: authKeysPath) {
        do {
            var contents = try String(contentsOfFile: authKeysPath, encoding: .utf8)
            if !contents.isEmpty && !contents.hasSuffix("\n") {
                contents += "\n"
            }
            contents += keyLine + "\n"
            try contents.write(toFile: authKeysPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authKeysPath)
        } catch {
            NSLog("[Sync] Failed to append to authorized_keys: %@", error.localizedDescription)
            return false
        }
    } else {
        do {
            try (keyLine + "\n").write(toFile: authKeysPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authKeysPath)
        } catch {
            NSLog("[Sync] Failed to create authorized_keys: %@", error.localizedDescription)
            return false
        }
    }

    NSLog("[Sync] Successfully appended key to authorized_keys")
    return true
}

/// Removes a public key from ~/.ssh/authorized_keys safely.
/// Filters out lines containing the exact key bytes, preserves all others.
/// Returns true if removed or wasn't present; false on file error.
func removePublicKeyFromAuthorizedKeys(_ pubkey: String) -> Bool {
    let fm = FileManager.default
    let home = NSHomeDirectory()
    let authKeysPath = ((home as NSString).appendingPathComponent(".ssh") as NSString)
        .appendingPathComponent("authorized_keys")

    guard fm.fileExists(atPath: authKeysPath) else {
        return true
    }

    let trimmedKey = pubkey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else {
        return true
    }

    do {
        let contents = try String(contentsOfFile: authKeysPath, encoding: .utf8)
        let lines = contents.components(separatedBy: "\n")
        let filteredLines = lines.filter { line in
            !line.contains(trimmedKey)
        }

        if filteredLines.count == lines.count {
            NSLog("[Sync] Key not found in authorized_keys, nothing to remove")
            return true
        }

        let newContents = filteredLines.joined(separator: "\n")
        try newContents.write(toFile: authKeysPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authKeysPath)

        NSLog("[Sync] Removed key from authorized_keys")
        return true
    } catch {
        NSLog("[Sync] Failed to modify authorized_keys: %@", error.localizedDescription)
        return false
    }
}
