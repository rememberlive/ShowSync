import Foundation
import IOKit

enum MachineFingerprint {
    /// The hardware-bound platform UUID (IOPlatformUUID), stable across reinstall,
    /// app-data reset, and OS reinstall on the same Mac. Used as the Keygen machine
    /// fingerprint for device-count enforcement. Returns nil if it can't be read.
    static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let cf = IORegistryEntryCreateCFProperty(service,
                                                       "IOPlatformUUID" as CFString,
                                                       kCFAllocatorDefault, 0)?
                                                       .takeRetainedValue() as? String else {
            return nil
        }
        return cf
    }
}
