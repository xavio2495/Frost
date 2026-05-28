// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IProviderRegistry — minimum surface needed by Settlement.
/// @notice Full spec in contract-architecture.md §7.
interface IProviderRegistry {
    /// @notice True iff `provider` is currently in the active allowlist.
    function isApproved(address provider) external view returns (bool);
}
