import Foundation

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

enum SignalFile {
    static let start = ".sync_start"
    static let progress = ".sync_progress"
    static let complete = ".sync_complete"
    static let refused = ".sync_refused"
    static let renameRequest = ".sync_rename_request"
    static let verifyRequest = ".verify_request"
    static let verifyResult = ".verify_result"
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
