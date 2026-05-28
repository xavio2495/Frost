// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Canonical caveat schema for Frost / Port-42.
/// @notice Single source of truth for caveat encoding, validation, and intersection.
///         Tracks contract-architecture.md §2 verbatim. Any divergence between this
///         library and the spec is a critical bug class (threat T-15).
library Caveats {
    // ---------------------------------------------------------------------
    // Type identifiers (bytes4(keccak256("FROST_CAVEAT_<NAME>_V1")))
    // ---------------------------------------------------------------------
    // Stable IDs; never change a value. Adding a new caveat type means a
    // new constant. Changing semantics for an existing type means a new
    // schemaVersion bumped in the Caveat struct (§2.1).
    bytes4 internal constant SPEND_CAP_TOTAL = 0x0a4f8e8a;
    bytes4 internal constant SPEND_CAP_PER_CALL = 0x0b3c9a21;
    bytes4 internal constant PROVIDER_WHITELIST = 0x0c1e7d42;
    bytes4 internal constant CAPABILITY_WHITELIST = 0x0d2b4c63;
    bytes4 internal constant TTL_EXPIRY = 0x0e5d3b84;
    bytes4 internal constant CONTEXT_SCOPE = 0x0f6e2aa5;
    bytes4 internal constant RATE_LIMIT = 0x107f1cc6;
    bytes4 internal constant MAX_REDELEGATION_DEPTH = 0x118a0de7;
    bytes4 internal constant CAP_REDELEGATE = 0x129b1e08;
    bytes4 internal constant CALLABLE_SURFACE = 0x13ac2f29;
    bytes4 internal constant SLIPPAGE_TOLERANCE = 0x14bd304a;
    bytes4 internal constant MAX_GAS_PRICE = 0x15ce416b;
    bytes4 internal constant HITL_THRESHOLD = 0x16df528c;
    bytes4 internal constant COMMS_TEMPLATE = 0x17e063ad;

    uint16 internal constant SCHEMA_VERSION_V1 = 1;

    // ---------------------------------------------------------------------
    // Bounds (§3.4)
    // ---------------------------------------------------------------------
    uint8 internal constant MAX_DELEGATION_DEPTH = 5;
    uint8 internal constant MAX_FAN_OUT_PER_NODE = 10;
    uint8 internal constant MAX_CAVEATS_PER_MANDATE = 24;

    // ---------------------------------------------------------------------
    // Core struct (§2.1)
    // ---------------------------------------------------------------------
    struct Caveat {
        bytes4 caveatType;
        bytes parameters;
        uint16 schemaVersion;
    }

    struct CallableSurfaceEntry {
        address target;
        bytes4 selector;
        uint256 maxValue;
    }

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error UnknownCaveatType(bytes4 caveatType);
    error UnsupportedSchemaVersion(bytes4 caveatType, uint16 version);
    error TypeMismatch(bytes4 expected, bytes4 actual);
    error EmptyIntersection(bytes4 caveatType);
    error ZeroDepth();
    error DuplicateCaveatType(bytes4 caveatType);
    error TooManyCaveats();

    // ---------------------------------------------------------------------
    // Lookup helpers
    // ---------------------------------------------------------------------

    /// @notice Returns (true, index) if a caveat of `t` exists in `cs`, else (false, 0).
    ///         Per §2 the contract treats a missing caveat type as "absent."
    function find(Caveat[] memory cs, bytes4 t) internal pure returns (bool found, uint256 idx) {
        uint256 len = cs.length;
        for (uint256 i = 0; i < len; ++i) {
            if (cs[i].caveatType == t) {
                return (true, i);
            }
        }
        return (false, 0);
    }

    /// @notice Reverts with DuplicateCaveatType if any caveat type appears twice in `cs`.
    ///         §2 implies one caveat per type per mandate (intersection rules require this).
    function assertNoDuplicates(Caveat[] memory cs) internal pure {
        uint256 len = cs.length;
        if (len > MAX_CAVEATS_PER_MANDATE) revert TooManyCaveats();
        for (uint256 i = 0; i < len; ++i) {
            bytes4 t = cs[i].caveatType;
            for (uint256 j = i + 1; j < len; ++j) {
                if (cs[j].caveatType == t) revert DuplicateCaveatType(t);
            }
        }
    }

    // ---------------------------------------------------------------------
    // Encoders (typed wrappers around abi.encode)
    // ---------------------------------------------------------------------
    // Kept thin so the spec→bytecode mapping is verifiable by eye.

    function encodeUint256(bytes4 t, uint256 v) internal pure returns (Caveat memory) {
        return Caveat({caveatType: t, parameters: abi.encode(v), schemaVersion: SCHEMA_VERSION_V1});
    }

    function encodeUint64(bytes4 t, uint64 v) internal pure returns (Caveat memory) {
        return Caveat({caveatType: t, parameters: abi.encode(v), schemaVersion: SCHEMA_VERSION_V1});
    }

    function encodeUint16(bytes4 t, uint16 v) internal pure returns (Caveat memory) {
        return Caveat({caveatType: t, parameters: abi.encode(v), schemaVersion: SCHEMA_VERSION_V1});
    }

    function encodeUint8(bytes4 t, uint8 v) internal pure returns (Caveat memory) {
        return Caveat({caveatType: t, parameters: abi.encode(v), schemaVersion: SCHEMA_VERSION_V1});
    }

    function encodeBytes32(bytes4 t, bytes32 v) internal pure returns (Caveat memory) {
        return Caveat({caveatType: t, parameters: abi.encode(v), schemaVersion: SCHEMA_VERSION_V1});
    }

    function encodeAddressArray(bytes4 t, address[] memory v) internal pure returns (Caveat memory) {
        return Caveat({caveatType: t, parameters: abi.encode(v), schemaVersion: SCHEMA_VERSION_V1});
    }

    function encodeBytes32Array(bytes4 t, bytes32[] memory v) internal pure returns (Caveat memory) {
        return Caveat({caveatType: t, parameters: abi.encode(v), schemaVersion: SCHEMA_VERSION_V1});
    }

    function encodeRateLimit(uint256 capacity, uint256 refillRate, uint256 currentTokens, uint64 lastRefill)
        internal
        pure
        returns (Caveat memory)
    {
        return Caveat({
            caveatType: RATE_LIMIT,
            parameters: abi.encode(capacity, refillRate, currentTokens, lastRefill),
            schemaVersion: SCHEMA_VERSION_V1
        });
    }

    function encodeCapRedelegate(uint8 maxSubMandates, uint256 maxAggregateBudget)
        internal
        pure
        returns (Caveat memory)
    {
        return Caveat({
            caveatType: CAP_REDELEGATE,
            parameters: abi.encode(maxSubMandates, maxAggregateBudget),
            schemaVersion: SCHEMA_VERSION_V1
        });
    }

    function encodeCallableSurface(CallableSurfaceEntry[] memory entries)
        internal
        pure
        returns (Caveat memory)
    {
        return Caveat({
            caveatType: CALLABLE_SURFACE,
            parameters: abi.encode(entries),
            schemaVersion: SCHEMA_VERSION_V1
        });
    }

    function encodeCommsTemplate(bytes32 templateHash, bytes memory templateMetadata)
        internal
        pure
        returns (Caveat memory)
    {
        return Caveat({
            caveatType: COMMS_TEMPLATE,
            parameters: abi.encode(templateHash, templateMetadata),
            schemaVersion: SCHEMA_VERSION_V1
        });
    }

    // ---------------------------------------------------------------------
    // Decoders
    // ---------------------------------------------------------------------

    function decodeUint256(Caveat memory c) internal pure returns (uint256) {
        return abi.decode(c.parameters, (uint256));
    }

    function decodeUint64(Caveat memory c) internal pure returns (uint64) {
        return abi.decode(c.parameters, (uint64));
    }

    function decodeUint16(Caveat memory c) internal pure returns (uint16) {
        return abi.decode(c.parameters, (uint16));
    }

    function decodeUint8(Caveat memory c) internal pure returns (uint8) {
        return abi.decode(c.parameters, (uint8));
    }

    function decodeBytes32(Caveat memory c) internal pure returns (bytes32) {
        return abi.decode(c.parameters, (bytes32));
    }

    function decodeAddressArray(Caveat memory c) internal pure returns (address[] memory) {
        return abi.decode(c.parameters, (address[]));
    }

    function decodeBytes32Array(Caveat memory c) internal pure returns (bytes32[] memory) {
        return abi.decode(c.parameters, (bytes32[]));
    }

    function decodeRateLimit(Caveat memory c)
        internal
        pure
        returns (uint256 capacity, uint256 refillRate, uint256 currentTokens, uint64 lastRefill)
    {
        return abi.decode(c.parameters, (uint256, uint256, uint256, uint64));
    }

    function decodeCapRedelegate(Caveat memory c)
        internal
        pure
        returns (uint8 maxSubMandates, uint256 maxAggregateBudget)
    {
        return abi.decode(c.parameters, (uint8, uint256));
    }

    function decodeCallableSurface(Caveat memory c)
        internal
        pure
        returns (CallableSurfaceEntry[] memory)
    {
        return abi.decode(c.parameters, (CallableSurfaceEntry[]));
    }

    function decodeCommsTemplate(Caveat memory c)
        internal
        pure
        returns (bytes32 templateHash, bytes memory templateMetadata)
    {
        return abi.decode(c.parameters, (bytes32, bytes));
    }

    // ---------------------------------------------------------------------
    // Intersection rules (§2.5 — the I-01 enforcement point)
    // ---------------------------------------------------------------------
    //
    // For each caveat type, intersect(parent, sub) returns the contract-stored
    // sub-caveat. The caller's requested sub-caveat is the *request*; what
    // gets stored is what `intersect` produces. Per §2.5 the contract does NOT
    // trust the issuer's view — recomputation is mandatory.
    //
    // Direction convention:
    //   - Most caveats: tighter = smaller. min(parent, sub) is the standard.
    //   - HITL_THRESHOLD: tighter = smaller. But sub must already be ≤ parent;
    //     a sub-mandate cannot RAISE the threshold above parent's. We enforce
    //     this by taking max(parent, sub) on the *threshold value*, which
    //     translates to "the strictest of the two" — see §2.8 / I-14 for the
    //     full inverted-direction explanation. **DO NOT "FIX" this to min.**
    //     Audit hotspot H-11.

    function intersectUint256Min(uint256 parent, uint256 sub) internal pure returns (uint256) {
        return parent < sub ? parent : sub;
    }

    function intersectUint64Min(uint64 parent, uint64 sub) internal pure returns (uint64) {
        return parent < sub ? parent : sub;
    }

    function intersectUint16Min(uint16 parent, uint16 sub) internal pure returns (uint16) {
        return parent < sub ? parent : sub;
    }

    /// @notice HITL_THRESHOLD intersection — sub may LOWER the threshold but never raise it.
    ///         Per I-14 / §2.8: `sub_stored = min(parent, sub_requested)`.
    ///         Lower threshold = stricter (more transactions require approval).
    ///         If a sub-mandate requests a *higher* threshold than its parent, the
    ///         contract silently clamps it to the parent's value. This is intentional:
    ///         it is impossible for a sub-mandate to weaken its parent's HITL safety.
    function intersectHitlThreshold(uint256 parent, uint256 sub) internal pure returns (uint256) {
        // The "max" in the spec's "max(parent, sub)" phrasing is read as
        // "max strictness," not "max value." Strictness corresponds to lower
        // numeric value, so we return min().
        return parent < sub ? parent : sub;
    }

    /// @notice MAX_REDELEGATION_DEPTH intersection. Sub's depth ≤ parent's depth − 1.
    ///         A child cannot have equal or greater remaining depth than its parent
    ///         (otherwise depth would not strictly bound the tree).
    function intersectMaxRedelegationDepth(uint8 parent, uint8 sub) internal pure returns (uint8) {
        if (parent == 0) revert ZeroDepth();
        uint8 cap = parent - 1;
        return cap < sub ? cap : sub;
    }

    /// @notice Address-set intersection. Order-preserving on the parent set.
    function intersectAddressSets(address[] memory parent, address[] memory sub)
        internal
        pure
        returns (address[] memory out)
    {
        uint256 maxLen = parent.length < sub.length ? parent.length : sub.length;
        address[] memory buf = new address[](maxLen);
        uint256 n = 0;
        for (uint256 i = 0; i < parent.length; ++i) {
            address a = parent[i];
            for (uint256 j = 0; j < sub.length; ++j) {
                if (sub[j] == a) {
                    buf[n++] = a;
                    break;
                }
            }
        }
        out = new address[](n);
        for (uint256 k = 0; k < n; ++k) {
            out[k] = buf[k];
        }
    }

    /// @notice bytes32-set intersection.
    function intersectBytes32Sets(bytes32[] memory parent, bytes32[] memory sub)
        internal
        pure
        returns (bytes32[] memory out)
    {
        uint256 maxLen = parent.length < sub.length ? parent.length : sub.length;
        bytes32[] memory buf = new bytes32[](maxLen);
        uint256 n = 0;
        for (uint256 i = 0; i < parent.length; ++i) {
            bytes32 v = parent[i];
            for (uint256 j = 0; j < sub.length; ++j) {
                if (sub[j] == v) {
                    buf[n++] = v;
                    break;
                }
            }
        }
        out = new bytes32[](n);
        for (uint256 k = 0; k < n; ++k) {
            out[k] = buf[k];
        }
    }

    /// @notice CALLABLE_SURFACE intersection (§2.7). Set intersection on
    ///         (target, selector), min on maxValue for matched pairs. Duplicate
    ///         (target, selector) entries in `sub` are deduplicated in the result
    ///         — set semantics per the spec. Cap the buffer at parent.length
    ///         because the result is bounded by the parent's distinct surfaces.
    function intersectCallableSurfaces(
        CallableSurfaceEntry[] memory parent,
        CallableSurfaceEntry[] memory sub
    ) internal pure returns (CallableSurfaceEntry[] memory out) {
        CallableSurfaceEntry[] memory buf = new CallableSurfaceEntry[](parent.length);
        uint256 n = 0;
        for (uint256 i = 0; i < sub.length; ++i) {
            CallableSurfaceEntry memory s = sub[i];
            // Skip if already in buf (sub-side dedup).
            bool alreadyIncluded = false;
            for (uint256 k = 0; k < n; ++k) {
                if (buf[k].target == s.target && buf[k].selector == s.selector) {
                    alreadyIncluded = true;
                    break;
                }
            }
            if (alreadyIncluded) continue;
            // Match against parent.
            for (uint256 j = 0; j < parent.length; ++j) {
                CallableSurfaceEntry memory p = parent[j];
                if (p.target == s.target && p.selector == s.selector) {
                    buf[n++] = CallableSurfaceEntry({
                        target: s.target,
                        selector: s.selector,
                        maxValue: p.maxValue < s.maxValue ? p.maxValue : s.maxValue
                    });
                    break;
                }
            }
        }
        out = new CallableSurfaceEntry[](n);
        for (uint256 k = 0; k < n; ++k) {
            out[k] = buf[k];
        }
    }

    /// @notice RATE_LIMIT intersection. min on capacity and refillRate; sub-mandate
    ///         starts with a *fresh* token bucket capped at the new capacity. The
    ///         `lastRefill` field is left at the sub-requested value — the issuer
    ///         (typically Mandate.issueSubMandate) is responsible for stamping it
    ///         with block.timestamp on storage.
    function intersectRateLimit(
        uint256 parentCap,
        uint256 parentRate,
        uint256, /* parentTokens */
        uint64, /* parentLastRefill */
        uint256 subCap,
        uint256 subRate,
        uint256 subTokens,
        uint64 subLastRefill
    )
        internal
        pure
        returns (uint256 capacity, uint256 refillRate, uint256 currentTokens, uint64 lastRefill)
    {
        capacity = parentCap < subCap ? parentCap : subCap;
        refillRate = parentRate < subRate ? parentRate : subRate;
        if (capacity == 0 || refillRate == 0) revert EmptyIntersection(RATE_LIMIT);
        currentTokens = subTokens < capacity ? subTokens : capacity;
        lastRefill = subLastRefill;
    }

    /// @notice CAP_REDELEGATE intersection (§2.6). min on both fields.
    function intersectCapRedelegate(
        uint8 parentMax,
        uint256 parentBudget,
        uint8 subMax,
        uint256 subBudget
    ) internal pure returns (uint8 maxSubMandates, uint256 maxAggregateBudget) {
        maxSubMandates = parentMax < subMax ? parentMax : subMax;
        maxAggregateBudget = parentBudget < subBudget ? parentBudget : subBudget;
    }

    /// @notice COMMS_TEMPLATE intersection (§2.9 / I-16). Sub's template hash must
    ///         appear in parent's. For MVP a mandate carries at most ONE COMMS_TEMPLATE
    ///         caveat (one template per channel; multiple channels would mean multiple
    ///         caveats — currently disallowed by `assertNoDuplicates`).
    ///         Returns the parent-side metadata to ensure the sub inherits exactly
    ///         what the parent committed to.
    function intersectCommsTemplate(
        bytes32 parentHash,
        bytes memory parentMetadata,
        bytes32 subHash
    ) internal pure returns (bytes32 templateHash, bytes memory templateMetadata) {
        if (parentHash != subHash) revert EmptyIntersection(COMMS_TEMPLATE);
        return (parentHash, parentMetadata);
    }

    /// @notice CONTEXT_SCOPE intersection. For MVP, treat as equality with a
    ///         zero-sentinel meaning "any scope":
    ///           parent=0 ∧ sub=0 → 0   (no restriction)
    ///           parent=0 ∧ sub=X → X   (sub may narrow)
    ///           parent=X ∧ sub=0 → X   (sub inherits parent)
    ///           parent=X ∧ sub=Y → revert if X != Y
    function intersectContextScope(bytes32 parent, bytes32 sub) internal pure returns (bytes32) {
        if (parent == bytes32(0)) return sub;
        if (sub == bytes32(0)) return parent;
        if (parent != sub) revert EmptyIntersection(CONTEXT_SCOPE);
        return parent;
    }
}
