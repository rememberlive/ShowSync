import SwiftUI
import AppKit
import Network

final class NetworkMonitor: ObservableObject {
    @Published var currentIP: String = "—"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.sync.networkmonitor", qos: .utility)

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let ip = Self.extractIPv4(from: path)
            DispatchQueue.main.async {
                self?.currentIP = ip ?? "—"
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    private static func extractIPv4(from path: NWPath) -> String? {
        // Walk available interfaces in path and return first non-loopback IPv4
        for iface in path.availableInterfaces {
            if iface.type == .loopback { continue }
            // Use getifaddrs to get the IP for this named interface
            if let ip = ipv4Address(for: iface.name) { return ip }
        }
        return nil
    }

    private static func ipv4Address(for interfaceName: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var ptr = Optional(first)
        while let current = ptr {
            let ifa = current.pointee
            if ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET),
               String(cString: ifa.ifa_name) == interfaceName {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count),
                            nil, 0, NI_NUMERICHOST)
                return String(cString: hostname)
            }
            ptr = ifa.ifa_next
        }
        return nil
    }
}

struct BackupView: View {
    @EnvironmentObject var store: ConfigStore
    @StateObject private var networkMonitor = NetworkMonitor()
    @State private var lastReceivedTime: Date? = nil
    @State private var showSettings = false

    private var computerName: String { Host.current().localizedName ?? "Unknown" }
    private var hostname: String { Host.current().name ?? "Unknown" }
    private var storageInfo: String { availableStorageString() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Circle()
                    .fill(lastReceivedTime != nil ? Color.green : Color.gray)
                    .frame(width: 9, height: 9)
                Text(lastReceivedTime != nil ? "Just received" : "Listening")
                    .font(.system(size: 12))
                Spacer()
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(lastReceivedTime != nil ? .green : .gray)
                    .font(.system(size: 16))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // IP — large, monospace, readable across the room
            VStack(alignment: .center, spacing: 4) {
                Text("This Mac's IP")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(networkMonitor.currentIP)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)

            Divider()

            // Info rows
            VStack(alignment: .leading, spacing: 8) {
                infoRow(label: "Computer name", value: computerName)
                infoRow(label: "Hostname", value: hostname)
                infoRow(label: "Last received",
                        value: lastReceivedTime.map { formatTime($0) } ?? "Never")
                infoRow(label: "Storage available", value: storageInfo)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

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
            SettingsView().environmentObject(store)
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
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f.string(from: date)
    }

    private func availableStorageString() -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else {
            return "Unknown"
        }
        let gb = Double(bytes) / 1_073_741_824
        return String(format: "%.1f GB free", gb)
    }
}
