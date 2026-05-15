import SwiftUI
import AppKit
import UserNotifications

enum SyncStatus {
    case ready, syncing, error(String)

    var color: Color {
        switch self {
        case .ready: return .gray
        case .syncing: return .yellow
        case .error: return .red
        }
    }

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .syncing: return "Syncing…"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

final class SyncEngine: ObservableObject {
    @Published var status: SyncStatus = .ready
    @Published var lastSyncTime: Date?
    @Published var dryRun: Bool = false

    private var task: Process?

    deinit {
        ConfigStore.shared.isSyncing = false
        task?.terminate()
    }

    func sync(config: Config) {
        guard config.isReadyToSync else { return }
        status = .syncing
        ConfigStore.shared.isSyncing = true

        let source = config.sourceFolder.hasSuffix("/") ? config.sourceFolder : config.sourceFolder + "/"
        let dest = "\(config.username)@\(config.destinationIP):\(config.destinationFolder)"

        var args = ["-av"]
        if dryRun { args.append("-n") }
        args.append(source)
        args.append(dest)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                ConfigStore.shared.isSyncing = false
                if p.terminationStatus == 0 {
                    self?.status = .ready
                    self?.lastSyncTime = Date()
                    if ConfigStore.shared.config.notifyOnComplete && !(self?.dryRun ?? false) {
                        self?.notify(title: "Sync complete",
                                     body: "Files synced to \(config.destinationIP)")
                    }
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: data, encoding: .utf8)?
                        .components(separatedBy: .newlines)
                        .filter { !$0.isEmpty }
                        .last ?? "Unknown error"
                    self?.status = .error(msg)
                }
            }
        }

        do {
            try proc.run()
            task = proc
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

struct MainView: View {
    @EnvironmentObject var store: ConfigStore
    @StateObject private var engine = SyncEngine()
    @State private var showSettings = false

    private var statusColor: Color { engine.status.color }
    private var canSync: Bool { store.config.isReadyToSync }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(engine.status.label)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "arrow.up.circle")
                    .foregroundColor(statusColor)
                    .font(.system(size: 16))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Info rows
            VStack(alignment: .leading, spacing: 8) {
                infoRow(label: "Destination IP",
                        value: store.config.destinationIP.isEmpty ? "Not set" : store.config.destinationIP)

                infoRow(label: "Last sync",
                        value: engine.lastSyncTime.map { formatTime($0) } ?? "Never")

                if case .error(let msg) = engine.status {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Actions
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: { engine.sync(config: store.config) }) {
                        Label("Sync Now", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSync || engine.status == .syncing)
                    .help(canSync ? "Run rsync now" : "Set source, destination, and IP first")
                }

                Toggle(isOn: $engine.dryRun) {
                    Label("Dry Run", systemImage: "eye")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Footer
            HStack {
                Button("Settings…") { showSettings = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 300)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(store)
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.primary)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f.string(from: date)
    }
}

// Needed for == comparison on SyncStatus in .disabled
extension SyncStatus: Equatable {
    static func == (lhs: SyncStatus, rhs: SyncStatus) -> Bool {
        switch (lhs, rhs) {
        case (.ready, .ready), (.syncing, .syncing): return true
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}
