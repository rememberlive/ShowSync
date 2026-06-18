// Copyright © 2026 Remember Chaitezvi. All rights reserved.
// Part of ShowSync — Remember Live.

import Foundation
import CryptoKit

/// Result of a Keygen license activation/validation round-trip.
enum ActivationResult {
    case activated(key: String, licenseID: String, expiry: String?)
    case expired
    case machineLimit
    case invalid(code: String)
    case networkError(String)
}

/// Keygen license-key activation (online). Validates a key scoped to this machine's
/// fingerprint and activates the machine if it isn't registered yet. Network + logic
/// only — no persistence, no gating (those are later steps). Does NOT yet verify the
/// Ed25519 signature; for now it trusts the HTTPS validate response.
enum LicenseManager {
    private static let apiHeaders = [
        "Content-Type": "application/vnd.api+json",
        "Accept": "application/vnd.api+json"
    ]

    // Product-scoped trial endpoint. Not live yet — fetchTrialKey fails gracefully
    // (returns nil) on any non-200 / network / decode error, so the UI can prompt
    // the user to enter a key manually.
    private static let trialURL = "https://rememberlive.africa/showsync/trial"

    /// Fetch a fresh trial license key from the product trial service.
    /// Returns nil on any failure (offline, timeout, non-200, malformed) so callers
    /// can degrade gracefully. Does NOT activate — caller passes the key to activate().
    static func fetchTrialKey() async -> String? {
        guard let url = URL(string: trialURL) else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        req.httpMethod = "GET"
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            struct TrialKeyResponse: Decodable { let key: String }
            return try? JSONDecoder().decode(TrialKeyResponse.self, from: data).key
        } catch { return nil }
    }

    // MARK: Minimal decodable shapes (only fields we use)

    private struct ValidateResponse: Decodable {
        struct Meta: Decodable { let valid: Bool?; let code: String? }
        struct DataObj: Decodable {
            struct Attrs: Decodable { let expiry: String? }
            let id: String?
            let attributes: Attrs?
        }
        let meta: Meta?
        let data: DataObj?
    }

    // MARK: Public entry point

    static func activate(key: String) async -> ActivationResult {
        guard let fingerprint = MachineFingerprint.hardwareUUID() else {
            return .networkError("Could not read this Mac's hardware identifier")
        }

        // 1. Validate the key, scoped to this machine.
        let first: ValidateResponse
        do { first = try await validateKey(key, fingerprint: fingerprint) }
        catch { return .networkError(error.localizedDescription) }

        let code = first.meta?.code ?? ""
        if (first.meta?.valid ?? false) && code == "VALID" {
            let lid = first.data?.id ?? "", exp = first.data?.attributes?.expiry
            await LicenseController.shared.persist(key: key, licenseID: lid, expiry: exp, policyID: policyID(from: key))
            return .activated(key: key, licenseID: lid, expiry: exp)
        }

        switch code {
        case "NO_MACHINE", "NO_MACHINES", "FINGERPRINT_SCOPE_MISMATCH":
            // Valid key, this machine not activated yet → activate, then re-validate.
            // FINGERPRINT_SCOPE_MISMATCH is Keygen's "this fingerprint isn't enrolled on
            // the license yet" under fingerprint-scoped validation when the license already
            // has another machine — same remedy: enroll this machine. The 2-machine limit
            // is still enforced server-side (a full license returns 422 → .machineLimit).
            guard let licenseID = first.data?.id else { return .invalid(code: "MISSING_LICENSE_ID") }
            let activateStatus: Int
            do { activateStatus = try await activateMachine(key: key, fingerprint: fingerprint, licenseID: licenseID) }
            catch { return .networkError(error.localizedDescription) }

            if activateStatus == 422 { return .machineLimit }
            guard activateStatus == 201 else { return .invalid(code: "ACTIVATE_HTTP_\(activateStatus)") }

            let second: ValidateResponse
            do { second = try await validateKey(key, fingerprint: fingerprint) }
            catch { return .networkError(error.localizedDescription) }
            if (second.meta?.valid ?? false) && (second.meta?.code ?? "") == "VALID" {
                let lid = second.data?.id ?? licenseID, exp = second.data?.attributes?.expiry
                await LicenseController.shared.persist(key: key, licenseID: lid, expiry: exp, policyID: policyID(from: key))
                return .activated(key: key, licenseID: lid, expiry: exp)
            }
            return .invalid(code: second.meta?.code ?? "REVALIDATE_FAILED")

        case "EXPIRED":
            return .expired
        default:
            return .invalid(code: code.isEmpty ? "UNKNOWN" : code)
        }
    }

    // MARK: Keygen calls

    private static func validateKey(_ key: String, fingerprint: String) async throws -> ValidateResponse {
        guard let url = URL(string: "\(KeygenConfig.apiBaseURL)/licenses/actions/validate-key") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        req.httpMethod = "POST"
        apiHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let body: [String: Any] = ["meta": ["key": key, "scope": ["fingerprint": fingerprint]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(ValidateResponse.self, from: data)
    }

    /// Returns the HTTP status code (201 = activated, 422 = machine limit, else error).
    private static func activateMachine(key: String, fingerprint: String, licenseID: String) async throws -> Int {
        guard let url = URL(string: "\(KeygenConfig.apiBaseURL)/machines") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        req.httpMethod = "POST"
        apiHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("License \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "data": [
                "type": "machines",
                "attributes": ["fingerprint": fingerprint],
                "relationships": ["license": ["data": ["type": "licenses", "id": licenseID]]]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: req)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }
}

extension LicenseManager {
    /// Offline-verify a Keygen ED25519_SIGN license key against the baked-in public key.
    /// Proves the key is authentically Keygen-signed and untampered. Does NOT check
    /// expiry or revocation (separate concerns). Returns true iff the signature is valid.
    static func verifyLicenseKey(_ key: String) -> Bool {
        // key format: "key/<payloadBase64>.<signatureBase64url>"
        guard key.hasPrefix("key/") else { return false }
        let body = String(key.dropFirst("key/".count))           // "<payload>.<sig>"
        guard let dot = body.firstIndex(of: ".") else { return false }
        let payloadB64 = String(body[..<dot])
        let sigB64url  = String(body[body.index(after: dot)...])

        // Signed message = literal "key/<payload>" (prefix INCLUDED), raw UTF-8.
        let message = Data(("key/" + payloadB64).utf8)

        guard let signature = base64urlDecode(sigB64url),
              let pubKeyData = hexDecode(KeygenConfig.verifyPublicKeyHex),
              let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyData)
        else { return false }

        return pubKey.isValidSignature(signature, for: message)
    }

    /// Decode base64url (with or without padding) to Data.
    private static func base64urlDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        let pad = b.count % 4
        if pad != 0 { b += String(repeating: "=", count: 4 - pad) }
        return Data(base64Encoded: b)
    }

    /// Extract the Keygen policy id from a license key's embedded payload
    /// ("key/<base64 payload>.<sig>" → payload JSON → policy.id). nil if unreadable.
    static func policyID(from key: String) -> String? {
        guard key.hasPrefix("key/") else { return nil }
        let body = String(key.dropFirst("key/".count))
        let payloadB64 = String(body.prefix(while: { $0 != "." }))
        guard let data = Data(base64Encoded: payloadB64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let policy = json["policy"] as? [String: Any],
              let id = policy["id"] as? String else {
            return nil
        }
        return id
    }

    /// Decode a hex string to Data (nil if malformed).
    private static func hexDecode(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data
    }
}
