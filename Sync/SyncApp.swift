import SwiftUI
import AppKit
import UserNotifications

@main
struct SyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // No windows — pure menu bar app
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover = NSPopover()
    var hostingController: NSHostingController<AnyView>?

    // Quit protection state
    var quitProtectionPanel: NSPanel?
    var quitConfirmed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildPopover()

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    func rebuildPopover() {
        let role = ConfigStore.shared.config.role
        let rootView: AnyView = role == "backup"
            ? AnyView(BackupView().environmentObject(ConfigStore.shared))
            : AnyView(MainView().environmentObject(ConfigStore.shared))

        popover.contentViewController = NSHostingController(rootView: rootView)
        popover.contentSize = NSSize(width: 300, height: 340)
        popover.behavior = .transient

        updateIcon()
    }

    func updateIcon() {
        let role = ConfigStore.shared.config.role
        let name = role == "backup" ? "arrow.down.circle" : "arrow.up.circle"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // If already confirmed or not syncing, quit immediately.
        if quitConfirmed || !ConfigStore.shared.isSyncing {
            return .terminateNow
        }
        // Prevent stacking panels if Cmd+Q is pressed multiple times.
        guard quitProtectionPanel == nil else { return .terminateCancel }
        showQuitProtectionPanel()
        return .terminateCancel
    }
}
