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
