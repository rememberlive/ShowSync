import SwiftUI
import AppKit

// MARK: - Hold-to-quit panel view

struct HoldToQuitView: View {
    let onHoldComplete: () -> Void
    let onCancel: () -> Void

    @State private var progress: CGFloat = 0
    @State private var holdTimer: Timer?
    @State private var completed = false

    private let holdDuration: TimeInterval = 3.0
    private let tickInterval: TimeInterval = 1.0 / 60.0

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 5)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: tickInterval), value: progress)

                Image(systemName: "xmark.circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundColor(.secondary)
            }
            .frame(width: 64, height: 64)

            VStack(spacing: 5) {
                Text("Hold to quit…")
                    .font(.system(size: 14, weight: .semibold))
                Text("Sync is in progress")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Text("Press and hold anywhere in this panel")
                .font(.system(size: 11))
                .foregroundColor(Color.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 240)
        // Capture press-and-hold over the full panel area
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in startHold() }
                .onEnded { _ in releaseHold() }
        )
    }

    private func startHold() {
        guard holdTimer == nil, !completed else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
            progress = min(1.0, progress + CGFloat(tickInterval / holdDuration))
            if progress >= 1.0 {
                completed = true
                stopTimer()
                onHoldComplete()
            }
        }
    }

    private func stopTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func releaseHold() {
        guard !completed else { return }
        stopTimer()
        withAnimation(.easeOut(duration: 0.25)) { progress = 0 }
        onCancel()
    }
}

// MARK: - AppDelegate extension

extension AppDelegate {

    func showQuitProtectionPanel() {
        let view = HoldToQuitView(
            onHoldComplete: { [weak self] in
                self?.quitProtectionPanel?.close()
                self?.quitProtectionPanel = nil
                self?.showQuitConfirmationAlert()
            },
            onCancel: { [weak self] in
                self?.quitProtectionPanel?.close()
                self?.quitProtectionPanel = nil
            }
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 220),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.contentViewController = NSHostingController(rootView: view)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        quitProtectionPanel = panel
    }

    func showQuitConfirmationAlert() {
        let alert = NSAlert()
        alert.messageText = "Sync in progress"
        alert.informativeText = "Quitting now may leave the backup incomplete. Are you sure you want to quit?"
        // Cancel is first (default — Return key = safe action)
        alert.addButton(withTitle: "Cancel")
        // Quit Anyway is second and destructive
        alert.addButton(withTitle: "Quit Anyway")
        alert.buttons[1].hasDestructiveAction = true

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            quitConfirmed = true
            NSApp.terminate(nil)
        }
        // Cancel: quit already blocked, nothing to do
    }
}
