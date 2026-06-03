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

enum SignalFile {
    static let start = ".sync_start"
    static let progress = ".sync_progress"
    static let complete = ".sync_complete"
    static let refused = ".sync_refused"
    static let renameRequest = ".sync_rename_request"
    static let verifyRequest = ".verify_request"
    static let verifyResult = ".verify_result"
}
