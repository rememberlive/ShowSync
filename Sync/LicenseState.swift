// Copyright © 2026 Remember Chaitezvi. All rights reserved.
// Part of ShowSync — Remember Live.

import Foundation
import Combine
import os

/// License log (Console: category License). Never logs the key itself.
private let licenseLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RememberLive", category: "License")

/// Tolerant ISO8601 parser for Keygen timestamps (with OR without fractional seconds).
/// Keygen expiries look like "2026-06-30T02:10:04.719Z" — the default
/// ISO8601DateFormatter (no fractional seconds) returns nil for those.
enum LicenseDate {
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}

/// Persisted license record (JSON-encoded into the Keychain via LicenseStore).
struct StoredLicense: Codable {
    let key: String
    let licenseID: String
    let expiry: String?        // ISO8601 from Keygen, may be nil for perpetual
    var lastValidated: Date
    var status: String         // "valid" | "expired" | etc. (informational for now)
    var policyID: String?      // Keygen policy id (optional → old records still decode)
}

/// Runtime license state the app (and later the Settings UI) observes.
/// NOTE: this step only POPULATES state; nothing acts on it yet (no gating).
enum LicenseState: Equatable {
    case unknown          // not yet determined at launch
    case none             // no stored license (would mean trial/unlicensed later)
    case active(expiry: String?)
    case expired
}

/// Derived, read-only classification of the stored license. Gates nothing.
enum LicenseKind: Equatable { case trial, paid, none }

struct LicenseSummary: Equatable {
    let kind: LicenseKind
    let expiry: Date?
    let daysRemaining: Int?
    let isValid: Bool
}

@MainActor
final class LicenseController: ObservableObject {
    static let shared = LicenseController()
    @Published private(set) var state: LicenseState = .unknown
    @Published private(set) var stored: StoredLicense?

    private init() {}

    /// Load persisted license from the Keychain into memory. Local only, no network.
    /// Populates `state` but takes NO action (no gating this step).
    func loadFromStore() {
        guard let json = LicenseStore.load(),
              let data = json.data(using: .utf8),
              let saved = try? JSONDecoder().decode(StoredLicense.self, from: data) else {
            stored = nil
            state = .none
            return
        }
        // Trust only a genuine signed key. A record whose key fails the Ed25519
        // signature check (hand-made or edited) is treated as no license.
        let savedKey = saved.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signed = LicenseManager.signedInfo(from: savedKey) else {
            licenseLog.notice("Stored license failed signature check; treated as unlicensed")
            stored = nil
            state = .none
            return
        }
        // Expiry and policy come from the SIGNED key when present (an edited
        // expiry in the saved record has no effect); fall back to the saved
        // values only where the key carries none.
        let lic = StoredLicense(key: saved.key,
                                licenseID: saved.licenseID,
                                expiry: signed.expiry ?? saved.expiry,
                                lastValidated: saved.lastValidated,
                                status: saved.status,
                                policyID: signed.policyID ?? saved.policyID)
        stored = lic
        // Informational expiry check only (no enforcement yet).
        // Uses the tolerant parser so fractional-seconds expiries parse correctly.
        if let date = LicenseDate.parse(lic.expiry), date < Date() {
            state = .expired
        } else {
            state = .active(expiry: lic.expiry)
        }
    }

    /// Persist a freshly activated license and update state. Called on activation success.
    func persist(key: String, licenseID: String, expiry: String?, policyID: String?) {
        let lic = StoredLicense(key: key, licenseID: licenseID, expiry: expiry,
                                lastValidated: Date(), status: "valid", policyID: policyID)
        if let data = try? JSONEncoder().encode(lic),
           let json = String(data: data, encoding: .utf8) {
            LicenseStore.save(json)
        }
        stored = lic
        state = .active(expiry: expiry)
    }

    /// Derived, read-only summary of the current license. Purely informational — gates nothing.
    var summary: LicenseSummary {
        guard let lic = stored else {
            return LicenseSummary(kind: .none, expiry: nil, daysRemaining: nil, isValid: false)
        }
        // Classify by policy id (robust); fall back to expiry presence if unknown.
        let kind: LicenseKind
        switch lic.policyID {
        case KeygenConfig.trialPolicyID: kind = .trial
        case KeygenConfig.paidPolicyID:  kind = .paid
        default:                          kind = (lic.expiry != nil) ? .trial : .paid
        }
        let expiry = LicenseDate.parse(lic.expiry)
        let days: Int? = expiry.map { max(0, Int(($0.timeIntervalSinceNow / 86400).rounded(.down))) }
        let isValid = (expiry == nil) || (expiry! > Date())
        return LicenseSummary(kind: kind, expiry: expiry, daysRemaining: days, isValid: isValid)
    }

    /// Whether to grant full (non-gated) mode. FAIL-OPEN: on a Keychain READ ERROR
    /// (ambiguous), grant full mode (never punish a paying user for a transient glitch).
    /// Only a CLEANLY-ABSENT or EXPIRED license gates to backup-only.
    /// Returns true = full mode allowed; false = gate to backup-only.
    /// Reads loadResult() fresh — intended for launch-time evaluation.
    var grantsFullMode: Bool {
        switch LicenseStore.loadResult() {
        case .error:  return true            // fail OPEN — honor saved role
        case .absent: return false           // legitimately unlicensed → gate
        case .found:  return summary.isValid // valid trial/paid → full; expired → gate
        }
    }
}
