# V2 One-to-Many Audit — ShowSync Main → N Backups

> Read-only architecture audit + phased plan proposal for the planned v2 ONE-TO-MANY sync
> feature: the Main connects to MULTIPLE Backup devices (conference use: 20–80 rooms);
> each destination has its OWN source folder on the Main (Room01 folder → Room01 device);
> sync runs SEQUENTIALLY one destination at a time (deliberate — a network disturbance must
> not restart everything; a persisted queue resumes at the first unfinished room, and rsync
> incrementality resumes within a room).
>
> Audited at commit `4b1e952` by reading every source file end-to-end (Config, Helpers,
> MainView/SyncEngine, BonjourDiscovery, BackupView, ConnectionStatus, WindowsTransport,
> SyncApp, SettingsView). All file:line references are current as of that commit.
> **v1.0 ships first — nothing changes now.**

**Headline finding:** the transport is already ~80% invocation-parameterized (per-run values
are captured at `sync()` entry from a passed `Config` value), the Backup side needs **zero
changes**, and the signal-file protocol is per-destination by construction. What is genuinely
singular is a thin but load-bearing layer: 4 engine globals, the adoption/auto-reconnect
writer, the verify response path, and the config schema. An additive orchestrator is feasible.

---

## 1. CONFIG — every one-backup assumption

All in the `Config` struct and its on-disk mirror:

| Field | Where | Singular assumption |
|---|---|---|
| `sourceFolder` | Config.swift:39 | one source for "the" backup |
| `destinationIP` | Config.swift:40 | one address |
| `username` | Config.swift:41 | one remote account |
| `sshKeysConfigured` / `ForIP` / `ForUsername` | Config.swift:53-55 | "the connection" is set up (actually per-peer authorization of the Main's single key) |
| `backupHostname` | Config.swift:68 | one Bonjour name |
| `lastBackupDiscoveryName` / `lastBackupIP` | Config.swift:69-70 | one auto-reconnect memory |
| `backupDestination` | Config.swift:71 | one remote folder (from "the" TXT) |
| `backupPlatform` | Config.swift:77 | one platform flag |
| `manualWindowsBackup` | Config.swift:82 | one persisted toggle |
| `isReadyToSync` | Config.swift:101-103 | gate over the singular fields |

Persistence mirrors it 1:1: `MainConfig` (Config.swift:112-145), `save()` (Config.swift:348-388).
The optional-field decode pattern for schema growth already exists (Config.swift:121-123,
143-144 — `var x: T? = nil` + `?? default` in `readMainConfig` :691-692, :721) — **a
`destinationProfiles: [DestinationProfile]?` array is a proven-safe additive change**.

What a profile list `{name, peerId, sourceSubfolder, destPath, platform, address, username}`
touches:

- **New**: `DestinationProfile: Codable`, array on `Config` + `MainConfig`, encode/decode
  lines in `save()`/`readMainConfig`. Pure addition.
- **Untouched if the orchestrator "loads" a profile into the existing singular fields per
  run** — the engine reads the passed `Config` value, so profile→Config synthesis per room
  means the schema above never has to change meaning. The singular fields become "the active
  room" during a run and "the show default / v1 mode" otherwise.
- Bonus: `TransferLogEntry` already records `destination` per entry (Config.swift:17) —
  history is one-to-many-ready; it only lacks a room/peer label.

## 2. ENGINE STATE SINGLETONS — per-run vs global, and what leaks

`SyncEngine.shared` (MainView.swift:114-115). Classified:

**Already per-invocation (reset at every `sync()` entry — safe for serial reuse):**
`syncUsername`, `syncIP`, `syncRemotePath`, `isAutoSync/isPushSync`, `syncStartTime`,
`syncTotalFiles`, `expectedSize`, `syncProgress` — all captured/zeroed at
MainView.swift:215-229. Every SSH helper downstream (`sshWrite` :1315, `runDu` :1187,
signal writes :1243-1263, `checkSyncRefused` :534) reads these captured fields, **not**
live config. ✅

**GLOBAL — would leak between serial runs against different targets:**

1. **`usingFallback`** (MainView.swift:124) — one flag for "the" backup. Room A's drive
   falls back → flag latches true → Room B's `verifyNow` picks `~/Sync` instead of its real
   dest (:724), `writeVerifyResult` targets the wrong path (:1279), the rsync
   terminationHandler stamps Room B's log entry `wasUsingFallback=true` (:516), and the UI
   shows "(drive unavailable)" for the wrong room (:2003). **Must become per-destination
   state.** Note: the *write-test at each sync() re-probes and corrects it* (:277-289), so
   within a run it self-heals — the leak window is verify, logging, and UI between runs.
2. **`lastRealDestWriteTest`** (MainView.swift:133) — keyed by **path string only**, not
   peer. With 80 rooms whose dest is the same string (e.g. everyone at `~/Sync` or
   `/Volumes/Backup`), Room A's "unwritable" verdict wins over Room B's healthy
   advertisement in `reconcileFallback` (:138-146). **Key must become (peerId, path).**
3. **`isRemoteVerify`** (MainView.swift:172) — one latch, no requester identity; see item 6.
4. **`manualModeFreeSpace`** (MainView.swift:125) — one value, written by ConnectionStatus
   polls (ConnectionStatus.swift:206-208).

**Global but acceptable/aggregate:** `status` (:117 — serializes runs, see item 3),
`lastSyncTime` (:118 — becomes per-room in profiles, global stays as "last any-room sync"),
notices (:121-123 — transient, self-clearing), `verifyStatus` (:168), auto/push timers
(:149-153 — the orchestrator replaces per-sync scheduling with per-queue scheduling),
`ConfigStore.isSyncing`/`iconState` (aggregate by design).

**Outside the engine:**

- `ConnectionStatus.shared` (ConnectionStatus.swift:28-32) — single `state`, polls the
  singular `config.username`/`destinationIP` (:79-80). Per-room reachability needed for the
  queue gate; note 80 rooms × 3 s ssh probes is unacceptable — orchestrator should probe
  current+next room only.
- `BonjourBrowser.lastHandledVerifyNonce` (BonjourDiscovery.swift:252) and
  `ConnectionStatus.lastHandledVerifyNonce` (ConnectionStatus.swift:38) — single-slot nonce
  dedupe; alternating requests from two Backups would re-trigger each other. Needs a
  per-peer dict (bounded).
- `BonjourBrowser.isCurrentPeerReachable` (BonjourDiscovery.swift:242) — single flag for
  "the" peer.
- `WindowsTransport.shared` — its run metadata is captured per-run (WindowsTransport.swift:56-61,
  set at :495-507) ✅, but it reads/writes the engine's global `usingFallback` (:502, :585,
  :838-840, :920) — inherits the same per-dest fix.

## 3. THE ENGINE AS AN INVOCABLE UNIT

**Can `sync()` be called serially against different targets today?** *Almost.*
`sync(config:isAuto:isPush:)` (MainView.swift:189) takes a `Config` **value** — address,
username, dest, source, platform all flow from the argument, and per-run fields are captured
at entry (:223-229). Mid-run mutation of `ConfigStore.shared.config` (e.g. an adoption write
from another room's TXT resolve) does **not** corrupt an in-flight transfer. The
`guard !status.isActive` (:198) plus single `task` (:158) naturally enforce one-at-a-time —
**sequential-only is the grain of this engine, not a compromise**.

What must change for orchestrated invocation:

1. **No completion signal** — `sync()` is fire-and-observe. Terminal paths: refused
   (:536-556), success (:559-606), failure (:607-626), cancel (:658-705), launch failure
   (:926-936), preview (:387). The orchestrator needs either a `completion:` parameter
   threaded to all six, or to observe `status`/transfer-log transitions. A completion param
   (default `nil`, so v1 call sites are untouched) is the cleaner additive change. Same for
   `WindowsTransport` (finish paths at WindowsTransport.swift:780, 813, 850, 869, 889).
2. **Cross-run leaks from item 2** — `usingFallback` + `lastRealDestWriteTest` keyed per
   (peerId, path); verify latch per-peer.
3. **The reachability gate** (:203-210) reads `ConnectionStatus.shared` and
   `BonjourBrowser.isCurrentPeerReachable` — both bound to "the current" peer. Per-room
   invocation must supply per-peer reachability (or the orchestrator pre-gates and the
   engine trusts its caller for orchestrated runs).
4. **Live-config reads inside verify**: `triggerRemoteVerify` (:877) and
   `writeVerifyResult` (:1267-1279) read `ConfigStore.shared.config`, not captured values —
   parameterize (item 6).
5. **Reset-between-runs**: nothing else — signal cleanup, du polling, rate samples all
   reset per run (:1177-1182, :215-229).

## 4. DISCOVERY / ADOPTION

**The multi-peer data model already exists at discovery level.** `services:
[DiscoveredBackup]` (BonjourDiscovery.swift:240), and each entry carries everything a
per-room record needs: `resolvedIP`, `destinationPath`, `effectiveDestinationPath`,
`freeSpaceBytes`, `isReachableOnSelectedInterface`, `backupDeviceId`, `backupFingerprint`,
`username`, `platform`, computed `isUsingFallback` (BonjourDiscovery.swift:211-229). Free
space and fallback per peer arrive continuously via TXT — nothing new to invent.

**What is singular is the adoption sink.** `handleAutoReconnect`
(BonjourDiscovery.swift:496-538) matches ONE remembered backup
(`lastBackupDiscoveryName`/`lastBackupIP`/`destinationIP`, :499-501) and funnels everything
into globals: `config.destinationIP/backupHostname` (:505-507), `backupDestination`
(:510-512), `backupPlatform` (:516-518), engine fallback via `reconcileFallback` (:522-523),
name (:527-530), username broadcast (:534-536), `isCurrentPeerReachable` (:537). Same
pattern in the reachability-clear block (:453-465), the manual-mode poll
(ConnectionStatus.swift:191-198), and Settings' selection button + Confirm Destination
(SettingsView.swift:679-698, :2626-2639).

**Per-peer tracking needs:** a resolve keyed by `backupDeviceId` updating the matching
*profile* record `{lastIP, effectiveDest, free, fallback, username, platform, reachable,
lastSeen}` — an additive second sink alongside the existing global one (which keeps
servicing v1 single-backup mode unchanged). `MainView`'s free-space lookup already does
per-peer matching by IP (MainView.swift:2021-2027) — it just selects one.

## 5. PAIRING — does trust scale to N?

**Yes, structurally.** `trustedPeers: [TrustedPeer]` (Config.swift:237; type at
Helpers.swift:192-203) is an array keyed by `peerDeviceId` with per-peer role/fingerprint;
`unpairPeer` is per-peer (Config.swift:617-647); the Backup side authorizes by key line
append (idempotent, Helpers.swift:275-342). The Main has **one** keypair for all Backups —
pairing room-by-room just appends the same pubkey to each room's `authorized_keys`. Pairing
is one-at-a-time (`isPairingInProgress`, BonjourDiscovery.swift:602/621) — fine for setup
workflow, and `targetBackupId` (:681) routes the request to the right device.

Three single-peer warts:

- **`handleAck` picks the wrong peer's name**: `services.first(where: { _ in true })` —
  literally the first discovered service (BonjourDiscovery.swift:708). Harmless with 1-3
  peers; wrong 79/80 times at a conference. Must match by `targetBackupId`.
- **`markPeerAsPairedOnMain` sets the global connection flags**
  `sshKeysConfigured/ForIP/ForUsername` (Config.swift:607-609) — "paired" must become a
  per-profile fact.
- **`forgetBackup` nukes all backup-role peers** (loop at SettingsView.swift:2777-2778)
  plus the singular selection fields (:2780-2786) and **deletes the shared keypair**
  (:2733, 2764 → `deleteLocalKeypair` :2693-2697) — which would sever all 79 other rooms.
  Needs per-room forget that only removes the key from *that* room's `authorized_keys` and
  never deletes the local keypair while other pairings exist.

## 6. VERIFY — per-peer or single-peer-assumed?

**Request direction: per-peer by construction.** Each Backup advertises its own `verifyReq`
nonce in its own TXT (BonjourDiscovery.swift:167; set at BackupView.swift:1337), or writes
`.verify_request` into its own dest folder (manual, BackupView.swift:1364-1367). The
Backup-side timeout is nonce-scoped (`pendingVerifyNonce`, BackupView.swift:463,
:1342-1360). ✅

**Response direction: single-peer-assumed, three ways:**

1. The Main only honors requests from "the" selected backup — `config.destinationIP ==
   service.resolvedIP` gate (BonjourDiscovery.swift:484-486). Other rooms' requests are
   ignored (correct for v1, needs routing for v2).
2. `isRemoteVerify` is one latch with no requester identity (MainView.swift:172, set :876)
   — the reply goes to whoever is globally configured when the verify finishes.
3. `writeVerifyResult` reads **live global config** for username/IP/dest/fallback
   (MainView.swift:1267-1279) — if the orchestrator has since moved to the next room, the
   result lands on the wrong machine.

Nonce dedupe is single-slot on both paths (BonjourDiscovery.swift:252;
ConnectionStatus.swift:38). Verify itself (`verifyNow(config:)`, MainView.swift:709) is
parameterized like sync, apart from the global `usingFallback` read (:724). Fix shape: carry
`{peerId, nonce, address, dest}` through the latch and parameterize `writeVerifyResult` —
contained.

## 7. SIGNAL FILES — confirmed per-destination by construction ✅

Written by the Main **under the run's captured remote path**
(`writeSyncStart/Progress/Complete/cleanup`, MainView.swift:1243-1263, all via
`syncRemotePath`); read by each Backup **from its own `effectiveDestination`**
(BackupView.swift:658-665). Since every destination is a distinct machine polling its own
folder, N rooms cannot cross-talk. The Windows transport speaks the identical protocol into
its own `runDest` (WindowsTransport.swift:386-490). Nothing to change. (Only note:
Backup-side `clearStaleSignalFiles` on launch, BackupView.swift:578-591 — already
per-device.)

## 8. UI — everything bound to "the backup" singular

**MainView** (all in MainView.swift):

- Connection Info block :1952-2044 — discovery name :1961, user :1972, IP :1982/2408-2413,
  folder + fallback badge :2000-2020, per-peer free-space picked by singular IP :2021-2027.
- Header status = one engine :1902-1917; progress bar :2069-2107; notices :2110-2143.
- Sync/Verify buttons + gates :2149-2208, `peerReachableForSync` :2431-2434,
  `syncDisabledReason` :2437-2444.
- "Last sync" :2050-2053 / :2486-2494 (transfer log is per-dest, display collapses it).
- History rows already show per-entry destination ✅ :2722-2732.

**SettingsView**:

- Discovered list is a **single-select radio** :678-729 (selection writes the global fields
  :683-698).
- Destination section (auto folder row :1203-1232; manual IP/folder/Windows rows
  :1234-1461); Confirm Destination writes globals :2626-2639.
- Rename flow targets "the" backup :1057-1126; `usernameIsBroadcast` :1035-1040; Secure
  Connection/pairing gate on single `connectionStatus.state` :1655-1743; "Forget This
  Backup" :1748-1762.

**BackupView: zero changes** — each room device runs its own Backup instance; the entire
Backup-role UI, ReceiveMonitor, StorageMonitor, and advertiser are per-device already.
**This is the biggest structural win: half the app (and the entire Windows twin's receive
side) is untouched by v2.**

## 9. SHAPE ESTIMATE — additive orchestrator over untouched transport: **CONFIRMED feasible**

The claim holds with one honest amendment: "untouched transport" is 95% true. The
rsync/ssh/sftp mechanics, write-test, versioning, signal protocol, du-polling, and the
Backup side need no changes. What must change *in place* inside the engine is small and
enumerable: a completion hook on ~6 terminal paths, and re-keying 3 globals
(`usingFallback`, `lastRealDestWriteTest`, `isRemoteVerify`+result routing) per destination.
Everything else — profiles, queue, persistence, room UI, per-peer adoption table — is
genuinely additive.

Sequential-only is not just acceptable, it's what the engine already enforces
(`!status.isActive`, one `task`, one du poller) — concurrency would be the rewrite; the
requirement and the architecture agree. Resume comes in two layers for free: rsync
incrementality within a room, and a persisted queue journal (append-only JSON, same
atomic-write idiom as `transfer_log.json`, Config.swift:439-446) across rooms.

**Rough total: ~1,500–2,100 new lines, ~400–600 modified lines**, phased below.

## 10. THE PLAN — phased v2 build

| Phase | What | Kind | Risk | Rough size |
|---|---|---|---|---|
| **0. Destination profiles** | `DestinationProfile` Codable + `[DestinationProfile]?` on `MainConfig` (optional-field pattern, Config.swift:121-123) + runtime array + persistence. Empty/nil = v1 single-backup mode, byte-identical behavior. | Additive | Low | ~200 |
| **1. Engine invocation hygiene** | `completion:` param on `sync()`/`verifyNow()` (default nil) wired to all terminal paths incl. WindowsTransport; re-key `lastRealDestWriteTest` → (peerId, path); `usingFallback` becomes per-dest record with the existing `@Published` as the active-dest view (v1 UI untouched). | **In place** | **HIGH — stop & confirm.** Touches the just-fixed fallback self-heal latch (commit `2ae7839`) and six exit paths. This is the phase that can regress v1. | ~150–300 modified |
| **2. Orchestrator** | New `SyncOrchestrator.swift`: build queue from profiles → synthesize per-room `Config` → invoke `sync()` serially via completion → per-room state records → persisted journal (resume at first unfinished room) → retry policy → aggregate icon/status. Auto-sync timer triggers a queue run instead of one sync. Decide: push-sync change→room mapping (FSEvents watches the parent show folder; map changed path → room subfolder). | Additive (new file) | Low-medium (timer interplay) | ~350–500 |
| **3. Per-peer adoption** | Second adoption sink in the resolve handler: update profile matching `backupDeviceId` (IP/effectiveDest/free/fallback/username/platform/lastSeen); per-peer reachability map; probe-on-demand ConnectionStatus (current+next room only, not 80×3s polls). Global sink kept for v1 mode. | In place (guarded) | **Medium-high — stop & confirm.** `handleResolverEvent`/`handleAutoReconnect` is fragile area §7.1 (AttributeGraph history, pairing-load-bearing late events, BonjourDiscovery.swift:358-364). | ~150–250 |
| **4. Room-list UI** | Main-role rooms view: per-room dot/last-sync/free/fallback, "Room 34/80" queue progress, per-room detail + retry; profile editor (name, paired device picker, subfolder, dest, platform). Existing MainView becomes the single-backup/v1 view or the active-room view. | Additive | Low (but the largest) | ~500–800 |
| **5. N-peer verify + pairing polish** | Verify request carries `{peerId, nonce}` through the latch; `writeVerifyResult` parameterized (MainView.swift:1267); per-peer nonce dedupe dicts (BonjourDiscovery.swift:252, ConnectionStatus.swift:38); `handleAck` match by `targetBackupId` (BonjourDiscovery.swift:708); per-room forget that never deletes the shared keypair while other pairings exist (SettingsView.swift:2693-2697, 2777). | In place, contained | Medium — stop & confirm on the forget/keypair change | ~120–200 |

**Ordering rationale:** 0→1 gives you a testable "run one room via a synthesized profile"
milestone before any queue exists; 2 delivers the conference capability with the global UI
as-is; 3 makes it self-healing; 4 makes it visible; 5 closes the long-tail correctness
holes. Phases 1, 3, and 5 are the stop-and-confirm points — each touches code with
regression history (fallback latch, TXT handler, trust teardown).

**What the Windows twin inherits:** everything. ShowSync-Win's receive side is untouched
(signal files + TXT per device). On the Main, `WindowsTransport` already captures per-run
metadata (WindowsTransport.swift:56-61) and is invoked through the same `sync()` gate
(MainView.swift:238-241) — once Phase 1 fixes its global `usingFallback` reads (:502, :920),
a room list can freely mix Mac and Windows rooms because `platform` is already per-peer in
discovery (BonjourDiscovery.swift:224) and per-profile in the new schema.
