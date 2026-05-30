# Menu Bar Dropdown Behaviour — Reference Spec

This document describes exactly how the **ShowMode** menu bar dropdown behaves. The **Sync app** should follow the same pattern so both apps feel identical to operate.

Hand this whole document to Claude Code as a reference when building or fixing the Sync app dropdown.

---

## 1. The menu bar icon

Both apps live entirely in the macOS menu bar — no Dock icon, no main window.

The icon has three possible visual states:

| State | What you see | When |
|---|---|---|
| **Idle** | Small grey dot (●) | The app is running, but the main feature is not yet active |
| **Active** | Bold coloured text (ShowMode: red "SHOW", Sync: whatever badge fits Sync) | The main feature is on |
| **Warning** | Same text but in amber | Active, but something needs attention |

A single left-click on the icon opens the dropdown panel. Clicking the icon again, or clicking outside the dropdown, closes it. This is standard macOS `NSStatusItem` behaviour — do not use a custom window or popover that hijacks focus.

---

## 2. First-click behaviour on the dropdown

This is the part that matters most. When the user clicks the icon for the first time after launch (or any time when the dropdown was closed), the following happens **automatically**, before the user does anything:

1. The dropdown opens.
2. The pre-flight / status check runs immediately in the background.
3. The dropdown displays whatever state was current as soon as the check completes (usually within a fraction of a second).
4. The user sees a fully-populated dropdown — they never see "loading…" or have to press a refresh button on the first open.

**Key rule:** status checks are event-driven, not continuously polling. They run when the dropdown opens, and only then. This keeps the app calm and low-power between shows.

In SwiftUI/AppKit terms: hook the status refresh into the `NSStatusItem`'s open event (or the `.onAppear` of the dropdown's root view). Do **not** run it on a timer.

---

## 3. Dropdown layout — idle state

When the main feature is **off**, the dropdown contains these elements from top to bottom:

1. **Title row** — app name on the left, current state label on the right (e.g. "Show Mode — Inactive" or "Sync — Idle").
2. **Primary action button** — the big one. For ShowMode it says "Enter Show Mode". For Sync it might say "Sync Now" or "Start Sync". Full width, bold colour.
3. **Secondary action button** — smaller, lower-priority. For ShowMode it's "Run Pre-flight Check". For Sync it could be "Test Connection" or "Refresh Receiver IP".
4. **Status section** — collapsed by default on first open. Shows a one-line summary like "All checks passed" or "2 issues to fix". The user can click to expand and see each item.
5. **Footer row** — a gear icon (Settings) on the bottom-left, a "Quit" button on the bottom-right.

The whole dropdown should be roughly 320–360 points wide, vertically sized to fit its contents, with consistent padding (12–16 points) on all sides.

---

## 4. Dropdown layout — active state

When the main feature is **on**, the dropdown changes:

1. **Title row** changes to show the active state — bold coloured (red for ShowMode, your chosen accent for Sync).
2. **Primary action button** becomes the **Exit** button. It requires a **3-second hold** to activate, not a single click. Show a progress fill animation as the user holds. This prevents an accidental exit mid-show.
3. **Status section** is expanded by default and shows live state (for ShowMode: the seven checks; for Sync: connection status, last sync time, files transferred, etc.).
4. **Footer** — same gear and Quit, but Quit also now requires a 3-second hold **plus** a confirmation dialog ("Quit Sync app? The sync will be interrupted.") to prevent accidental quit during an active operation.

---

## 5. The Settings panel

The gear icon in the footer opens Settings. Behaviour:

1. **Settings replaces the current dropdown view** — it slides in, or the panel re-renders to show Settings. It does **not** open a separate window. Same dropdown frame, different content.
2. **A back arrow (←) appears in the top-left** of the Settings view. Tapping it returns to the main dropdown view.
3. **Settings content** is a vertically scrolling list of sections, each with a heading and one or more controls:
   - For ShowMode: "Show Machine Optimisations" (with Set Up / Restore buttons), "Launch at login" (toggle), "About" (version number).
   - For Sync: similar pattern — e.g. "Pairing" (set receiver IP or auto-discover), "Sync folder" (which directory to sync), "Launch at login" (toggle), "About".
4. **All settings persist across app launches.** Use `UserDefaults` or `@AppStorage` in SwiftUI. The user should never have to re-configure on relaunch.
5. **Settings open from a clean state.** When the user opens Settings, it reflects the current saved values immediately — no loading delay.

Important: Settings is for **configuration**, not for triggering actions. Actions (like "Sync Now") belong on the main dropdown view. Settings is where you set up things that affect *how* the app behaves, not *what* it does right now.

---

## 6. The Quit button — single source of truth

The Quit button lives in the footer of both the idle and active dropdowns. Its behaviour depends on app state:

- **Idle:** single click quits the app immediately. No confirmation.
- **Active:** requires a 3-second hold, then shows a confirmation dialog. Only quits if the user confirms.

The Quit button is also styled differently in each state:
- **Idle:** plain grey text or button.
- **Active:** red text/button — visually echoes the active state colour, signals "this is a serious action right now".

---

## 7. Visual consistency rules

- **One accent colour per app.** ShowMode uses red as its active accent and amber as its warning accent. Sync should pick its own pair and stick with them everywhere — the primary button, the active state text in the menu bar, the Quit-during-active styling.
- **Backgrounds.** Use the system material background (`NSVisualEffectView` / `.regularMaterial` in SwiftUI) so the dropdown blends with light and dark mode automatically. Don't hardcode background colours.
- **Spacing and rhythm.** Use the same padding and spacing values throughout (e.g. 12 points between sections, 8 points within sections). Inconsistent spacing is the most common reason a SwiftUI panel feels "off".
- **Typography.** System font, regular weight for body, semibold for labels, bold for the main action button. No more than three sizes total in the whole dropdown.

---

## 8. What "not working properly" usually means

If your Sync app dropdown is misbehaving, the most common causes are:

1. **The dropdown is its own window instead of an `NSStatusItem` popover.** Symptom: it appears in the wrong place, doesn't close when you click outside, or steals focus from other apps. Fix: use the standard `NSStatusItem` with `NSPopover` or SwiftUI's `MenuBarExtra`.
2. **Status check is on a timer instead of an event.** Symptom: the dropdown shows stale data or flickers. Fix: trigger the check only when the dropdown opens.
3. **Settings is a separate window.** Symptom: clicking the gear opens a new window instead of replacing the dropdown content. Fix: Settings must be a different view within the same dropdown frame.
4. **State doesn't persist.** Symptom: the user configures something, quits, relaunches, and the setting is gone. Fix: write everything to `UserDefaults` via `@AppStorage` and read from it on launch.
5. **Active-state Quit is unprotected.** Symptom: a single click quits during an active operation. Fix: implement the 3-second hold + confirmation dialog for the active state.

---

## 9. Implementation hint for Claude Code

In SwiftUI on macOS 13+, use `MenuBarExtra` as the entry point. The body of the `MenuBarExtra` is the dropdown. Inside, use a single state variable (e.g. `@State private var currentView: DropdownView = .main`) and switch between `.main` and `.settings` to swap content within the same panel. Do not introduce a second `Scene` or window for Settings.

Status state should be held in an `@ObservableObject` view model. The model exposes a `refresh()` method that is called from `.onAppear` of the main view. No timers, no background loops.

For the 3-second hold button, use a `DragGesture` with a minimum distance of zero and track elapsed time; show a progress overlay that fills as the time passes; only fire the action when 3 seconds is reached and the gesture has not been cancelled.

---

## 10. The point of this document

ShowMode works because every one of these behaviours is consistent. The user only has to learn the pattern once — then any future app from you (Sync, and whatever comes after) feels familiar. If the Sync app's dropdown drifts from these rules, the user has to think harder, and "thinking harder" during a show is exactly what we are trying to eliminate.

When in doubt, ask: *"Does ShowMode do it this way?"* If yes, copy that. If no, you are probably overengineering.
