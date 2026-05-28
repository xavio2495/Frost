// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProviderRegistry} from "./interfaces/IProviderRegistry.sol";

/// @title ProviderRegistry — curated admin-managed provider allowlist.
/// @notice Per contract-architecture.md §7.
///
///         MVP-intentionally simple. The admin (a deployment-time multisig in
///         production, the deployer in tests) maintains a flat allowlist of
///         provider addresses with manifest commitments. No stake, no
///         reputation, no slashing — those land in Phase 3 when the open
///         registry ships.
///
///         `isApproved(provider)` is the only function called on the hot path
///         (Settlement.settle). It's O(1) — pure mapping lookup.
///
///         Threats addressed: T-04, T-18, T-34.
contract ProviderRegistry is IProviderRegistry {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error OnlyAdmin();
    error ProviderAlreadyApproved(address provider);
    error ProviderNotApproved(address provider);
    error ProviderZero();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event ProviderApproved(
        address indexed provider,
        bytes32 manifestHash,
        bytes32 manifestUri,
        uint8 tier,
        uint64 approvedAt
    );
    event ProviderRevoked(address indexed provider, uint64 revokedAt);

    // ---------------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------------
    address public immutable admin;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor(address _admin) {
        admin = _admin;
    }

    // ---------------------------------------------------------------------
    // Storage (§7.2)
    // ---------------------------------------------------------------------
    struct ProviderRecord {
        address providerAddress;
        bytes32 manifestHash;
        bytes32 manifestUri; // IPFS or HTTPS handle
        uint64 approvedAt;
        uint64 revokedAt;
        uint8 tier; // basic / verified / premium (future)
    }

    mapping(address => ProviderRecord) public providers;
    address[] private activeProviderList;

    // ---------------------------------------------------------------------
    // Write API (admin-only)
    // ---------------------------------------------------------------------

    /// @notice Approve a new provider or re-approve a previously-revoked one.
    ///         Reverts if the provider is currently active.
    function approveProvider(
        address provider,
        bytes32 manifestHash,
        bytes32 manifestUri,
        uint8 tier
    ) external onlyAdmin {
        if (provider == address(0)) revert ProviderZero();

        ProviderRecord storage rec = providers[provider];
        bool currentlyActive = rec.approvedAt != 0 && rec.revokedAt == 0;
        if (currentlyActive) revert ProviderAlreadyApproved(provider);

        uint64 nowTs = uint64(block.timestamp);
        rec.providerAddress = provider;
        rec.manifestHash = manifestHash;
        rec.manifestUri = manifestUri;
        rec.approvedAt = nowTs;
        rec.revokedAt = 0;
        rec.tier = tier;

        activeProviderList.push(provider);

        emit ProviderApproved(provider, manifestHash, manifestUri, tier, nowTs);
    }

    /// @notice Revoke an active provider. Reverts if not currently approved.
    function revokeProvider(address provider) external onlyAdmin {
        if (provider == address(0)) revert ProviderZero();

        ProviderRecord storage rec = providers[provider];
        bool currentlyActive = rec.approvedAt != 0 && rec.revokedAt == 0;
        if (!currentlyActive) revert ProviderNotApproved(provider);

        uint64 nowTs = uint64(block.timestamp);
        rec.revokedAt = nowTs;

        // Find-and-swap-pop. activeProviderList is small (curated MVP);
        // O(n) here is acceptable and beats maintaining an index mapping.
        uint256 len = activeProviderList.length;
        for (uint256 i = 0; i < len; ++i) {
            if (activeProviderList[i] == provider) {
                activeProviderList[i] = activeProviderList[len - 1];
                activeProviderList.pop();
                break;
            }
        }

        emit ProviderRevoked(provider, nowTs);
    }

    // ---------------------------------------------------------------------
    // Read API
    // ---------------------------------------------------------------------

    /// @notice True iff `provider` is currently in the active allowlist.
    ///         O(1) — Settlement's hot-path predicate.
    function isApproved(address provider) external view override returns (bool) {
        ProviderRecord storage rec = providers[provider];
        return rec.approvedAt != 0 && rec.revokedAt == 0;
    }

    /// @notice Returns (manifestHash, manifestUri) for `provider`. Zero values
    ///         if the provider has never been approved.
    function getManifest(address provider)
        external
        view
        returns (bytes32 manifestHash, bytes32 manifestUri)
    {
        ProviderRecord storage rec = providers[provider];
        return (rec.manifestHash, rec.manifestUri);
    }

    /// @notice Snapshot of the active allowlist. Off-chain discovery helper;
    ///         not on Settlement's hot path.
    function getActiveProviders() external view returns (address[] memory) {
        return activeProviderList;
    }
}
