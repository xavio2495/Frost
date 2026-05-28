// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Caveats} from "../Caveats.sol";

/// @title IMandate — minimum surface needed by Settlement and Revocation.
/// @notice Full spec in contract-architecture.md §3. Functions here are
///         the ones Settlement.settle calls; the issuance side is intentionally
///         omitted from this interface so Settlement does not depend on it.
interface IMandate {
    /// @notice Mirrors §3.2 MandateData fields needed at query time.
    struct MandateView {
        address issuer;
        address holder;
        bytes32 parentMandateId;
        uint64 issuedAt;
        bool revoked;
        uint256 cumulativeSpend;
    }

    /// @notice Reason codes returned by validateMandateForOperation (§3.3).
    ///         OK = 0 keeps the (bool, uint8) success path zero-cost to interpret.
    enum InvalidReason {
        OK,
        NotFound,
        Revoked,
        Expired,
        CapabilityNotPermitted,
        ProviderNotPermitted,
        TargetNotPermitted,
        SpendCapTotalExceeded,
        SpendCapPerCallExceeded,
        RateLimited,
        SlippageExceeded,
        GasPriceExceeded,
        AncestorRevoked,
        Unknown
    }

    /// @notice Core authorization check (§3.3). Side-effectful: consumes a
    ///         rate-limit token on success and bumps cumulativeSpend.
    /// @param mandateId        Target mandate.
    /// @param operationType    bytes32 capability identifier from §2.3.
    /// @param target           Address being interacted with (provider for x402,
    ///                         contract for on-chain execution).
    /// @param amount           USDC-denominated value of the operation (6 decimals).
    /// @param contextRef       Optional context plane reference; bytes32(0) when unused.
    /// @return valid           True iff every caveat permits the operation.
    /// @return reason          OK on success; otherwise the first failing check.
    function validateMandateForOperation(
        bytes32 mandateId,
        bytes32 operationType,
        address target,
        uint256 amount,
        bytes32 contextRef
    ) external returns (bool valid, InvalidReason reason);

    /// @notice Read-only mandate metadata. Reverts if mandateId unknown.
    function getMandate(bytes32 mandateId) external view returns (MandateView memory);

    /// @notice Returns the stored (intersected) caveats for inspection. Bounded by
    ///         MAX_CAVEATS_PER_MANDATE so callers can read without unbounded gas.
    function getCaveats(bytes32 mandateId) external view returns (Caveats.Caveat[] memory);
}
