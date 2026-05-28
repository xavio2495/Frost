// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Mandate} from "./Mandate.sol";
import {Revocation} from "./Revocation.sol";
import {Caveats} from "./Caveats.sol";
import {IMandate} from "./interfaces/IMandate.sol";

/// @title RefillableMandate — streaming top-up primitive over Mandate.
/// @notice Per contract-architecture.md §4. Two logical objects in one record:
///         - Parent authorization (`RefillPolicy`) — the signed terms: total
///           cap, per-refill amount, threshold, min interval, holder, and the
///           caveat template every spawned active mandate carries.
///         - Active mandate — a normal root mandate created via
///           `Mandate.issueMandate`. A new mandateId is minted each refill
///           cycle (Option A, §4.2 — refill REPLACES the active mandate).
///
///         RefillableMandate is the issuer of every active mandate it spawns,
///         so it is authorized by `Revocation` (§8.3) to revoke them, and it
///         owns its own monotonic nonce scope inside `Mandate.usedNonces`.
contract RefillableMandate {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error ZeroRefillAmount();
    error PerRefillExceedsTotal();
    error ThresholdExceedsPerRefill();
    error SpendCapMismatch(uint256 expected, uint256 actual);
    error SpendCapMissing();
    error HolderZero();
    error NonceAlreadyUsed();
    error PolicyAlreadyExists();
    error UnknownPolicy(bytes32 parentAuthId);
    error PolicyRevoked(bytes32 parentAuthId);
    error TotalCapExceeded(uint256 totalRefilled, uint256 perRefillAmount, uint256 totalCap);
    error RefillTooSoon(uint64 nextEligibleAt);
    error ActiveMandateNotDepleted(uint256 remaining, uint256 refillThreshold);
    error NotPolicyUser();
    error AlreadyRevoked();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event RefillableMandateCreated(
        bytes32 indexed parentAuthId,
        bytes32 indexed activeMandateId,
        address indexed user,
        address holder,
        RefillTerms terms
    );
    event RefillExecuted(
        bytes32 indexed parentAuthId,
        bytes32 oldActiveMandateId,
        bytes32 newActiveMandateId,
        uint256 perRefillAmount,
        uint256 totalRefilled
    );
    event RefillPolicyRevoked(bytes32 indexed parentAuthId, address indexed by);

    // ---------------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------------
    Mandate public immutable mandate;
    Revocation public immutable revocation;

    constructor(Mandate _mandate, Revocation _revocation) {
        mandate = _mandate;
        revocation = _revocation;
    }

    // ---------------------------------------------------------------------
    // Storage (§4.3)
    // ---------------------------------------------------------------------

    /// @notice Calldata-friendly subset of policy terms.
    ///         `minRefillInterval == 0` is allowed and means "no time gate."
    struct RefillTerms {
        uint256 totalCap;
        uint256 perRefillAmount;
        uint256 refillThreshold;
        uint64 minRefillInterval;
    }

    /// @notice The on-chain policy record. Caveat template lives in a separate
    ///         mapping (`_caveatTemplates`) to sidestep the calldata-struct-with-
    ///         dynamic-bytes copy limitation; same pattern as Mandate._caveats.
    struct RefillPolicy {
        address user;
        address holder;
        uint256 totalCap;
        uint256 totalRefilled;
        uint256 perRefillAmount;
        uint256 refillThreshold;
        uint64 minRefillInterval;
        uint64 lastRefillTimestamp;
        bytes32 activeMandateId;
        bool revoked;
    }

    mapping(bytes32 => RefillPolicy) private _policies;
    mapping(bytes32 => Caveats.Caveat[]) private _caveatTemplates;
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    /// @dev Monotonic counter so RefillableMandate (the issuer of every active
    ///      mandate it spawns) never collides with itself in `Mandate.usedNonces`.
    uint256 private _internalNonce;

    function _nextNonce() internal returns (uint256 n) {
        unchecked {
            n = ++_internalNonce;
        }
    }

    // ---------------------------------------------------------------------
    // createRefillableMandate (§4.4)
    // ---------------------------------------------------------------------

    function createRefillableMandate(
        address holder,
        Caveats.Caveat[] calldata activeMandateCaveats,
        RefillTerms calldata terms,
        uint256 userNonce
    ) external returns (bytes32 parentAuthId, bytes32 activeMandateId) {
        // Validation (§4.4 reverts).
        if (holder == address(0)) revert HolderZero();
        if (terms.perRefillAmount == 0) revert ZeroRefillAmount();
        if (terms.perRefillAmount > terms.totalCap) revert PerRefillExceedsTotal();
        if (terms.refillThreshold > terms.perRefillAmount) revert ThresholdExceedsPerRefill();

        // Active-mandate SPEND_CAP_TOTAL must equal perRefillAmount (§4.4).
        _assertSpendCapMatches(activeMandateCaveats, terms.perRefillAmount);

        if (usedNonces[msg.sender][userNonce]) revert NonceAlreadyUsed();

        parentAuthId =
            keccak256(abi.encode(block.chainid, address(this), msg.sender, holder, userNonce));
        if (_policies[parentAuthId].user != address(0)) revert PolicyAlreadyExists();

        // Mark nonce before any external call to make this re-entrancy safe
        // on its own state (Mandate.issueMandate doesn't call back, but the
        // ordering is cheap and defensive).
        usedNonces[msg.sender][userNonce] = true;

        activeMandateId = mandate.issueMandate(holder, activeMandateCaveats, _nextNonce());

        // Populate policy. Caveats go into the separate template mapping.
        RefillPolicy storage p = _policies[parentAuthId];
        p.user = msg.sender;
        p.holder = holder;
        p.totalCap = terms.totalCap;
        p.totalRefilled = terms.perRefillAmount;
        p.perRefillAmount = terms.perRefillAmount;
        p.refillThreshold = terms.refillThreshold;
        p.minRefillInterval = terms.minRefillInterval;
        p.lastRefillTimestamp = uint64(block.timestamp);
        p.activeMandateId = activeMandateId;

        Caveats.Caveat[] storage tpl = _caveatTemplates[parentAuthId];
        for (uint256 i = 0; i < activeMandateCaveats.length; ++i) {
            tpl.push(activeMandateCaveats[i]);
        }

        emit RefillableMandateCreated(parentAuthId, activeMandateId, msg.sender, holder, terms);
    }

    // ---------------------------------------------------------------------
    // triggerRefill (§4.4 — permissionless)
    // ---------------------------------------------------------------------

    function triggerRefill(bytes32 parentAuthId) external returns (bytes32 newActiveMandateId) {
        RefillPolicy storage p = _policies[parentAuthId];
        if (p.user == address(0)) revert UnknownPolicy(parentAuthId);
        if (p.revoked) revert PolicyRevoked(parentAuthId);

        // I-03: total refilled may never exceed total cap. Load-bearing check.
        if (p.totalRefilled + p.perRefillAmount > p.totalCap) {
            revert TotalCapExceeded(p.totalRefilled, p.perRefillAmount, p.totalCap);
        }

        // Anti-griefing time gate (§4.4).
        uint64 nextEligibleAt = p.lastRefillTimestamp + p.minRefillInterval;
        if (block.timestamp < uint256(nextEligibleAt)) revert RefillTooSoon(nextEligibleAt);

        // Active mandate must be sufficiently depleted (§4.4).
        bytes32 oldActiveMandateId = p.activeMandateId;
        IMandate.MandateView memory v = mandate.getMandate(oldActiveMandateId);
        uint256 remaining =
            p.perRefillAmount > v.cumulativeSpend ? p.perRefillAmount - v.cumulativeSpend : 0;
        if (remaining >= p.refillThreshold) {
            revert ActiveMandateNotDepleted(remaining, p.refillThreshold);
        }

        // Revoke the old active mandate. Defensive: if the holder already
        // revoked it directly through Revocation.revoke, skip the call rather
        // than reverting on AlreadyRevoked.
        if (!revocation.isRevoked(oldActiveMandateId)) {
            revocation.revoke(oldActiveMandateId);
        }

        // Issue replacement via Mandate.issueMandate, using the stored template.
        // `Mandate.issueMandate` takes calldata caveats, so we re-pack from
        // storage into memory through a calldata-shaped helper.
        newActiveMandateId =
            _issueFromTemplate(parentAuthId, p.holder);

        // Effects.
        p.activeMandateId = newActiveMandateId;
        p.totalRefilled += p.perRefillAmount;
        p.lastRefillTimestamp = uint64(block.timestamp);

        emit RefillExecuted(
            parentAuthId,
            oldActiveMandateId,
            newActiveMandateId,
            p.perRefillAmount,
            p.totalRefilled
        );
    }

    /// @dev `Mandate.issueMandate` accepts `Caveats.Caveat[] calldata`. Calling
    ///      it from inside this contract with a memory array works because the
    ///      Solidity compiler will ABI-encode the memory array as part of the
    ///      external call (which is what `mandate.issueMandate(...)` performs
    ///      — it's an external call, not an internal jump). So the helper just
    ///      materialises a memory copy of the stored template and calls.
    function _issueFromTemplate(bytes32 parentAuthId, address holder)
        internal
        returns (bytes32)
    {
        Caveats.Caveat[] storage tpl = _caveatTemplates[parentAuthId];
        Caveats.Caveat[] memory mem = new Caveats.Caveat[](tpl.length);
        for (uint256 i = 0; i < tpl.length; ++i) {
            mem[i] = tpl[i];
        }
        return mandate.issueMandate(holder, mem, _nextNonce());
    }

    // ---------------------------------------------------------------------
    // revokeRefillPolicy (§4.4)
    // ---------------------------------------------------------------------

    /// @notice Stops future refills. Per §4.4 this does NOT revoke the current
    ///         active mandate — the holder can call `Revocation.revoke` directly
    ///         if they want immediate stop.
    function revokeRefillPolicy(bytes32 parentAuthId) external {
        RefillPolicy storage p = _policies[parentAuthId];
        if (p.user == address(0)) revert UnknownPolicy(parentAuthId);
        if (msg.sender != p.user) revert NotPolicyUser();
        if (p.revoked) revert AlreadyRevoked();
        p.revoked = true;
        emit RefillPolicyRevoked(parentAuthId, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Read API
    // ---------------------------------------------------------------------

    /// @notice Full policy state. Caveat template is returned via the separate
    ///         getter `getCaveatTemplate(parentAuthId)`.
    function getRefillStatus(bytes32 parentAuthId)
        external
        view
        returns (RefillPolicy memory)
    {
        return _policies[parentAuthId];
    }

    function getCaveatTemplate(bytes32 parentAuthId)
        external
        view
        returns (Caveats.Caveat[] memory)
    {
        return _caveatTemplates[parentAuthId];
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _assertSpendCapMatches(Caveats.Caveat[] calldata cs, uint256 expected) internal pure {
        for (uint256 i = 0; i < cs.length; ++i) {
            if (cs[i].caveatType == Caveats.SPEND_CAP_TOTAL) {
                uint256 actual = abi.decode(cs[i].parameters, (uint256));
                if (actual != expected) revert SpendCapMismatch(expected, actual);
                return;
            }
        }
        revert SpendCapMissing();
    }
}
