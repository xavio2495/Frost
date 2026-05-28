// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IRevocation — minimum surface needed by Settlement.
/// @notice Full spec in contract-architecture.md §8.
interface IRevocation {
    /// @notice Block at which revocation was recorded; 0 means not revoked.
    ///         Settlement uses this with REVOCATION_LATENCY_BLOCKS to enforce I-04.
    function revokedAtBlock(bytes32 mandateId) external view returns (uint64);

    /// @notice True iff this specific mandate has been marked revoked.
    function isRevoked(bytes32 mandateId) external view returns (bool);

    /// @notice True iff mandate or any ancestor in the chain is revoked.
    ///         Walks via DelegationRegistry, bounded by MAX_DELEGATION_DEPTH.
    function isAncestorRevoked(bytes32 mandateId) external view returns (bool);

    /// @notice Returns the revocation block of the nearest revoked ancestor (or this
    ///         mandate). Returns 0 if no ancestor is revoked. Used by Settlement to
    ///         determine whether the REVOCATION_LATENCY_BLOCKS grace period has
    ///         elapsed for the WHOLE chain, not just the leaf.
    function nearestRevokedAtBlock(bytes32 mandateId) external view returns (uint64);
}
