// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDelegationRegistry} from "./interfaces/IDelegationRegistry.sol";
import {Caveats} from "./Caveats.sol";

/// @title DelegationRegistry — canonical on-chain index of the delegation tree.
/// @notice Per contract-architecture.md §5. Pre-computes parent/root/depth and
///         aggregate redelegation state so Settlement and Revocation don't have
///         to walk the Mandate contract per call.
///
///         Write access is gated to a single `mandateContract` address set
///         once at deployment time. Reads are public.
///
///         Threats addressed: T-09 (canonical source), T-16 (lazy revocation),
///         T-30 (aggregate redelegation enforcement).
contract DelegationRegistry is IDelegationRegistry {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error OnlyMandate();
    error MandateAlreadyRegistered(bytes32 mandateId);
    error UnknownMandate(bytes32 mandateId);
    error MandateContractAlreadySet();
    error MandateContractZero();
    error MaxDepthExceeded(uint8 depth);
    error MaxFanOutExceeded(bytes32 parentMandateId);
    error MaxSubMandatesExceeded(bytes32 parentMandateId);
    error MaxAggregateBudgetExceeded(bytes32 parentMandateId);

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event MandateRegistered(
        bytes32 indexed mandateId,
        bytes32 indexed parentMandateId,
        address indexed holder,
        uint8 depth
    );
    event MandateContractSet(address mandateContract);

    // ---------------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------------
    address public immutable admin;
    address public mandateContract;

    modifier onlyMandate() {
        if (msg.sender != mandateContract) revert OnlyMandate();
        _;
    }

    constructor(address _admin) {
        admin = _admin;
    }

    /// @notice One-time wiring of the Mandate contract that may write here.
    ///         After this returns, the binding is immutable.
    function setMandateContract(address _mandateContract) external {
        if (msg.sender != admin) revert OnlyMandate();
        if (mandateContract != address(0)) revert MandateContractAlreadySet();
        if (_mandateContract == address(0)) revert MandateContractZero();
        mandateContract = _mandateContract;
        emit MandateContractSet(_mandateContract);
    }

    // ---------------------------------------------------------------------
    // Storage (§5.2)
    // ---------------------------------------------------------------------
    mapping(bytes32 => bytes32) private _parentOf;
    mapping(bytes32 => bytes32) private _rootOf;
    mapping(bytes32 => uint8) private _depthOf;
    mapping(bytes32 => bytes32[]) private _childrenOf;
    mapping(bytes32 => bool) private _registered;
    mapping(address => bytes32[]) private _mandatesByHolder;

    mapping(bytes32 => uint8) public subMandateCount;
    mapping(bytes32 => uint256) public aggregateSubMandateBudget;

    // ---------------------------------------------------------------------
    // Write API (Mandate-only)
    // ---------------------------------------------------------------------

    /// @notice Records a new mandate in the tree. Called by Mandate during both
    ///         issueMandate (root) and issueSubMandate (child).
    /// @param mandateId             The newly issued mandate.
    /// @param parentMandateId       bytes32(0) for root mandates.
    /// @param holder                The mandate's holder address.
    /// @param subMandateSpendCap    The new mandate's SPEND_CAP_TOTAL — used by
    ///                              the registry to check parent's aggregate
    ///                              budget. Pass 0 for root mandates.
    /// @param parentMaxSubMandates  Parent's CAP_REDELEGATE.maxSubMandates (0
    ///                              for root issuance — registry will not
    ///                              enforce a fan-out cap beyond MAX_FAN_OUT).
    /// @param parentMaxAggregateBudget Parent's CAP_REDELEGATE.maxAggregateBudget.
    function registerMandate(
        bytes32 mandateId,
        bytes32 parentMandateId,
        address holder,
        uint256 subMandateSpendCap,
        uint8 parentMaxSubMandates,
        uint256 parentMaxAggregateBudget
    ) external onlyMandate {
        if (_registered[mandateId]) revert MandateAlreadyRegistered(mandateId);

        if (parentMandateId == bytes32(0)) {
            // Root mandate.
            _parentOf[mandateId] = bytes32(0);
            _rootOf[mandateId] = mandateId;
            _depthOf[mandateId] = 0;
        } else {
            if (!_registered[parentMandateId]) revert UnknownMandate(parentMandateId);

            uint8 newDepth = _depthOf[parentMandateId] + 1;
            if (newDepth > Caveats.MAX_DELEGATION_DEPTH) revert MaxDepthExceeded(newDepth);

            // Fan-out bound (I-07).
            if (_childrenOf[parentMandateId].length >= Caveats.MAX_FAN_OUT_PER_NODE) {
                revert MaxFanOutExceeded(parentMandateId);
            }

            // Aggregate bounds (I-13). subMandateCount is bumped post-check;
            // a +1 here corresponds to *this* new sub-mandate.
            uint8 currentCount = subMandateCount[parentMandateId];
            if (uint256(currentCount) + 1 > uint256(parentMaxSubMandates)) {
                revert MaxSubMandatesExceeded(parentMandateId);
            }
            uint256 nextBudget = aggregateSubMandateBudget[parentMandateId] + subMandateSpendCap;
            if (nextBudget > parentMaxAggregateBudget) {
                revert MaxAggregateBudgetExceeded(parentMandateId);
            }

            _parentOf[mandateId] = parentMandateId;
            _rootOf[mandateId] = _rootOf[parentMandateId];
            _depthOf[mandateId] = newDepth;
            _childrenOf[parentMandateId].push(mandateId);

            subMandateCount[parentMandateId] = currentCount + 1;
            aggregateSubMandateBudget[parentMandateId] = nextBudget;
        }

        _registered[mandateId] = true;
        _mandatesByHolder[holder].push(mandateId);

        emit MandateRegistered(mandateId, parentMandateId, holder, _depthOf[mandateId]);
    }

    // ---------------------------------------------------------------------
    // Read API
    // ---------------------------------------------------------------------

    function parentOf(bytes32 mandateId) external view override returns (bytes32) {
        return _parentOf[mandateId];
    }

    function rootOf(bytes32 mandateId) external view override returns (bytes32) {
        return _rootOf[mandateId];
    }

    function depthOf(bytes32 mandateId) external view override returns (uint8) {
        return _depthOf[mandateId];
    }

    function isRegistered(bytes32 mandateId) external view returns (bool) {
        return _registered[mandateId];
    }

    function childrenOf(bytes32 mandateId) external view returns (bytes32[] memory) {
        return _childrenOf[mandateId];
    }

    function mandatesByHolder(address holder) external view returns (bytes32[] memory) {
        return _mandatesByHolder[holder];
    }

    /// @notice Walks ancestor chain to determine whether `ancestor` appears
    ///         above `descendant`. Bounded by MAX_DELEGATION_DEPTH so the walk
    ///         is O(5).
    function isAncestorOf(bytes32 ancestor, bytes32 descendant)
        external
        view
        override
        returns (bool)
    {
        bytes32 cursor = _parentOf[descendant];
        // Walk at most MAX_DELEGATION_DEPTH steps. Root's parent is bytes32(0)
        // which can't be a registered mandate; loop terminates naturally.
        for (uint8 i = 0; i < Caveats.MAX_DELEGATION_DEPTH; ++i) {
            if (cursor == bytes32(0)) return false;
            if (cursor == ancestor) return true;
            cursor = _parentOf[cursor];
        }
        return false;
    }

    /// @notice Ancestor chain top-down (root → leaf's parent). Useful for
    ///         off-chain audit; not consumed on-chain by Settlement.
    function getAncestorChain(bytes32 mandateId) external view returns (bytes32[] memory chain) {
        uint8 d = _depthOf[mandateId];
        chain = new bytes32[](d);
        bytes32 cursor = _parentOf[mandateId];
        for (uint256 i = 0; i < d; ++i) {
            // Fill from the end so chain[0] is root.
            chain[d - 1 - i] = cursor;
            cursor = _parentOf[cursor];
        }
    }

    function getAggregateRedelegationState(bytes32 mandateId)
        external
        view
        override
        returns (uint8 count, uint256 budget)
    {
        return (subMandateCount[mandateId], aggregateSubMandateBudget[mandateId]);
    }
}
