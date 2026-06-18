// Copyright © 2026 Remember Chaitezvi. All rights reserved.
// Part of ShowSync — Remember Live.

import AppKit

// Quit confirmation is now rendered inline inside the popover by MainView and
// BackupView (see their .confirmQuit / showQuitConfirm branches).
//
// AppDelegate.applicationShouldTerminate (in SyncApp.swift) signals the active
// view by setting ConfigStore.shared.pendingQuitConfirm = true when Cmd+Q is
// pressed mid-sync; the view then renders the inline confirm.
//
// This file previously hosted HoldToQuitView + an NSPanel / NSAlert flow; that
// floating-window approach has been retired in favour of the inline pattern
// used elsewhere in the app.
