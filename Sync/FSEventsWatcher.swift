import Foundation
import CoreServices

// Global callback function for FSEvents — required because C function pointers cannot capture context
private func fseventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo else { return }
    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
    watcher.handleFileSystemChange()
}

// FSEvents-based file system watcher for Push Sync.
// Watches the source folder and triggers sync after a debounce period when files change.
// Uses pure Apple CoreServices framework — zero polling, event-driven, instant response.

final class FSEventsWatcher: ObservableObject {
    static let shared = FSEventsWatcher()

    // Published trigger that MainView can observe - increments each time sync should be triggered
    @Published var syncTrigger: Int = 0

    private var stream: FSEventStreamRef?
    private var debounceTimer: Timer?
    private var watchedPath: String = ""
    private var debounceSeconds: Int = 10

    private init() {}

    deinit {
        stop()
    }

    // Start watching the given folder path with the specified debounce interval
    func start(path: String, debounceSeconds: Int) {
        guard !path.isEmpty else { return }

        // If already watching the same path, just update debounce
        if watchedPath == path && stream != nil {
            self.debounceSeconds = debounceSeconds
            return
        }

        stop() // Stop any existing watcher

        watchedPath = path
        self.debounceSeconds = debounceSeconds

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathArray = [path] as CFArray

        stream = FSEventStreamCreate(
            nil,                                                    // allocator
            fseventsCallback,                                       // callback
            &ctx,                                                   // context
            pathArray,                                              // paths to watch
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),    // start from now
            0.5,                                                    // latency seconds
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes) // watch files with improved reliability
        )

        guard let stream else {
            NSLog("[FSEventsWatcher] Failed to create FSEventStream for path: %@", path)
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)

        let started = FSEventStreamStart(stream)
        if !started {
            NSLog("[FSEventsWatcher] Failed to start FSEventStream for path: %@", path)
            FSEventStreamRelease(stream)
            self.stream = nil
        } else {
            NSLog("[FSEventsWatcher] Started watching path: %@", path)
            NSLog("[FSEventsWatcher] Debounce interval: %d seconds", debounceSeconds)
        }
    }

    // Stop watching and clean up resources
    func stop() {
        debounceTimer?.invalidate()
        debounceTimer = nil

        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }

        if !watchedPath.isEmpty {
            NSLog("[FSEventsWatcher] Stopped watching path: %@", watchedPath)
            watchedPath = ""
        }
    }

    // Internal: Handle file system change events with debouncing
    func handleFileSystemChange() {
        NSLog("[FSEventsWatcher] File system change detected")
        // Reset debounce timer — if more changes arrive within the window, this timer gets cancelled and restarted
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(debounceSeconds), repeats: false) { [weak self] _ in
            NSLog("[FSEventsWatcher] Debounce period completed, triggering sync")
            self?.debounceTimer = nil
            // Debounce period completed with no new changes — trigger sync by updating @Published property
            Task { @MainActor [weak self] in
                self?.syncTrigger += 1
            }
        }
    }
}