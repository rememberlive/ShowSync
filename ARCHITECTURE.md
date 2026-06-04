# ShowSync Architecture

This document maps the complete codebase so future changes don't break working logic. It covers every subsystem, state property, shared path, and threading concern.

---

## 1. Overview

**App type**: macOS menu-bar utility (LSUIElement=YES — no Dock icon by default)  
**Target OS**: macOS 13.0+  
**Frameworks**: SwiftUI, AppKit, Network, CoreServices (FSEvents), Carbon (GlobalHotkey)  
**Process model**: Single-process, dual-role (user chooses MAIN or BACKUP at runtime)

### Roles

| Role | Purpose | Key Behaviors |
|------|---------|---------------|
| **MAIN** | Sends files to Backup via rsync-over-SSH | Browses Bonjour for Backups, initiates sync, writes signal files |
| **BACKUP** | Receives files, monitors ~/Sync | Advertises via Bonjour, watches signal files, validates storage |

### Design Invariants

1. **Calm Technology**: Idle = zero CPU. All activity is event-driven (FSEvents, Bonjour callbacks, timers).
2. **Additive-only sync**: rsync with no `--delete`. Files are never removed from Backup.
3. **Honest status**: Icon/UI always reflects true state. Unknown ≠ 0. Fallback is disclosed.
4. **Backup as source of truth**: TXT record advertises Backup's actual destination and free space.
5. **Fail safe**: On any error, abort cleanly. Never corrupt user data.

---

## 2. File Inventory

| File | Lines | Responsibility |
|------|-------|----------------|
| `main.swift` | 2 | Entry point stub (actual entry is `@main SyncApp`) |
| `SyncApp.swift` | 403 | App entry, `AppDelegate`, popover lifecycle, icon rendering, quit protection |
| `Config.swift` | 719 | `ConfigStore` singleton, `Config` struct, persistence, transfer log, trust foundation |
| `Helpers.swift` | 244 | Utility functions, `SignalFile` enum, trust types (`DeviceIdentity`, `TrustedPeer`), `authorized_keys` management |
| `BonjourDiscovery.swift` | 1320 | `BonjourAdvertiser`, `BonjourBrowser`, `BonjourPairingService`, TXT record handling |
| `MainView.swift` | 2553 | `SyncEngine` (rsync orchestration), Main-role UI, verify, version history, auto/push sync |
| `BackupView.swift` | 1131 | `ReceiveMonitor`, `NetworkMonitor`, `StorageMonitor`, `NetworkInterfaceManager`, Backup-role UI |
| `SettingsView.swift` | 1789 | Settings UI for both roles, SSH connection test, discovery mode, rename flow |
| `SSHKeyWizard.swift` | 248 | Password-based SSH key setup wizard, pairing confirm dialog |
| `FSEventsWatcher.swift` | 142 | Push Sync file-change detection via CoreServices FSEvents |
| `GlobalHotkey.swift` | 87 | ⌃⌥⌘S global hotkey registration via Carbon |
| `QuitProtection.swift` | 12 | Legacy stub (quit protection now inline in views) |

---

## 3. Subsystems

### 3a. Bonjour Discovery

**Files**: `BonjourDiscovery.swift`

#### BonjourAdvertiser (Backup role)
- **Singleton**: `BonjourAdvertiser.shared` (line 33)
- **Service type**: `_rememberlivesync._tcp` (line 21)
- **Thread**: Dedicated `Thread` named `com.rememberlive.sync.bonjour-advertiser` (line 54-68)
- **RunLoop**: `bonjourRunLoop` with `NSMachPort` keepalive (line 61)
- **TXT record fields**: `free`, `dest`, `effectiveDest`, `verifyReq`, `backupId`, `backupFP`, `pairAck`, `pairNack`, `pairAckNonce`, `pairNackNonce`
- **Key methods**: `start()` (line 72), `stop()` (line 141), `updateTXTRecord()` (line 151), `setPairAck()` (line 200), `setPairNack()` (line 218)

#### BonjourBrowser (Main role)
- **Singleton**: `BonjourBrowser.shared` (line 331)
- **Thread**: Dedicated `Thread` named `com.rememberlive.sync.bonjour-browser` (line 351-365)
- **RunLoop**: `bonjourRunLoop` with `NSMachPort` keepalive (line 358)
- **Key methods**: `start()` (line 386), `stop()` (line 401), `restart()` (line 405)
- **Auto-reconnect**: Lines 574-599 — matches by name or IP, updates config
- **TXT update handler**: `netService(_:didUpdateTXTRecord:)` (line 614-719) — updates `services`, config, triggers remote verify

#### BonjourPairingService (Layer 2b)
- **Singleton**: `BonjourPairingService.shared` (line 868)
- **Service type**: `_syncpair._tcp` (line 22)
- **Thread**: Dedicated `Thread` named `com.rememberlive.sync.pairing` (line 880-892)
- **Main-role**: `startPairing()` (line 960) — generates key if missing, advertises with pubkey/fingerprint/nonce, 45s timeout
- **Backup-role**: `startListening()` (line 1144), `stopListening()` (line 1153) — browses, shows confirm dialog, writes to `authorized_keys`
- **Nonce validation**: `currentNonce` (line 896), `handledNonces` (line 904)
- **Publish mode**: Uses `publish(options: .listenForConnections)` (line 1068) so NetService owns a real listening socket and fully announces on the network. Incoming connections are accepted and immediately closed (line 1247) since pairing data rides TXT records, not this socket.

### 3b. Pairing Handshake / Trust Foundation

**Files**: `BonjourDiscovery.swift` (Layer 2b), `Helpers.swift` (types + authorized_keys), `Config.swift` (persistence), `SSHKeyWizard.swift` (dialogs)

#### Flow (Main → Backup):
1. Main clicks "Pair Automatically" → `BonjourPairingService.startPairing()` (line 960)
2. Ensures SSH key exists via `ensureSSHKeyExists()` (line 914-953)
3. Advertises `_syncpair._tcp` with: `mainId`, `mainName`, `mainPubKey`, `mainFP`, `targetBackupId`, `nonce`
4. Backup's `BonjourPairingService` browses, resolves, validates `targetBackupId` matches self
5. Backup dispatches to main thread (line 1297), then shows `showPairingConfirmDialog()` (SSHKeyWizard.swift line 225)
6. If trusted: `ConfigStore.markPeerAsTrustedOnBackup()` (Config.swift line 465) → writes to `~/.ssh/authorized_keys`
7. Backup sets `pairAck` in TXT via `BonjourAdvertiser.setPairAck()` (line 200)
8. Main's browser detects ack, calls `handleAck()` (line 1048), marks paired

#### Key Files:
- `~/Library/Application Support/Sync/identity.json` — device UUID + name
- `~/Library/Application Support/Sync/trusted_peers.json` — paired devices
- `~/Library/Application Support/Sync/trust_log.json` — audit trail
- `~/.ssh/authorized_keys` — Main's pubkey written by Backup

### 3c. rsync-over-SSH Sync Engine

**File**: `MainView.swift`, class `SyncEngine` (line 98-1580)

#### Entry point
- `sync(config:isAuto:isPush:)` (line 149) — single entry for manual, auto, push

#### Phases
1. **Preparing**: Write-test remote folder, fallback to ~/Sync if unwritable
2. **Syncing**: Launch rsync with `-av --stats --exclude=*~sync-v~*`
3. **Signal files**: `.sync_start`, `.sync_progress`, `.sync_complete`, `.sync_refused`
4. **Progress polling**: SSH `du -sk` every 1s via `startDuPolling()` (line 929)

#### rsync arguments
- Source: `config.sourceFolder` with trailing `/`
- Dest: `username@ip:remotePath/`
- SSH bind: `-e "ssh -b <bindIP>"` if interface selected
- Version exclusion: `--exclude=*~sync-v~*`

#### SSH options (all calls)
- `BatchMode=yes` — no password prompts
- `ConnectTimeout=2-5` — fast failure
- `StrictHostKeyChecking=no` — Layer 3 will pin host keys

### 3d. Version History / Prune

**File**: `MainView.swift`, lines 1350-1580

- **Inline versioning**: Before sync, dry-run identifies changed files, copies to `filename~sync-v~TIMESTAMP.ext`
- **Prune**: After sync, `pruneVersions()` removes oldest versions keeping `maxVersionCount`
- **Timeout guards**: Master 60s, dry-run 30s, cp 45s — backup always proceeds

### 3e. ConfigStore and Persistence

**File**: `Config.swift`

#### Storage locations (`~/Library/Application Support/Sync/`)
| File | Purpose |
|------|---------|
| `role.json` | Current role ("main" or "backup") |
| `config_main.json` | Main-role settings |
| `config_backup.json` | Backup-role settings |
| `config_shared.json` | Cross-role settings (appPresence) |
| `transfer_log.json` | Last 100 sync entries |
| `identity.json` | Device UUID + name (Layer 1) |
| `trusted_peers.json` | Paired devices (Layer 1) |
| `trust_log.json` | Trust audit trail (Layer 1) |

#### Save mechanism
- Debounced: `scheduleSave()` (line 197) — 0.1s delay, cancellable
- `flushPendingSave()` (line 204) — immediate, used before role switch and quit

### 3f. SwiftUI UI Layer

#### View hierarchy
```
PopoverRootView (SyncApp.swift:21)
├── MainView (Main role)
├── BackupView (Backup role)
└── SettingsView (both roles, toggled via onSettingsTapped)
```

#### Popover lifecycle
- `AppDelegate.togglePopover()` (line 273) — show/hide
- `popover.behavior = .transient` — auto-close on click outside
- `popover.animates = false` — instant transitions

#### Startup sequence (applicationDidFinishLaunching, lines 49-102)
Order matters — destination must be validated before TXT is published:
1. `startReceiveMonitorIfNeeded()` — validates destination, sets `usingFallback` (line 96)
2. `updateBonjourAdvertiser()` — publishes TXT with correct `effectiveDestination` (line 97)
3. `updateBonjourBrowser()` — starts browsing for Backups (line 98)
4. `startAutoSyncIfNeeded()`, `startPushSyncIfNeeded()` — timers (lines 99-100)
5. `startGlobalHotkeyIfNeeded()`, `applyAppPresence()` — UI (lines 101-102)

### 3g. SSH Key + Host Handling

**Files**: `SSHKeyWizard.swift`, `BonjourDiscovery.swift` (ensureSSHKeyExists), `Helpers.swift`

#### Key generation
- Path: `~/.ssh/id_ed25519` (ed25519, empty passphrase)
- `ssh-keygen -t ed25519 -f <path> -N "" -q`
- Two paths: Password wizard (`SSHKeyWizard.generateKey` line 36), Pairing (`ensureSSHKeyExists` line 914)

#### SSH fingerprint
- `getSSHFingerprint()` (Helpers.swift line 95) — runs `ssh-keygen -lf`, parses SHA256

#### SSH options used everywhere
- `StrictHostKeyChecking=no` — current (Layer 3 will change to `=yes` with pinned keys)
- `BatchMode=yes` — no interactive prompts
- `ConnectTimeout=2-5` — fast failure

---

## 4. STATE MAP

### Singletons (shared state)

| Singleton | File:Line | @Published Properties | Writers | Readers |
|-----------|-----------|----------------------|---------|---------|
| `ConfigStore.shared` | Config.swift:157 | `config`, `isSyncing`, `iconState`, `lastConfigSaveFailed`, `pendingQuitConfirm`, `transferLog`, `identity`, `trustedPeers`, `trustLog` | SyncEngine, SettingsView, AppDelegate, BonjourBrowser, pairing | All views |
| `SyncEngine.shared` | MainView.swift:99 | `status`, `lastSyncTime`, `dryRunResult`, `syncProgress`, `fallbackNotice`, `lowSpaceNotice`, `usingFallback`, `manualModeFreeSpace`, `nextAutoSyncDate`, `nextPushSyncDate`, `hasUnacknowledgedError`, `verifyStatus` | SyncEngine (self), BonjourBrowser (usingFallback) | MainView, SettingsView |
| `BonjourAdvertiser.shared` | BonjourDiscovery.swift:33 | `state`, `confirmedName`, `verifyRequestNonce` | BonjourAdvertiser (self), ReceiveMonitor (verifyRequestNonce) | BackupView, SettingsView |
| `BonjourBrowser.shared` | BonjourDiscovery.swift:331 | `services`, `state` | BonjourBrowser (self) | SettingsView |
| `BonjourPairingService.shared` | BonjourDiscovery.swift:868 | `state` | BonjourPairingService (self) | SettingsView |
| `ReceiveMonitor.shared` | BackupView.swift:365 | `state`, `receivePercent`, `receiveDetails`, `usingFallback`, `verifyStatus`, `effectiveDestination` | ReceiveMonitor (self), signal file parsing | BackupView, BonjourAdvertiser |
| `NetworkMonitor.shared` | BackupView.swift:162 | `currentIP` | NetworkMonitor (self) | BackupView |
| `NetworkInterfaceManager.shared` | BackupView.swift:23 | `availableInterfaces`, `usingFallback` | NetworkInterfaceManager (self) | SettingsView, SyncEngine |
| `FSEventsWatcher.shared` | FSEventsWatcher.swift:23 | (none @Published, uses callbacks) | FSEventsWatcher (self) | AppDelegate |
| `GlobalHotkey.shared` | GlobalHotkey.swift:5 | (none @Published) | GlobalHotkey (self) | AppDelegate |

### View-local @State (SettingsView)

| Property | Line | Purpose | Writers | Readers |
|----------|------|---------|---------|---------|
| `sshConnectionState` | 25 | SSH connection status | `runLiveSSHTest()`, `.onChange(of: config)` | secureConnectionSection |
| `localDiscoveryMode` | 27 | Discovery mode picker | `.onAppear`, user selection | body |
| `renameState` | 36 | Remote rename flow | `sendRemoteRename()`, `handleRenameConfirmed()` | body |
| `destinationCheckState` | 38 | Manual mode destination check | `confirmBackupDestination()` | body |

### State write timing in didUpdateTXTRecord

**BonjourBrowser.didUpdateTXTRecord** (line 614-721):
Within `Task { @MainActor }`:
1. `self.services[idx] = ...` (line 696) — @Published array write, synchronous (index-based, deferring risks stale idx)
2. `ConfigStore.shared.config.backupDestination` and `SyncEngine.shared.usingFallback` (lines 714-717) — deferred to next runloop tick via `DispatchQueue.main.asyncAfter(deadline: .now())` to avoid AttributeGraph cycle

---

## 5. SHARED / LOAD-BEARING PATHS

### Path 1: ConfigStore.shared.config
**Dependents**: Every view, SyncEngine, BonjourAdvertiser/Browser, FSEventsWatcher, GlobalHotkey  
**Breaks if changed**: Everything. Role, folders, IP, SSH state — all depend on this.  
**Thread**: Main only (SwiftUI binding)

### Path 2: Signal file protocol
**Files**: `Helpers.swift` (SignalFile enum), `MainView.swift` (write), `BackupView.swift` (read)  
**Dependents**: Main→Backup progress communication, refusal detection  
**Breaks if changed**: Progress display, low-space warning, receive state  
**Protocol**: JSON in `~/Sync/.sync_start`, `.sync_progress`, `.sync_complete`, `.sync_refused`

### Path 3: BonjourAdvertiser TXT record
**Dependents**: Main's discovery, free space display, fallback detection, pairing  
**Breaks if changed**: Discovery, pairing ack/nack, verify request  
**Thread**: Dedicated Bonjour thread, main thread reads via @Published

### Path 4: shellEscapeForDoubleQuotes()
**File**: Helpers.swift:27  
**Dependents**: All SSH commands, rsync paths, signal file writes  
**Breaks if changed**: Command injection, path escaping failures  
**SINGLE SOURCE OF TRUTH** — consolidated in audit pass 6

### Path 5: SSH arguments pattern
**Used in**: SyncEngine (rsync, du, write-test, signal files), SettingsView (SSH test, rename), SSHKeyWizard  
**Options**: `BatchMode=yes`, `ConnectTimeout=N`, `StrictHostKeyChecking=no`  
**Breaks if changed**: Connection failures, security regressions

### Path 6: Dedicated Bonjour threads
**Pattern**: `Thread` + `RunLoop.current.run()` + `NSMachPort` keepalive + `runLoopReady` semaphore  
**Instances**: BonjourAdvertiser, BonjourBrowser, BonjourPairingService  
**Breaks if changed**: Main thread hangs, Bonjour operation failures

---

## 6. THREADING MODEL

### Threads

| Thread | Name | Owner | Purpose |
|--------|------|-------|---------|
| Main | — | System | UI, @Published mutations, SwiftUI |
| Bonjour Advertiser | `com.rememberlive.sync.bonjour-advertiser` | BonjourAdvertiser | NetService operations |
| Bonjour Browser | `com.rememberlive.sync.bonjour-browser` | BonjourBrowser | NetServiceBrowser operations |
| Bonjour Pairing | `com.rememberlive.sync.pairing` | BonjourPairingService | Pairing NetService operations |
| FSEvents | (GCD) | FSEventsWatcher | File change callbacks |
| SSH/rsync | (GCD userInitiated) | SyncEngine | Process.run() |

### Cross-thread patterns

1. **perform(_:on:with:waitUntilDone:false)** — Schedule work on Bonjour threads (never waitUntilDone:true)
2. **DispatchQueue.global().async** — Background SSH/rsync launch
3. **Task { @MainActor }** — Jump to main for @Published mutations
4. **DispatchQueue.main.asyncAfter(deadline: .now())** — Defer to next runloop tick (flicker fix)

### Main-thread blocking risks

1. **getSSHFingerprint()** (Helpers.swift:95) — Synchronous `proc.waitUntilExit()`. Called in view body at SettingsView:1068.
2. **Bonjour runLoopReady.wait()** — Always on background queue, never main.
3. **rsync pipe drain** — Uses async NotificationCenter pattern, not synchronous readDataToEndOfFile().

---

## 7. KNOWN FRAGILE AREAS

### 7.1 BonjourBrowser.didUpdateTXTRecord cycle — RESOLVED
**Location**: BonjourDiscovery.swift:614-721  
**Issue**: Previously mutated `services`, `config.backupDestination`, `engine.usingFallback` in same @MainActor Task, causing AttributeGraph cycle  
**Resolution**: The two scalar writes (`backupDestination`, `usingFallback`) are now deferred to next runloop tick via `asyncAfter(deadline: .now())` (lines 714-717). The `services[idx]` array write stays synchronous — deferring it would risk stale/out-of-bounds index since the array can change between ticks

### 7.2 getSSHFingerprint() in view body
**Location**: SettingsView.swift:1068  
**Issue**: Blocking Process call during SwiftUI render  
**Symptom**: UI lag when opening Settings  
**Fix**: Cache fingerprint in @State, compute async on appear

### 7.3 Pairing ack/nack transient state
**Location**: BonjourAdvertiser lines 41-46, setPairAck/setPairNack lines 200-232  
**Issue**: 5-second auto-clear, Main must poll TXT within window  
**Risk**: Slow networks miss ack, pairing appears to fail  
**Mitigation**: Main has 45s timeout, BonjourBrowser monitors TXT continuously

### 7.4 Signal file race conditions
**Issue**: Main writes `.sync_start`, Backup polls every 2s  
**Risk**: Brief window where file exists but content incomplete  
**Mitigation**: Atomic write via shell `echo '...' > file`

### 7.5 Version history timeouts
**Location**: MainView.swift:1350-1580  
**Issue**: Master 60s timeout, individual 30s/45s  
**Risk**: Slow network hangs versioning, delays sync  
**Mitigation**: `VersioningGuard` ensures backup always proceeds

---

## 8. DESIGN INVARIANTS

### Calm Technology / Zero CPU at Idle
- FSEventsWatcher: Event-driven, no polling
- Bonjour: Callback-based, threads blocked on RunLoop.run()
- Auto Sync: Single-shot Timer, rescheduled after fire
- Signal files: Backup polls every 2s ONLY during active receive

### Event-Driven
- All user actions are button/toggle events
- All network events are delegate callbacks
- All file changes are FSEvents callbacks
- All timers are rescheduled, not repeating

### Honest Status
- Icon reflects true state (idle/syncing/success/error/warning)
- Free space shown is actual (from Backup's TXT record)
- Fallback to ~/Sync is always disclosed in UI
- Unknown values show "?" not "0"

### Backup as Source of Truth
- TXT record: Backup advertises its actual destination and free space
- Config: Main reads `backupDestination` from TXT, doesn't assume
- Refusal: Backup writes `.sync_refused`, Main reads and displays

### Features Fail Safe
- SSH failure: Abort sync, show error, clean up signal files
- Bonjour failure: Show "Network discovery unavailable"
- Version timeout: Proceed with sync anyway
- Write-test failure: Fall back to ~/Sync

---

## Appendix: Key Line References

### SyncEngine
- `sync()` entry: MainView.swift:149
- rsync launch: MainView.swift:380-561
- Signal file writes: MainView.swift:1018-1036
- Auto sync timer: MainView.swift:1206-1251
- Push sync trigger: MainView.swift:1260-1270

### ConfigStore
- Singleton: Config.swift:157
- `config` didSet save: Config.swift:160
- Role switch: Config.swift:258-276
- Trust functions: Config.swift:465-570

### BonjourAdvertiser
- TXT record build: BonjourDiscovery.swift:104-131
- Pairing ack/nack: BonjourDiscovery.swift:197-233

### BonjourBrowser
- TXT update handler: BonjourDiscovery.swift:614-721
- Auto-reconnect: BonjourDiscovery.swift:574-599

### BonjourPairingService
- Key generation: BonjourDiscovery.swift:914-953
- startPairing: BonjourDiscovery.swift:960-1006
- Confirm dialog call: BonjourDiscovery.swift:1295-1333 (dispatched to main thread at line 1297)
