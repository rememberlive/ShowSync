import Foundation

/// Result of a Keygen license activation/validation round-trip.
enum ActivationResult {
    case activated(licenseID: String, expiry: String?)
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
            return .activated(licenseID: first.data?.id ?? "", expiry: first.data?.attributes?.expiry)
        }

        switch code {
        case "NO_MACHINE", "NO_MACHINES":
            // Valid key, this machine not activated yet → activate, then re-validate.
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
                return .activated(licenseID: second.data?.id ?? licenseID, expiry: second.data?.attributes?.expiry)
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
