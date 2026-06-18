// Copyright © 2026 Remember Chaitezvi. All rights reserved.
// Part of ShowSync — Remember Live.

import Foundation

/// Static Keygen.sh account/product/policy configuration for ShowSync licensing.
/// Account: remember-africa (Dev tier). These are public identifiers + a public
/// verification key — safe to embed in the client (no secret tokens here).
enum KeygenConfig {
    /// Keygen account ID.
    static let accountID = "2d928b66-8453-423c-a190-9eb5437af043"

    /// Base URL for Keygen API requests, scoped to this account.
    static let apiBaseURL = "https://api.keygen.sh/v1/accounts/2d928b66-8453-423c-a190-9eb5437af043"

    /// Ed25519 public key (hex) for offline verification of signed licenses.
    static let verifyPublicKeyHex = "ca02219ce202e8c142dc0e581f2950927a130b4cb2ce19dc043d04b3b5b8c8ab"

    /// Product ID for ShowSync.
    static let productID = "67376482-7659-41a7-9dc3-a06152091765"

    /// Paid (perpetual) policy ID.
    static let paidPolicyID = "8762911a-d5d9-461f-8762-2b6f3078a27e"

    /// 14-day trial policy ID.
    static let trialPolicyID = "91ad570b-1563-4f1f-9533-937534585c37"

    /// Trial length in days (mirrors the Keygen trial policy duration).
    static let trialDays = 14
}
