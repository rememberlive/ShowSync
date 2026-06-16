import Foundation
import Combine

/// Persisted license record (JSON-encoded into the Keychain via LicenseStore).
struct StoredLicense: Codable {
    let key: String
    let licenseID: String
    let expiry: String?        // ISO8601 from Keygen, may be nil for perpetual
    var lastValidated: Date
    var status: String         // "valid" | "expired" | etc. (informational for now)
}

/// Runtime license state the app (and later the Settings UI) observes.
/// NOTE: this step only POPULATES state; nothing acts on it yet (no gating).
enum LicenseState: Equatable {
    case unknown          // not yet determined at launch
    case none             // no stored license (would mean trial/unlicensed later)
    case active(expiry: String?)
    case expired
}

@MainActor
final class LicenseController: ObservableObject {
    static let shared = LicenseController()
    @Published private(set) var state: LicenseState = .unknown
    private(set) var stored: StoredLicense?

    private init() {}

    /// Load persisted license from the Keychain into memory. Local only, no network.
    /// Populates `state` but takes NO action (no gating this step).
    func loadFromStore() {
        guard let json = LicenseStore.load(),
              let data = json.data(using: .utf8),
              let lic = try? JSONDecoder().decode(StoredLicense.self, from: data) else {
            stored = nil
            state = .none
            return
        }
        stored = lic
        // Informational expiry check only (no enforcement yet).
        if let expiry = lic.expiry,
           let date = ISO8601DateFormatter().date(from: expiry),
           date < Date() {
            state = .expired
        } else {
            state = .active(expiry: lic.expiry)
        }
    }

    /// Persist a freshly activated license and update state. Called on activation success.
    func persist(key: String, licenseID: String, expiry: String?) {
        let lic = StoredLicense(key: key, licenseID: licenseID, expiry: expiry,
                                lastValidated: Date(), status: "valid")
        if let data = try? JSONEncoder().encode(lic),
           let json = String(data: data, encoding: .utf8) {
            LicenseStore.save(json)
        }
        stored = lic
        state = .active(expiry: expiry)
    }
}
