import SwiftUI
import AppKit
import Combine

// MARK: - App entry point

@main
struct SyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No windows — the entire UI lives in the NSPopover attached to the status item.
        // Settings scene is declared so SwiftUI does not synthesise a default window.
        Settings { EmptyView() }
    }
}

// MARK: - Popover root view

// Single navigation root — switches main/backup/settings in-panel (no separate windows)
struct PopoverRootView: View {
    @EnvironmentObject var store: ConfigStore
    @State private var showSettings = false

    var body: some View {
        if showSettings {
            SettingsView(onBack: { showSettings = false })
        } else if store.config.role == "backup" {
            BackupView(onSettingsTapped: { showSettings = true })
        } else {
            MainView(onSettingsTapped: { showSettings = true })
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    var statusItem: NSStatusItem!
    var popover = NSPopover()
    private var fallbackAnchorWindow: NSWindow?

    var quitConfirmed = false

    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        if ConfigStore.shared.config.role == "backup" {
            cleanupStaleSignalFiles()
            ensureSyncFolder()
            if ConfigStore.shared.config.username.isEmpty {
                ConfigStore.shared.config.username = NSUserName()
            }
        }

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // contentViewController assigned at init, not lazily
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView().environmentObject(ConfigStore.shared)
        )
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Set initial icon state before subscribing so the first icon render is correct.
        let store = ConfigStore.shared
        if store.config.role != "backup" {
            store.iconState = store.config.isReadyToSync ? .idle : .notConfigured
        }
        // Backup initial state is .idle; NetworkMonitor will correct it on first path update.

        if store.config.role == "backup" {
            checkRemoteLoginIfNeeded()
        }

        // Single Combine subscription — every iconState change updates the status item icon.
        store.$iconState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.applyIconState(state)
            }
            .store(in: &cancellables)

        updateBonjourAdvertiser()
        updateBonjourBrowser()
        startAutoSyncIfNeeded()
        startPushSyncIfNeeded()
        startReceiveMonitorIfNeeded()
        startGlobalHotkeyIfNeeded()
        applyAppPresence()
    }

    // Applies the user's app presence preference (Menu Bar only or Menu Bar & Dock).
    // Called on launch and live when the setting changes.
    func applyAppPresence() {
        let presence = ConfigStore.shared.config.appPresence
        if presence == "both" {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // Registers the global sync hotkey (⌃⌥⌘S) for Main role if enabled.
    func startGlobalHotkeyIfNeeded() {
        let cfg = ConfigStore.shared.config
        if cfg.role == "main" && cfg.globalHotkeyEnabled {
            GlobalHotkey.shared.register()
        }
    }

    // Starts Auto Sync timer at app launch for Main role with Auto Sync enabled.
    func startAutoSyncIfNeeded() {
        let cfg = ConfigStore.shared.config
        if cfg.role == "main" && cfg.autoSyncEnabled {
            SyncEngine.shared.startAutoSync()
        }
    }

    // Starts FSEventsWatcher at app launch for Main role with Push Sync enabled.
    func startPushSyncIfNeeded() {
        let cfg = ConfigStore.shared.config
        // Wire up callbacks once (idempotent)
        if FSEventsWatcher.shared.onDebounceComplete == nil {
            FSEventsWatcher.shared.onDebounceComplete = {
                SyncEngine.shared.triggerPushSync()
            }
            FSEventsWatcher.shared.onDebounceStart = { date in
                SyncEngine.shared.nextPushSyncDate = date
            }
        }
        if cfg.role == "main" && cfg.pushSyncEnabled && !cfg.sourceFolder.isEmpty {
            FSEventsWatcher.shared.start(path: cfg.sourceFolder, debounceSeconds: cfg.pushSyncDebounce)
        }
    }

    // Starts ReceiveMonitor at app launch for Backup role.
    func startReceiveMonitorIfNeeded() {
        if ConfigStore.shared.config.role == "backup" {
            ReceiveMonitor.shared.startMonitoring()
        }
    }

    // Starts/stops the Backup-role Bonjour advertiser based on current role + discovery mode.
    // Safe to call repeatedly — BonjourAdvertiser.start() is idempotent.
    func updateBonjourAdvertiser() {
        let cfg = ConfigStore.shared.config
        if cfg.role == "backup" && cfg.discoveryMode == "automatic" {
            BonjourAdvertiser.shared.start()
            // Layer 2b: Also start listening for pairing requests
            BonjourPairingService.shared.startListening()
        } else {
            BonjourAdvertiser.shared.stop()
            BonjourPairingService.shared.stopListening()
        }
    }

    // Starts/stops the Main-role Bonjour browser based on current role + discovery mode.
    func updateBonjourBrowser() {
        let cfg = ConfigStore.shared.config
        if cfg.role == "main" && cfg.discoveryMode == "automatic" {
            BonjourBrowser.shared.start()
        } else {
            BonjourBrowser.shared.stop()
        }
    }

    private func cleanupStaleSignalFiles() {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Sync")
        for name in [SignalFile.start, SignalFile.progress, SignalFile.complete] {
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
    }

    // Called from SettingsView after a role switch — SwiftUI view updates reactively;
    // this closes the popover, resets icon state for the new role, and re-renders the icon.
    func ensureSyncFolder() {
        let fm = FileManager.default
        let defaultPath = fm.homeDirectoryForCurrentUser.appendingPathComponent("Sync")
        let configPath = ConfigStore.shared.config.destinationFolder
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o755]

        // If custom folder is set and valid, use it (don't create ~/Sync)
        if !configPath.isEmpty && configPath != defaultPath.path &&
           fm.fileExists(atPath: configPath) && fm.isWritableFile(atPath: configPath) {
            return
        }
        // Otherwise ensure ~/Sync exists
        if !fm.fileExists(atPath: defaultPath.path) {
            do {
                try fm.createDirectory(at: defaultPath, withIntermediateDirectories: true, attributes: attrs)
                NSLog("[Sync] Created ~/Sync")
            } catch {
                NSLog("[Sync] Failed to create ~/Sync: %@", error.localizedDescription)
            }
        }
        do {
            try fm.setAttributes(attrs, ofItemAtPath: defaultPath.path)
        } catch {
            NSLog("[Sync] Failed to set permissions on ~/Sync: %@", error.localizedDescription)
        }
        if configPath.isEmpty {
            ConfigStore.shared.config.destinationFolder = defaultPath.path
        }
        checkSyncFolderWritability()
    }

    func checkSyncFolderWritability() {
        guard ConfigStore.shared.config.role == "backup" else { return }
        let syncFolder = URL(fileURLWithPath: ConfigStore.shared.config.destinationFolder)
        DispatchQueue.global(qos: .utility).async {
            let testFile = syncFolder.appendingPathComponent(".syncwritetest")
            let writable = FileManager.default.createFile(atPath: testFile.path, contents: Data())
            if writable { try? FileManager.default.removeItem(at: testFile) }
            if !writable {
                NSLog("[Sync] ~/Sync writable check failed")
            }
        }
    }

    func rebuildPopover() {
        if popover.isShown { popover.performClose(nil) }
        let store = ConfigStore.shared
        store.iconState = store.config.role == "backup"
            ? .idle
            : (store.config.isReadyToSync ? .idle : .notConfigured)
        updateBonjourAdvertiser()
        updateBonjourBrowser()
    }

    func checkRemoteLoginIfNeeded() {
        guard ConfigStore.shared.config.role == "backup" else { return }
        // systemsetup -getremotelogin requires admin and outputs an access-denied message
        // on macOS 13+, making string parsing unreliable. A TCP probe of localhost:22 is
        // authoritative: exit 0 = sshd is listening (Remote Login ON), else OFF.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        proc.arguments     = ["-z", "-w1", "localhost", "22"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] p in
            let isOn = p.terminationStatus == 0
            NSLog("[Sync] Remote Login check result: %@", isOn ? "ON" : "OFF")
            if !isOn {
                DispatchQueue.main.async { self?.showRemoteLoginAlert() }
            }
        }
        DispatchQueue.global(qos: .utility).async { try? proc.run() }
    }

    private func showRemoteLoginAlert() {
        let alert = NSAlert()
        alert.messageText     = "Remote Login Required"
        alert.informativeText = "Sync needs Remote Login enabled on this Mac to receive files. Open System Settings to enable it."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.sharing?Services_RemoteLogin")!)
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // In an .accessory-policy app the popover window is not automatically made key,
            // so SwiftUI controls (Toggle/checkbox) don't receive events. Force it here.
            popover.contentViewController?.view.window?.makeKey()
            // Acknowledge persistent success/error/warning icon — revert to grey on open.
            let store = ConfigStore.shared
            if store.iconState == .success || store.iconState == .error || store.iconState == .warning {
                store.iconState = store.config.role == "backup"
                    ? .idle
                    : (store.config.isReadyToSync ? .idle : .notConfigured)
            }
        }
    }

    // MARK: - Icon rendering

    private func applyIconState(_ state: SyncIconState) {
        let symbolName = ConfigStore.shared.config.role == "backup"
            ? "arrow.down.circle"
            : "arrow.up.circle"

        let color: NSColor
        switch state {
        case .idle:          color = .secondaryLabelColor
        case .notConfigured: color = .tertiaryLabelColor
        case .syncing:       color = .systemYellow
        case .receiving:     color = .systemYellow
        case .success:       color = .systemGreen
        case .warning:       color = .systemOrange
        case .error:         color = .systemRed
        }

        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return }
        let symConfig = NSImage.SymbolConfiguration(paletteColors: [color])
        guard let tinted = base.withSymbolConfiguration(symConfig) else { return }
        tinted.isTemplate = false
        statusItem.button?.image = tinted
    }

    // MARK: - Dock click handling

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !popover.isShown {
            if let button = statusItem.button, button.window != nil {
                togglePopover()
            } else {
                showPopoverScreenAnchored()
            }
        }
        return false
    }

    private func showPopoverScreenAnchored() {
        guard let screen = NSScreen.main else { return }

        let anchorWindow: NSWindow
        if let existing = fallbackAnchorWindow {
            anchorWindow = existing
        } else {
            anchorWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            anchorWindow.isOpaque = false
            anchorWindow.backgroundColor = .clear
            anchorWindow.level = .popUpMenu
            anchorWindow.collectionBehavior = [.canJoinAllSpaces, .stationary]
            anchorWindow.ignoresMouseEvents = true
            fallbackAnchorWindow = anchorWindow
        }

        let screenFrame = screen.frame
        let menuBarHeight: CGFloat = 24
        let anchorX = screenFrame.midX
        let anchorY = screenFrame.maxY - menuBarHeight
        anchorWindow.setFrameOrigin(NSPoint(x: anchorX, y: anchorY))
        anchorWindow.orderFront(nil)

        if let anchorView = anchorWindow.contentView {
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()

            let store = ConfigStore.shared
            if store.iconState == .success || store.iconState == .error || store.iconState == .warning {
                store.iconState = store.config.role == "backup"
                    ? .idle
                    : (store.config.isReadyToSync ? .idle : .notConfigured)
            }
        }
    }

    // MARK: - Quit protection

    // Cleanup that must happen on EVERY clean quit (Cmd+Q, Quit button, NSApp.terminate).
    // applicationShouldTerminate decides IF we quit; this fires AFTER it returns .terminateNow.
    // Active timers and child Processes are reaped by the OS at exit, so we only have to
    // clean up state that persists on disk after the process is gone — the Backup signal
    // files in ~/Sync are the only such state.
    func applicationWillTerminate(_ notification: Notification) {
        ConfigStore.shared.flushPendingSave()
        GlobalHotkey.shared.unregister()
        if ConfigStore.shared.config.role == "backup" {
            cleanupStaleSignalFiles()
        }
        BonjourAdvertiser.shared.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitConfirmed || !ConfigStore.shared.isSyncing {
            return .terminateNow
        }
        // Mid-sync Cmd+Q: open the popover (if needed) and ask the active view to
        // render the inline Quit confirmation. The user's choice is handled there.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.popover.isShown, let button = self.statusItem.button {
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                self.popover.contentViewController?.view.window?.makeKey()
            }
            ConfigStore.shared.pendingQuitConfirm = true
        }
        return .terminateCancel
    }
}
