// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRevocation} from "./interfaces/IRevocation.sol";
import {IDelegationRegistry} from "./interfaces/IDelegationRegistry.sol";
import {IMandate} from "./interfaces/IMandate.sol";
import {Caveats} from "./Caveats.sol";

/// @title Revocation — mark-and-sweep mandate revocation.
/// @notice Per contract-architecture.md §8.
///
///         Marks a mandate as revoked; descendants are revoked lazily via the
///         ancestor walk. Walk depth is bounded by MAX_DELEGATION_DEPTH so all
///         reads are O(5).
///
///         Threats addressed: T-02 (lazy revocation), T-16 (O(1) revocation
///         gas at the revoke call site), T-10 (revoke is callable directly by
///         the smart account, no relayer dependency).
///
///         Deployment ordering note: Mandate's constructor takes IRevocation,
///         so Revocation must deploy before Mandate. The mandate binding is
///         therefore set via a one-time admin call (`setMandate`) after Mandate
///         is deployed. Same pattern as DelegationRegistry.setMandateContract.
contract Revocation is IRevocation {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error UnknownMandate(bytes32 mandateId);
    error NotAuthorized(address caller);
    error AlreadyRevoked(bytes32 mandateId);
    error MandateAlreadySet();
    error MandateZero();
    error OnlyAdmin();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event MandateRevoked(bytes32 indexed mandateId, address indexed revokedBy, uint64 blockNumber);
    event MandateSet(address mandate);

    // ---------------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------------
    address public immutable admin;
    IDelegationRegistry public immutable delegationRegistry;
    IMandate public mandate;

    constructor(address _admin, IDelegationRegistry _registry) {
        admin = _admin;
        delegationRegistry = _registry;
    }

    /// @notice One-time wiring. Locks the mandate binding so the access-control
    ///         lookups in `revoke` can't be swapped after deployment.
    function setMandate(address _mandate) external {
        if (msg.sender != admin) revert OnlyAdmin();
        if (address(mandate) != address(0)) revert MandateAlreadySet();
        if (_mandate == address(0)) revert MandateZero();
        mandate = IMandate(_mandate);
        emit MandateSet(_mandate);
    }

    // ---------------------------------------------------------------------
    // Storage (§8.2)
    // ---------------------------------------------------------------------
    mapping(bytes32 => uint64) private _revokedAtBlock;
    mapping(bytes32 => address) public revokedBy;

    // ---------------------------------------------------------------------
    // Write API
    // ---------------------------------------------------------------------

    /// @notice Marks `mandateId` revoked. Caller must be the mandate's issuer,
    ///         the parent's holder, or the root issuer (§8.3, I-10).
    function revoke(bytes32 mandateId) external {
        IMandate.MandateView memory m = mandate.getMandate(mandateId);
        if (m.issuer == address(0)) revert UnknownMandate(mandateId);
        if (_revokedAtBlock[mandateId] != 0) revert AlreadyRevoked(mandateId);

        bool authorized = msg.sender == m.issuer;
        if (!authorized && m.parentMandateId != bytes32(0)) {
            IMandate.MandateView memory parent = mandate.getMandate(m.parentMandateId);
            authorized = msg.sender == parent.holder;
        }
        if (!authorized) {
            bytes32 root = delegationRegistry.rootOf(mandateId);
            if (root != bytes32(0) && root != mandateId) {
                IMandate.MandateView memory rootMandate = mandate.getMandate(root);
                authorized = msg.sender == rootMandate.issuer;
            }
        }
        if (!authorized) revert NotAuthorized(msg.sender);

        uint64 blockNum = uint64(block.number);
        _revokedAtBlock[mandateId] = blockNum;
        revokedBy[mandateId] = msg.sender;
        emit MandateRevoked(mandateId, msg.sender, blockNum);
    }

    // ---------------------------------------------------------------------
    // Read API (IRevocation)
    // ---------------------------------------------------------------------

    function revokedAtBlock(bytes32 mandateId) external view override returns (uint64) {
        return _revokedAtBlock[mandateId];
    }

    function isRevoked(bytes32 mandateId) external view override returns (bool) {
        return _revokedAtBlock[mandateId] != 0;
    }

    /// @notice True iff `mandateId` or any ancestor in the chain is revoked.
    ///         Walk is bounded by MAX_DELEGATION_DEPTH + 1 (the +1 covers the
    ///         leaf itself); termination on bytes32(0) when we walk past root.
    function isAncestorRevoked(bytes32 mandateId) external view override returns (bool) {
        bytes32 cursor = mandateId;
        for (uint256 i = 0; i <= Caveats.MAX_DELEGATION_DEPTH; ++i) {
            if (cursor == bytes32(0)) return false;
            if (_revokedAtBlock[cursor] != 0) return true;
            cursor = delegationRegistry.parentOf(cursor);
        }
        return false;
    }

    /// @notice Earliest revocation block across `mandateId` and its ancestors.
    ///         Returns 0 if no node in the chain is revoked.
    ///         "Nearest" = smallest non-zero block: Settlement uses this with
    ///         REVOCATION_LATENCY_BLOCKS to enforce the grace window against the
    ///         WORST-case (earliest) revocation — once any ancestor is past
    ///         grace, the whole chain is past grace.
    function nearestRevokedAtBlock(bytes32 mandateId) external view override returns (uint64) {
        bytes32 cursor = mandateId;
        uint64 nearest = 0;
        for (uint256 i = 0; i <= Caveats.MAX_DELEGATION_DEPTH; ++i) {
            if (cursor == bytes32(0)) break;
            uint64 r = _revokedAtBlock[cursor];
            if (r != 0 && (nearest == 0 || r < nearest)) nearest = r;
            cursor = delegationRegistry.parentOf(cursor);
        }
        return nearest;
    }
}
