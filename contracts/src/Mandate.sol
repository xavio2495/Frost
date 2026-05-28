// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMandate} from "./interfaces/IMandate.sol";
import {IDelegationRegistry} from "./interfaces/IDelegationRegistry.sol";
import {IRevocation} from "./interfaces/IRevocation.sol";
import {Caveats} from "./Caveats.sol";
import {DelegationRegistry} from "./DelegationRegistry.sol";

/// @title Mandate — issuance, storage, and per-operation validation.
/// @notice Per contract-architecture.md §3.
///
///         State-mutating `validateMandateForOperation` is gated to a single
///         settlement consumer (set once at deployment). Issuance is open to
///         any caller acting as issuer for themselves; sub-mandate issuance
///         requires the caller to be the parent's holder.
///
///         Caveats are stored intact (the intersected list per §2.5). For
///         per-call efficiency, the dynamic RATE_LIMIT state (currentTokens,
///         lastRefill) lives in a separate mapping rather than being re-encoded
///         into the caveat bytes on every consumption — the on-disk encoding
///         shape from §2.4 is preserved in the caveat at issuance time, and the
///         decoded initial values seed `rateLimitState`.
contract Mandate is IMandate {
    using Caveats for Caveats.Caveat[];

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error NotIssuer();
    error NotParentHolder();
    error NonceAlreadyUsed(address issuer, uint256 nonce);
    error MandateAlreadyExists(bytes32 mandateId);
    error ParanoidDefaultMissing(bytes4 caveatType);
    error ParentExpired();
    error ParentLacksRedelegate();
    error ParentRateLimited();
    error EmptyIntersection(bytes4 caveatType);
    error CallerNotSettlement();
    error SettlementAlreadySet();
    error SettlementZero();
    error UnknownMandate(bytes32 mandateId);
    error CaveatsExceedLimit();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event MandateIssued(
        bytes32 indexed mandateId,
        address indexed issuer,
        address indexed holder,
        bytes32 caveatsHash
    );
    event SubMandateIssued(
        bytes32 indexed mandateId,
        bytes32 indexed parentMandateId,
        address indexed holder,
        bytes32 caveatsHash
    );
    event MandateValidated(
        bytes32 indexed mandateId, bytes32 operationHash, bool valid, IMandate.InvalidReason reason
    );
    event SettlementSet(address settlement);

    // ---------------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------------
    address public immutable admin;
    DelegationRegistry public immutable delegationRegistry;
    IRevocation public immutable revocation;
    address public settlement;

    constructor(address _admin, DelegationRegistry _registry, IRevocation _revocation) {
        admin = _admin;
        delegationRegistry = _registry;
        revocation = _revocation;
    }

    /// @notice One-time wiring. After this returns, the settlement binding is
    ///         immutable. Without this, `validateMandateForOperation` would be
    ///         open-callable and any address could grief the rate-limit bucket.
    function setSettlement(address _settlement) external {
        if (msg.sender != admin) revert CallerNotSettlement();
        if (settlement != address(0)) revert SettlementAlreadySet();
        if (_settlement == address(0)) revert SettlementZero();
        settlement = _settlement;
        emit SettlementSet(_settlement);
    }

    modifier onlySettlement() {
        if (msg.sender != settlement) revert CallerNotSettlement();
        _;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------
    struct Data {
        address issuer;
        address holder;
        bytes32 parentMandateId;
        uint64 issuedAt;
        uint256 cumulativeSpend;
    }

    struct RateLimitState {
        uint256 currentTokens;
        uint64 lastRefill;
    }

    mapping(bytes32 => Data) private _mandates;
    mapping(bytes32 => Caveats.Caveat[]) private _caveats;
    mapping(bytes32 => RateLimitState) private _rateLimit;
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    // ---------------------------------------------------------------------
    // Issuance
    // ---------------------------------------------------------------------

    /// @notice Creates a new root mandate. Caller acts as issuer.
    function issueMandate(address holder, Caveats.Caveat[] calldata requestedCaveats, uint256 nonce)
        external
        returns (bytes32 mandateId)
    {
        if (usedNonces[msg.sender][nonce]) revert NonceAlreadyUsed(msg.sender, nonce);

        Caveats.Caveat[] memory cs = _copyToMemory(requestedCaveats);

        // Paranoid defaults (§3.3).
        _enforceParanoidDefaults(cs);
        Caveats.assertNoDuplicates(cs);

        mandateId = _computeMandateId(msg.sender, holder, bytes32(0), nonce);
        if (_mandates[mandateId].issuer != address(0)) revert MandateAlreadyExists(mandateId);

        _store(mandateId, msg.sender, holder, bytes32(0), cs);
        usedNonces[msg.sender][nonce] = true;

        // §10.1 step 4: register as root with parent=0, budget=0.
        delegationRegistry.registerMandate(mandateId, bytes32(0), holder, 0, 0, 0);

        emit MandateIssued(mandateId, msg.sender, holder, _hashCaveats(_caveats[mandateId]));
    }

    /// @notice Creates a sub-mandate under an existing parent (§3.3, §10.2).
    ///         The caveats stored on the new mandate are the contract-recomputed
    ///         intersection of `requestedCaveats` with parent's caveats. Per the
    ///         spec, the contract does NOT trust the issuer's view.
    function issueSubMandate(
        bytes32 parentMandateId,
        address holder,
        Caveats.Caveat[] calldata requestedCaveats,
        uint256 nonce
    ) external returns (bytes32 mandateId) {
        Data storage parent = _mandates[parentMandateId];
        if (parent.issuer == address(0)) revert UnknownMandate(parentMandateId);
        if (msg.sender != parent.holder) revert NotParentHolder();
        if (usedNonces[msg.sender][nonce]) revert NonceAlreadyUsed(msg.sender, nonce);

        Caveats.Caveat[] storage parentCaveats = _caveats[parentMandateId];

        // Cheap pre-checks before the expensive intersection (§3.3 Rate limit note).
        _requireCapability(parentCaveats, _CAP_REDELEGATE);
        _requireNotExpired(parentCaveats);
        _requireParentRateLimitHasToken(parentMandateId, parentCaveats);
        Caveats.assertNoDuplicates(requestedCaveats);

        // Intersect every caveat type. Sub may omit a caveat the parent has;
        // in that case the parent's caveat carries through unchanged.
        Caveats.Caveat[] memory intersected = _intersectAll(parentCaveats, requestedCaveats);
        _enforceParanoidDefaults(intersected);

        mandateId = _computeMandateId(msg.sender, holder, parentMandateId, nonce);
        if (_mandates[mandateId].issuer != address(0)) revert MandateAlreadyExists(mandateId);

        _store(mandateId, msg.sender, holder, parentMandateId, intersected);
        usedNonces[msg.sender][nonce] = true;

        // Extract sub's SPEND_CAP_TOTAL + parent's CAP_REDELEGATE for the registry check.
        uint256 subSpendCap = _readSpendCapTotal(_caveats[mandateId]);
        (uint8 parentMaxSub, uint256 parentMaxBudget) = _readCapRedelegate(parentCaveats);
        delegationRegistry.registerMandate(
            mandateId, parentMandateId, holder, subSpendCap, parentMaxSub, parentMaxBudget
        );

        // Consume one parent rate-limit token AFTER registry success — the
        // atomic effects of §3.3 land together. If registry reverts, no token is
        // consumed; if it succeeds, token consumption can't fail.
        _consumeParentToken(parentMandateId, parentCaveats);

        emit SubMandateIssued(
            mandateId, parentMandateId, holder, _hashCaveats(_caveats[mandateId])
        );
    }

    // ---------------------------------------------------------------------
    // Validation (Settlement-only, state-mutating)
    // ---------------------------------------------------------------------

    function validateMandateForOperation(
        bytes32 mandateId,
        bytes32 operationType,
        address target,
        uint256 amount,
        bytes32 /* contextRef */
    ) external override onlySettlement returns (bool valid, IMandate.InvalidReason reason) {
        Data storage m = _mandates[mandateId];
        if (m.issuer == address(0)) {
            return _emitValidated(mandateId, operationType, target, amount, false, IMandate.InvalidReason.NotFound);
        }

        Caveats.Caveat[] storage cs = _caveats[mandateId];

        // 1. Expiry.
        if (_isExpired(cs)) {
            return _emitValidated(mandateId, operationType, target, amount, false, IMandate.InvalidReason.Expired);
        }

        // 2. Capability whitelist (paranoid default: must exist; checked at issuance).
        if (!_capabilityAllowed(cs, operationType)) {
            return _emitValidated(
                mandateId, operationType, target, amount, false, IMandate.InvalidReason.CapabilityNotPermitted
            );
        }

        // 3. Provider whitelist (only applies to settlement-style ops).
        if (!_providerAllowed(cs, target)) {
            return _emitValidated(
                mandateId, operationType, target, amount, false, IMandate.InvalidReason.ProviderNotPermitted
            );
        }

        // 4. Spend caps.
        uint256 perCallCap = _readSpendCapPerCall(cs);
        if (perCallCap != type(uint256).max && amount > perCallCap) {
            return _emitValidated(
                mandateId, operationType, target, amount, false, IMandate.InvalidReason.SpendCapPerCallExceeded
            );
        }
        uint256 totalCap = _readSpendCapTotal(cs);
        if (m.cumulativeSpend + amount > totalCap) {
            return _emitValidated(
                mandateId, operationType, target, amount, false, IMandate.InvalidReason.SpendCapTotalExceeded
            );
        }

        // 5. Rate limit — last check, also the only state mutation on rejection.
        if (_hasRateLimit(cs) && !_tryConsumeRateLimit(mandateId, cs)) {
            return _emitValidated(
                mandateId, operationType, target, amount, false, IMandate.InvalidReason.RateLimited
            );
        }

        // 6. Commit cumulative spend.
        m.cumulativeSpend += amount;
        return _emitValidated(mandateId, operationType, target, amount, true, IMandate.InvalidReason.OK);
    }

    function _emitValidated(
        bytes32 mandateId,
        bytes32 operationType,
        address target,
        uint256 amount,
        bool valid,
        IMandate.InvalidReason reason
    ) internal returns (bool, IMandate.InvalidReason) {
        emit MandateValidated(
            mandateId, keccak256(abi.encode(operationType, target, amount)), valid, reason
        );
        return (valid, reason);
    }

    // ---------------------------------------------------------------------
    // Read API
    // ---------------------------------------------------------------------

    function getMandate(bytes32 mandateId) external view override returns (MandateView memory v) {
        Data storage m = _mandates[mandateId];
        v.issuer = m.issuer;
        v.holder = m.holder;
        v.parentMandateId = m.parentMandateId;
        v.issuedAt = m.issuedAt;
        v.revoked = m.issuer != address(0) && revocation.isAncestorRevoked(mandateId);
        v.cumulativeSpend = m.cumulativeSpend;
    }

    function getCaveats(bytes32 mandateId) external view override returns (Caveats.Caveat[] memory) {
        return _caveats[mandateId];
    }

    function getRateLimitState(bytes32 mandateId) external view returns (uint256, uint64) {
        RateLimitState storage s = _rateLimit[mandateId];
        return (s.currentTokens, s.lastRefill);
    }

    // ---------------------------------------------------------------------
    // Internals — paranoid defaults
    // ---------------------------------------------------------------------

    bytes32 internal constant _CAP_REDELEGATE = keccak256("CAP_REDELEGATE");

    /// @dev Per §3.3: a mandate without CAPABILITY_WHITELIST or SPEND_CAP_TOTAL
    ///      is malformed. CAPABILITY_WHITELIST also enforces the §2.2 paranoid
    ///      default that an absent caveat denies everything.
    function _enforceParanoidDefaults(Caveats.Caveat[] memory cs) internal pure {
        (bool hasCap,) = Caveats.find(cs, Caveats.CAPABILITY_WHITELIST);
        if (!hasCap) revert ParanoidDefaultMissing(Caveats.CAPABILITY_WHITELIST);
        (bool hasSpend,) = Caveats.find(cs, Caveats.SPEND_CAP_TOTAL);
        if (!hasSpend) revert ParanoidDefaultMissing(Caveats.SPEND_CAP_TOTAL);
        if (cs.length > Caveats.MAX_CAVEATS_PER_MANDATE) revert CaveatsExceedLimit();
    }

    /// @dev Copies a calldata array of caveats into memory so internal helpers
    ///      that take `memory` parameters can consume it. Solidity does not
    ///      implicitly convert calldata struct arrays containing dynamic
    ///      fields (`bytes parameters`) to memory.
    function _copyToMemory(Caveats.Caveat[] calldata cs)
        internal
        pure
        returns (Caveats.Caveat[] memory out)
    {
        out = new Caveats.Caveat[](cs.length);
        for (uint256 i = 0; i < cs.length; ++i) {
            out[i] = cs[i];
        }
    }

    // ---------------------------------------------------------------------
    // Internals — readers
    // ---------------------------------------------------------------------

    function _readSpendCapTotal(Caveats.Caveat[] storage cs) internal view returns (uint256) {
        for (uint256 i = 0; i < cs.length; ++i) {
            if (cs[i].caveatType == Caveats.SPEND_CAP_TOTAL) {
                return abi.decode(cs[i].parameters, (uint256));
            }
        }
        return type(uint256).max; // unreachable past paranoid-default
    }

    function _readSpendCapPerCall(Caveats.Caveat[] storage cs) internal view returns (uint256) {
        for (uint256 i = 0; i < cs.length; ++i) {
            if (cs[i].caveatType == Caveats.SPEND_CAP_PER_CALL) {
                return abi.decode(cs[i].parameters, (uint256));
            }
        }
        return type(uint256).max;
    }

    function _readCapRedelegate(Caveats.Caveat[] storage cs)
        internal
        view
        returns (uint8 maxSub, uint256 maxBudget)
    {
        for (uint256 i = 0; i < cs.length; ++i) {
            if (cs[i].caveatType == Caveats.CAP_REDELEGATE) {
                return abi.decode(cs[i].parameters, (uint8, uint256));
            }
        }
        return (0, 0);
    }

    function _isExpired(Caveats.Caveat[] storage cs) internal view returns (bool) {
        for (uint256 i = 0; i < cs.length; ++i) {
            if (cs[i].caveatType == Caveats.TTL_EXPIRY) {
                uint64 exp = abi.decode(cs[i].parameters, (uint64));
                return block.timestamp >= uint256(exp);
            }
        }
        return false;
    }

    function _capabilityAllowed(Caveats.Caveat[] storage cs, bytes32 op) internal view returns (bool) {
        for (uint256 i = 0; i < cs.length; ++i) {
            if (cs[i].caveatType == Caveats.CAPABILITY_WHITELIST) {
                bytes32[] memory caps = abi.decode(cs[i].parameters, (bytes32[]));
                for (uint256 j = 0; j < caps.length; ++j) {
                    if (caps[j] == op) return true;
                }
                return false;
            }
        }
        return false;
    }

    function _providerAllowed(Caveats.Caveat[] storage cs, address target) internal view returns (bool) {
        for (uint256 i = 0; i < cs.length; ++i) {
            if (cs[i].caveatType == Caveats.PROVIDER_WHITELIST) {
                address[] memory list = abi.decode(cs[i].parameters, (address[]));
                for (uint256 j = 0; j < list.length; ++j) {
                    if (list[j] == target) return true;
                }
                return false;
            }
        }
        // No PROVIDER_WHITELIST caveat → provider check is open (only the
        // CAPABILITY_WHITELIST gates the operation in that case).
        return true;
    }

    function _hasRateLimit(Caveats.Caveat[] storage cs) internal view returns (bool) {
        for (uint256 i = 0; i < cs.length; ++i) {
            if (cs[i].caveatType == Caveats.RATE_LIMIT) return true;
        }
        return false;
    }

    function _requireCapability(Caveats.Caveat[] storage cs, bytes32 op) internal view {
        if (!_capabilityAllowed(cs, op)) revert ParentLacksRedelegate();
    }

    function _requireNotExpired(Caveats.Caveat[] storage cs) internal view {
        if (_isExpired(cs)) revert ParentExpired();
    }

    // ---------------------------------------------------------------------
    // Internals — rate-limit token bucket (§2.4)
    // ---------------------------------------------------------------------

    /// @dev Per §2.4: tokens refill at refillRate per second, saturate at
    ///      capacity. Overflow in `delta * refillRate` saturates to capacity
    ///      rather than reverting (the "lastRefill far in the past" case).
    function _refilledTokens(uint256 current, uint64 lastRefill, uint256 refillRate, uint256 capacity)
        internal
        view
        returns (uint256)
    {
        if (current >= capacity) return capacity;
        if (refillRate == 0) return current;
        uint256 delta = block.timestamp - uint256(lastRefill);
        uint256 added;
        unchecked {
            added = delta * refillRate;
            if (delta != 0 && added / delta != refillRate) return capacity; // overflow
        }
        uint256 sum;
        unchecked {
            sum = current + added;
            if (sum < current) return capacity;
        }
        return sum >= capacity ? capacity : sum;
    }

    function _requireParentRateLimitHasToken(bytes32 mandateId, Caveats.Caveat[] storage cs)
        internal
        view
    {
        for (uint256 i = 0; i < cs.length; ++i) {
            if (cs[i].caveatType == Caveats.RATE_LIMIT) {
                (uint256 capacity, uint256 refillRate,,) =
                    abi.decode(cs[i].parameters, (uint256, uint256, uint256, uint64));
                RateLimitState storage s = _rateLimit[mandateId];
                uint256 refilled = _refilledTokens(s.currentTokens, s.lastRefill, refillRate, capacity);
                if (refilled < 1) revert ParentRateLimited();
                return;
            }
        }
        // No RATE_LIMIT caveat → unbounded redelegation (caller chose this).
    }

    function _consumeParentToken(bytes32 mandateId, Caveats.Caveat[] storage cs) internal {
        for (uint256 i = 0; i < cs.length; ++i) {
            if (cs[i].caveatType == Caveats.RATE_LIMIT) {
                (uint256 capacity, uint256 refillRate,,) =
                    abi.decode(cs[i].parameters, (uint256, uint256, uint256, uint64));
                RateLimitState storage s = _rateLimit[mandateId];
                uint256 refilled = _refilledTokens(s.currentTokens, s.lastRefill, refillRate, capacity);
                s.currentTokens = refilled - 1;
                s.lastRefill = uint64(block.timestamp);
                return;
            }
        }
    }

    function _tryConsumeRateLimit(bytes32 mandateId, Caveats.Caveat[] storage cs) internal returns (bool) {
        for (uint256 i = 0; i < cs.length; ++i) {
            if (cs[i].caveatType == Caveats.RATE_LIMIT) {
                (uint256 capacity, uint256 refillRate,,) =
                    abi.decode(cs[i].parameters, (uint256, uint256, uint256, uint64));
                RateLimitState storage s = _rateLimit[mandateId];
                uint256 refilled = _refilledTokens(s.currentTokens, s.lastRefill, refillRate, capacity);
                if (refilled < 1) return false;
                s.currentTokens = refilled - 1;
                s.lastRefill = uint64(block.timestamp);
                return true;
            }
        }
        return true;
    }

    // ---------------------------------------------------------------------
    // Internals — intersection of every caveat type
    // ---------------------------------------------------------------------

    /// @dev Intersection rule: if sub omits a caveat type the parent has, the
    ///      parent's caveat is inherited as-is (parent restriction continues).
    ///      If sub has a caveat type parent doesn't have, it's added (sub may
    ///      ADD restrictions). Otherwise the type-specific intersection rule
    ///      from §2.2 applies.
    function _intersectAll(Caveats.Caveat[] storage parent, Caveats.Caveat[] calldata sub)
        internal
        view
        returns (Caveats.Caveat[] memory out)
    {
        // Collect every caveat type that appears in either side.
        bytes4[] memory types = new bytes4[](parent.length + sub.length);
        uint256 nTypes;
        for (uint256 i = 0; i < parent.length; ++i) {
            types[nTypes++] = parent[i].caveatType;
        }
        for (uint256 i = 0; i < sub.length; ++i) {
            bytes4 t = sub[i].caveatType;
            bool seen = false;
            for (uint256 j = 0; j < nTypes; ++j) {
                if (types[j] == t) {
                    seen = true;
                    break;
                }
            }
            if (!seen) types[nTypes++] = t;
        }

        out = new Caveats.Caveat[](nTypes);
        for (uint256 i = 0; i < nTypes; ++i) {
            out[i] = _intersectOne(parent, sub, types[i]);
        }
    }

    function _intersectOne(
        Caveats.Caveat[] storage parent,
        Caveats.Caveat[] calldata sub,
        bytes4 t
    ) internal view returns (Caveats.Caveat memory) {
        (bool pHas, uint256 pIdx) = _findStorage(parent, t);
        (bool sHas, uint256 sIdx) = _findCalldata(sub, t);

        // Sub-only: copy through (sub adding a restriction parent didn't impose).
        if (!pHas) return _cloneCalldata(sub[sIdx]);
        // Parent-only: inherit parent.
        if (!sHas) return _cloneStorage(parent[pIdx]);

        // Both present — type-specific intersection.
        Caveats.Caveat memory p = _cloneStorage(parent[pIdx]);
        Caveats.Caveat memory s = _cloneCalldata(sub[sIdx]);
        return _intersectPair(p, s, t);
    }

    function _intersectPair(Caveats.Caveat memory p, Caveats.Caveat memory s, bytes4 t)
        internal
        pure
        returns (Caveats.Caveat memory)
    {
        if (t == Caveats.SPEND_CAP_TOTAL || t == Caveats.SPEND_CAP_PER_CALL) {
            return Caveats.encodeUint256(
                t, Caveats.intersectUint256Min(Caveats.decodeUint256(p), Caveats.decodeUint256(s))
            );
        }
        if (t == Caveats.TTL_EXPIRY) {
            return Caveats.encodeUint64(
                t, Caveats.intersectUint64Min(Caveats.decodeUint64(p), Caveats.decodeUint64(s))
            );
        }
        if (t == Caveats.MAX_GAS_PRICE) {
            return Caveats.encodeUint64(
                t, Caveats.intersectUint64Min(Caveats.decodeUint64(p), Caveats.decodeUint64(s))
            );
        }
        if (t == Caveats.SLIPPAGE_TOLERANCE) {
            return Caveats.encodeUint16(
                t, Caveats.intersectUint16Min(Caveats.decodeUint16(p), Caveats.decodeUint16(s))
            );
        }
        if (t == Caveats.HITL_THRESHOLD) {
            return Caveats.encodeUint256(
                t, Caveats.intersectHitlThreshold(Caveats.decodeUint256(p), Caveats.decodeUint256(s))
            );
        }
        if (t == Caveats.MAX_REDELEGATION_DEPTH) {
            return Caveats.encodeUint8(
                t,
                Caveats.intersectMaxRedelegationDepth(Caveats.decodeUint8(p), Caveats.decodeUint8(s))
            );
        }
        if (t == Caveats.CONTEXT_SCOPE) {
            return Caveats.encodeBytes32(
                t, Caveats.intersectContextScope(Caveats.decodeBytes32(p), Caveats.decodeBytes32(s))
            );
        }
        if (t == Caveats.PROVIDER_WHITELIST) {
            address[] memory r =
                Caveats.intersectAddressSets(Caveats.decodeAddressArray(p), Caveats.decodeAddressArray(s));
            if (r.length == 0) revert EmptyIntersection(t);
            return Caveats.encodeAddressArray(t, r);
        }
        if (t == Caveats.CAPABILITY_WHITELIST) {
            bytes32[] memory r =
                Caveats.intersectBytes32Sets(Caveats.decodeBytes32Array(p), Caveats.decodeBytes32Array(s));
            if (r.length == 0) revert EmptyIntersection(t);
            return Caveats.encodeBytes32Array(t, r);
        }
        if (t == Caveats.RATE_LIMIT) {
            (uint256 pCap, uint256 pRate, uint256 pTok, uint64 pLast) = Caveats.decodeRateLimit(p);
            (uint256 sCap, uint256 sRate, uint256 sTok, uint64 sLast) = Caveats.decodeRateLimit(s);
            (uint256 cap, uint256 rate, uint256 tok, uint64 last) =
                Caveats.intersectRateLimit(pCap, pRate, pTok, pLast, sCap, sRate, sTok, sLast);
            return Caveats.encodeRateLimit(cap, rate, tok, last);
        }
        if (t == Caveats.CAP_REDELEGATE) {
            (uint8 pMax, uint256 pBudget) = Caveats.decodeCapRedelegate(p);
            (uint8 sMax, uint256 sBudget) = Caveats.decodeCapRedelegate(s);
            (uint8 mx, uint256 bg) = Caveats.intersectCapRedelegate(pMax, pBudget, sMax, sBudget);
            return Caveats.encodeCapRedelegate(mx, bg);
        }
        if (t == Caveats.CALLABLE_SURFACE) {
            Caveats.CallableSurfaceEntry[] memory r = Caveats.intersectCallableSurfaces(
                Caveats.decodeCallableSurface(p), Caveats.decodeCallableSurface(s)
            );
            if (r.length == 0) revert EmptyIntersection(t);
            return Caveats.encodeCallableSurface(r);
        }
        if (t == Caveats.COMMS_TEMPLATE) {
            (bytes32 pHash, bytes memory pMeta) = Caveats.decodeCommsTemplate(p);
            (bytes32 sHash,) = Caveats.decodeCommsTemplate(s);
            (bytes32 h, bytes memory m) = Caveats.intersectCommsTemplate(pHash, pMeta, sHash);
            return Caveats.encodeCommsTemplate(h, m);
        }
        revert Caveats.UnknownCaveatType(t);
    }

    // ---------------------------------------------------------------------
    // Internals — storage write helpers
    // ---------------------------------------------------------------------

    function _store(
        bytes32 mandateId,
        address issuer,
        address holder,
        bytes32 parentId,
        Caveats.Caveat[] memory cs
    ) internal {
        _mandates[mandateId] = Data({
            issuer: issuer,
            holder: holder,
            parentMandateId: parentId,
            issuedAt: uint64(block.timestamp),
            cumulativeSpend: 0
        });
        for (uint256 i = 0; i < cs.length; ++i) {
            _caveats[mandateId].push(cs[i]);
            if (cs[i].caveatType == Caveats.RATE_LIMIT) {
                (, , uint256 tokens, uint64 last) =
                    abi.decode(cs[i].parameters, (uint256, uint256, uint256, uint64));
                _rateLimit[mandateId] = RateLimitState({
                    currentTokens: tokens,
                    lastRefill: last == 0 ? uint64(block.timestamp) : last
                });
            }
        }
    }

    function _computeMandateId(address issuer, address holder, bytes32 parentId, uint256 nonce)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), issuer, holder, parentId, nonce));
    }

    function _hashCaveats(Caveats.Caveat[] storage cs) internal view returns (bytes32) {
        Caveats.Caveat[] memory copy = new Caveats.Caveat[](cs.length);
        for (uint256 i = 0; i < cs.length; ++i) {
            copy[i] = cs[i];
        }
        return keccak256(abi.encode(copy));
    }

    // ---------------------------------------------------------------------
    // Internals — find/clone helpers
    // ---------------------------------------------------------------------

    function _findStorage(Caveats.Caveat[] storage cs, bytes4 t) internal view returns (bool, uint256) {
        for (uint256 i = 0; i < cs.length; ++i) {
            if (cs[i].caveatType == t) return (true, i);
        }
        return (false, 0);
    }

    function _findCalldata(Caveats.Caveat[] calldata cs, bytes4 t) internal pure returns (bool, uint256) {
        for (uint256 i = 0; i < cs.length; ++i) {
            if (cs[i].caveatType == t) return (true, i);
        }
        return (false, 0);
    }

    function _cloneStorage(Caveats.Caveat storage c) internal view returns (Caveats.Caveat memory) {
        return Caveats.Caveat({
            caveatType: c.caveatType,
            parameters: c.parameters,
            schemaVersion: c.schemaVersion
        });
    }

    function _cloneCalldata(Caveats.Caveat calldata c) internal pure returns (Caveats.Caveat memory) {
        return Caveats.Caveat({
            caveatType: c.caveatType,
            parameters: c.parameters,
            schemaVersion: c.schemaVersion
        });
    }
}
