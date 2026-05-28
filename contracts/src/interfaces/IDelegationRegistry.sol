// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IDelegationRegistry — ancestor-walk surface needed by Revocation and Settlement.
/// @notice Full spec in contract-architecture.md §5.
interface IDelegationRegistry {
    /// @notice Returns the parent mandate ID; bytes32(0) for root mandates.
    function parentOf(bytes32 mandateId) external view returns (bytes32);

    /// @notice Returns the root mandate ID at the top of the chain.
    function rootOf(bytes32 mandateId) external view returns (bytes32);

    /// @notice Depth in the delegation tree; 0 for root, ≤ MAX_DELEGATION_DEPTH.
    function depthOf(bytes32 mandateId) external view returns (uint8);

    /// @notice True iff `ancestor` appears anywhere on the chain from `descendant` to root.
    function isAncestorOf(bytes32 ancestor, bytes32 descendant) external view returns (bool);

    /// @notice (subMandateCount, aggregateSubMandateBudget) for parametric CAP_REDELEGATE.
    function getAggregateRedelegationState(bytes32 mandateId)
        external
        view
        returns (uint8 subMandateCount, uint256 aggregateSubMandateBudget);
}
