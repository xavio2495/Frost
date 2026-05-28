// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Caveats} from "../src/Caveats.sol";

/// @title Caveats library tests.
/// @notice Pins the intersection rules of contract-architecture.md §2 with
///         both round-trip encoders and property-based fuzz on every type.
///         Property targets: I-01 (intersection bounded by parent), I-14
///         (HITL inverted direction), I-15 (slippage & gas-price narrow),
///         I-17 (callable-surface narrows).
/// @dev External dispatch wrappers so `vm.expectRevert` catches reverts inside
///      `Caveats`'s internal library functions. Without this, the library calls
///      are inlined and revert at the same depth as the test, so the cheatcode
///      can't observe them.
contract CaveatsHarness {
    function assertNoDuplicates(Caveats.Caveat[] memory cs) external pure {
        Caveats.assertNoDuplicates(cs);
    }

    function intersectContextScope(bytes32 parent, bytes32 sub) external pure returns (bytes32) {
        return Caveats.intersectContextScope(parent, sub);
    }

    function intersectCommsTemplate(bytes32 parentHash, bytes memory parentMeta, bytes32 subHash)
        external
        pure
        returns (bytes32, bytes memory)
    {
        return Caveats.intersectCommsTemplate(parentHash, parentMeta, subHash);
    }

    function intersectRateLimit(
        uint256 pCap,
        uint256 pRate,
        uint256 pTok,
        uint64 pLast,
        uint256 sCap,
        uint256 sRate,
        uint256 sTok,
        uint64 sLast
    ) external pure returns (uint256, uint256, uint256, uint64) {
        return Caveats.intersectRateLimit(pCap, pRate, pTok, pLast, sCap, sRate, sTok, sLast);
    }

    function intersectMaxRedelegationDepth(uint8 parent, uint8 sub) external pure returns (uint8) {
        return Caveats.intersectMaxRedelegationDepth(parent, sub);
    }
}

contract CaveatsTest is Test {
    CaveatsHarness internal h;

    function setUp() public {
        h = new CaveatsHarness();
    }

    // ------------------------------------------------------------------
    // Encode/decode round-trips
    // ------------------------------------------------------------------

    function testFuzz_RoundTrip_SpendCapTotal(uint256 v) public pure {
        Caveats.Caveat memory c = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, v);
        assertEq(c.caveatType, Caveats.SPEND_CAP_TOTAL);
        assertEq(c.schemaVersion, Caveats.SCHEMA_VERSION_V1);
        assertEq(Caveats.decodeUint256(c), v);
    }

    function testFuzz_RoundTrip_TtlExpiry(uint64 v) public pure {
        Caveats.Caveat memory c = Caveats.encodeUint64(Caveats.TTL_EXPIRY, v);
        assertEq(Caveats.decodeUint64(c), v);
    }

    function testFuzz_RoundTrip_Slippage(uint16 v) public pure {
        Caveats.Caveat memory c = Caveats.encodeUint16(Caveats.SLIPPAGE_TOLERANCE, v);
        assertEq(Caveats.decodeUint16(c), v);
    }

    function testFuzz_RoundTrip_Depth(uint8 v) public pure {
        Caveats.Caveat memory c = Caveats.encodeUint8(Caveats.MAX_REDELEGATION_DEPTH, v);
        assertEq(Caveats.decodeUint8(c), v);
    }

    function testFuzz_RoundTrip_ContextScope(bytes32 v) public pure {
        Caveats.Caveat memory c = Caveats.encodeBytes32(Caveats.CONTEXT_SCOPE, v);
        assertEq(Caveats.decodeBytes32(c), v);
    }

    function testFuzz_RoundTrip_RateLimit(
        uint256 capacity,
        uint256 refillRate,
        uint256 currentTokens,
        uint64 lastRefill
    ) public pure {
        Caveats.Caveat memory c = Caveats.encodeRateLimit(capacity, refillRate, currentTokens, lastRefill);
        (uint256 ca, uint256 rr, uint256 ct, uint64 lr) = Caveats.decodeRateLimit(c);
        assertEq(ca, capacity);
        assertEq(rr, refillRate);
        assertEq(ct, currentTokens);
        assertEq(lr, lastRefill);
    }

    function testFuzz_RoundTrip_CapRedelegate(uint8 maxSubMandates, uint256 maxAggregateBudget) public pure {
        Caveats.Caveat memory c = Caveats.encodeCapRedelegate(maxSubMandates, maxAggregateBudget);
        (uint8 m, uint256 b) = Caveats.decodeCapRedelegate(c);
        assertEq(m, maxSubMandates);
        assertEq(b, maxAggregateBudget);
    }

    function test_RoundTrip_CallableSurface() public pure {
        Caveats.CallableSurfaceEntry[] memory in_ = new Caveats.CallableSurfaceEntry[](2);
        in_[0] = Caveats.CallableSurfaceEntry({
            target: 0x1111111111111111111111111111111111111111,
            selector: 0xaabbccdd,
            maxValue: 1_000_000
        });
        in_[1] = Caveats.CallableSurfaceEntry({
            target: 0x2222222222222222222222222222222222222222,
            selector: 0x11223344,
            maxValue: 500_000
        });
        Caveats.Caveat memory c = Caveats.encodeCallableSurface(in_);
        Caveats.CallableSurfaceEntry[] memory out = Caveats.decodeCallableSurface(c);
        assertEq(out.length, 2);
        assertEq(out[0].target, in_[0].target);
        assertEq(out[1].selector, in_[1].selector);
        assertEq(out[1].maxValue, 500_000);
    }

    function testFuzz_RoundTrip_CommsTemplate(bytes32 hash_, bytes memory meta) public pure {
        Caveats.Caveat memory c = Caveats.encodeCommsTemplate(hash_, meta);
        (bytes32 h, bytes memory m) = Caveats.decodeCommsTemplate(c);
        assertEq(h, hash_);
        assertEq(keccak256(m), keccak256(meta));
    }

    // ------------------------------------------------------------------
    // I-01: intersection ≤ parent for min-direction caveats
    // ------------------------------------------------------------------

    function testFuzz_I01_SpendCapTotal_MinDirection(uint256 parent, uint256 sub) public pure {
        uint256 r = Caveats.intersectUint256Min(parent, sub);
        assertLe(r, parent);
        assertLe(r, sub);
    }

    function testFuzz_I01_TtlExpiry_MinDirection(uint64 parent, uint64 sub) public pure {
        uint64 r = Caveats.intersectUint64Min(parent, sub);
        assertLe(uint256(r), uint256(parent));
        assertLe(uint256(r), uint256(sub));
    }

    function testFuzz_I15_Slippage_Narrows(uint16 parent, uint16 sub) public pure {
        uint16 r = Caveats.intersectUint16Min(parent, sub);
        assertLe(uint256(r), uint256(parent));
        assertLe(uint256(r), uint256(sub));
    }

    function testFuzz_I15_MaxGasPrice_Narrows(uint64 parent, uint64 sub) public pure {
        uint64 r = Caveats.intersectUint64Min(parent, sub);
        assertLe(uint256(r), uint256(parent));
        assertLe(uint256(r), uint256(sub));
    }

    // ------------------------------------------------------------------
    // I-14: HITL_THRESHOLD inverted direction
    // ------------------------------------------------------------------
    // The audit hotspot. A sub's stored HITL ≤ parent's HITL, which means
    // strictness can only INCREASE through redelegation. Any sub trying to
    // raise the threshold is silently clamped to parent — checked here.

    function testFuzz_I14_HitlThreshold_NeverWeakens(uint256 parent, uint256 sub) public pure {
        uint256 stored = Caveats.intersectHitlThreshold(parent, sub);
        // The stored value MUST be ≤ parent. Equivalent to "sub cannot raise threshold."
        assertLe(stored, parent);
    }

    function test_I14_HitlThreshold_SubLowerThanParent_KeepsSub() public pure {
        // sub=5, parent=10 → sub is stricter, stored should be 5
        uint256 stored = Caveats.intersectHitlThreshold(10, 5);
        assertEq(stored, 5);
    }

    function test_I14_HitlThreshold_SubHigherThanParent_ClampsToParent() public pure {
        // sub=20, parent=10 → sub trying to weaken, stored must be 10
        uint256 stored = Caveats.intersectHitlThreshold(10, 20);
        assertEq(stored, 10);
    }

    // ------------------------------------------------------------------
    // MAX_REDELEGATION_DEPTH — strict decrement
    // ------------------------------------------------------------------

    function testFuzz_MaxRedelegationDepth_StrictlyDecreases(uint8 parent, uint8 sub) public {
        vm.assume(parent > 0);
        uint8 r = Caveats.intersectMaxRedelegationDepth(parent, sub);
        // r must be ≤ parent-1 AND ≤ sub
        assertLe(uint256(r), uint256(parent) - 1);
        assertLe(uint256(r), uint256(sub));
    }

    function test_MaxRedelegationDepth_ZeroParentReverts() public {
        vm.expectRevert(Caveats.ZeroDepth.selector);
        h.intersectMaxRedelegationDepth(0, 5);
    }

    // ------------------------------------------------------------------
    // CAP_REDELEGATE — min on both fields
    // ------------------------------------------------------------------

    function testFuzz_CapRedelegate_MinOnBoth(uint8 pM, uint256 pB, uint8 sM, uint256 sB) public pure {
        (uint8 m, uint256 b) = Caveats.intersectCapRedelegate(pM, pB, sM, sB);
        assertLe(uint256(m), uint256(pM));
        assertLe(uint256(m), uint256(sM));
        assertLe(b, pB);
        assertLe(b, sB);
    }

    // ------------------------------------------------------------------
    // Address-set intersection
    // ------------------------------------------------------------------

    function test_ProviderWhitelist_Intersection_Subset() public pure {
        address[] memory parent = new address[](3);
        parent[0] = address(0xA);
        parent[1] = address(0xB);
        parent[2] = address(0xC);
        address[] memory sub = new address[](2);
        sub[0] = address(0xB);
        sub[1] = address(0xC);
        address[] memory r = Caveats.intersectAddressSets(parent, sub);
        assertEq(r.length, 2);
        assertEq(r[0], address(0xB));
        assertEq(r[1], address(0xC));
    }

    function test_ProviderWhitelist_Intersection_SubHasExtras_DropsThem() public pure {
        address[] memory parent = new address[](2);
        parent[0] = address(0xA);
        parent[1] = address(0xB);
        address[] memory sub = new address[](3);
        sub[0] = address(0xA);
        sub[1] = address(0x42); // not in parent
        sub[2] = address(0xB);
        address[] memory r = Caveats.intersectAddressSets(parent, sub);
        assertEq(r.length, 2);
        assertEq(r[0], address(0xA));
        assertEq(r[1], address(0xB));
    }

    function test_ProviderWhitelist_Intersection_Disjoint_Empty() public pure {
        address[] memory parent = new address[](1);
        parent[0] = address(0xA);
        address[] memory sub = new address[](1);
        sub[0] = address(0xB);
        address[] memory r = Caveats.intersectAddressSets(parent, sub);
        assertEq(r.length, 0);
    }

    // ------------------------------------------------------------------
    // CALLABLE_SURFACE (I-17) — set intersection + min(maxValue)
    // ------------------------------------------------------------------

    function test_I17_CallableSurface_MaxValueNarrows() public pure {
        Caveats.CallableSurfaceEntry[] memory parent = new Caveats.CallableSurfaceEntry[](2);
        parent[0] = Caveats.CallableSurfaceEntry({
            target: address(0xAA),
            selector: 0x11111111,
            maxValue: 100
        });
        parent[1] = Caveats.CallableSurfaceEntry({
            target: address(0xBB),
            selector: 0x22222222,
            maxValue: 200
        });
        Caveats.CallableSurfaceEntry[] memory sub = new Caveats.CallableSurfaceEntry[](2);
        sub[0] = Caveats.CallableSurfaceEntry({
            target: address(0xAA),
            selector: 0x11111111,
            maxValue: 500 // sub asks for more than parent allows
        });
        sub[1] = Caveats.CallableSurfaceEntry({
            target: address(0xCC), // not in parent → dropped
            selector: 0x33333333,
            maxValue: 999
        });
        Caveats.CallableSurfaceEntry[] memory r = Caveats.intersectCallableSurfaces(parent, sub);
        assertEq(r.length, 1);
        assertEq(r[0].target, address(0xAA));
        assertEq(r[0].selector, bytes4(0x11111111));
        assertEq(r[0].maxValue, 100, "maxValue must clamp to parent");
    }

    function testFuzz_I17_CallableSurface_ResultIsSubsetOfParent(
        uint256 nP,
        uint256 nS,
        uint64 seed
    ) public pure {
        nP = bound(nP, 0, 8);
        nS = bound(nS, 0, 8);
        Caveats.CallableSurfaceEntry[] memory parent = _buildEntries(nP, seed, 1_000_000);
        Caveats.CallableSurfaceEntry[] memory sub = _buildEntries(nS, seed ^ 0xdead, 2_000_000);
        Caveats.CallableSurfaceEntry[] memory r = Caveats.intersectCallableSurfaces(parent, sub);
        // Every entry in r must exist in parent and have maxValue ≤ parent's.
        for (uint256 i = 0; i < r.length; ++i) {
            bool found = false;
            for (uint256 j = 0; j < parent.length; ++j) {
                if (parent[j].target == r[i].target && parent[j].selector == r[i].selector) {
                    assertLe(r[i].maxValue, parent[j].maxValue);
                    found = true;
                    break;
                }
            }
            assertTrue(found, "result entry not in parent set");
        }
    }

    function _buildEntries(uint256 n, uint64 seed, uint256 maxValueCap)
        internal
        pure
        returns (Caveats.CallableSurfaceEntry[] memory out)
    {
        out = new Caveats.CallableSurfaceEntry[](n);
        for (uint256 i = 0; i < n; ++i) {
            // Restrict to a small target/selector space so intersections happen.
            uint160 targetSeed = uint160(uint256(keccak256(abi.encode(seed, i, "target"))) % 4);
            uint32 selectorSeed = uint32(uint256(keccak256(abi.encode(seed, i, "selector"))) % 4);
            uint256 maxVal = uint256(keccak256(abi.encode(seed, i, "max"))) % maxValueCap;
            out[i] = Caveats.CallableSurfaceEntry({
                target: address(targetSeed + 1),
                selector: bytes4(selectorSeed + 1),
                maxValue: maxVal
            });
        }
    }

    // ------------------------------------------------------------------
    // RATE_LIMIT intersection
    // ------------------------------------------------------------------

    function test_RateLimit_IntersectsMin() public {
        (uint256 c, uint256 r, uint256 t, uint64 l) =
            Caveats.intersectRateLimit(100, 10, 50, 1234, 200, 5, 80, 5678);
        assertEq(c, 100);
        assertEq(r, 5);
        assertEq(t, 80); // subTokens, capped at capacity (100). 80 ≤ 100.
        assertEq(uint256(l), 5678);
    }

    function test_RateLimit_TokensCapped() public {
        (uint256 c,, uint256 t,) = Caveats.intersectRateLimit(10, 10, 0, 0, 100, 100, 9999, 0);
        assertEq(c, 10);
        assertEq(t, 10); // 9999 clamped to capacity
    }

    function test_RateLimit_ZeroCapacity_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Caveats.EmptyIntersection.selector, Caveats.RATE_LIMIT));
        h.intersectRateLimit(0, 10, 0, 0, 100, 100, 0, 0);
    }

    // ------------------------------------------------------------------
    // CONTEXT_SCOPE intersection
    // ------------------------------------------------------------------

    function test_ContextScope_BothZero_Any() public pure {
        assertEq(Caveats.intersectContextScope(bytes32(0), bytes32(0)), bytes32(0));
    }

    function test_ContextScope_ParentZero_SubWins() public pure {
        bytes32 v = keccak256("root-A");
        assertEq(Caveats.intersectContextScope(bytes32(0), v), v);
    }

    function test_ContextScope_SubZero_ParentWins() public pure {
        bytes32 v = keccak256("root-B");
        assertEq(Caveats.intersectContextScope(v, bytes32(0)), v);
    }

    function test_ContextScope_Mismatch_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Caveats.EmptyIntersection.selector, Caveats.CONTEXT_SCOPE));
        h.intersectContextScope(keccak256("A"), keccak256("B"));
    }

    // ------------------------------------------------------------------
    // COMMS_TEMPLATE — sub must be in parent's set (single-template MVP: equality)
    // ------------------------------------------------------------------

    function test_CommsTemplate_Matching_Inherits() public pure {
        bytes32 h = keccak256("template-A");
        bytes memory meta = bytes("{...}");
        (bytes32 oh, bytes memory om) = Caveats.intersectCommsTemplate(h, meta, h);
        assertEq(oh, h);
        assertEq(keccak256(om), keccak256(meta));
    }

    function test_CommsTemplate_Mismatched_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(Caveats.EmptyIntersection.selector, Caveats.COMMS_TEMPLATE)
        );
        h.intersectCommsTemplate(keccak256("A"), bytes(""), keccak256("B"));
    }

    // ------------------------------------------------------------------
    // find() / assertNoDuplicates()
    // ------------------------------------------------------------------

    function test_Find_FoundAtIndex() public pure {
        Caveats.Caveat[] memory cs = new Caveats.Caveat[](3);
        cs[0] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, 100);
        cs[1] = Caveats.encodeUint64(Caveats.TTL_EXPIRY, 999);
        cs[2] = Caveats.encodeUint16(Caveats.SLIPPAGE_TOLERANCE, 50);
        (bool ok, uint256 i) = Caveats.find(cs, Caveats.TTL_EXPIRY);
        assertTrue(ok);
        assertEq(i, 1);
    }

    function test_Find_NotFound() public pure {
        Caveats.Caveat[] memory cs = new Caveats.Caveat[](1);
        cs[0] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, 100);
        (bool ok,) = Caveats.find(cs, Caveats.HITL_THRESHOLD);
        assertFalse(ok);
    }

    function test_AssertNoDuplicates_Clean() public pure {
        Caveats.Caveat[] memory cs = new Caveats.Caveat[](2);
        cs[0] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, 1);
        cs[1] = Caveats.encodeUint64(Caveats.TTL_EXPIRY, 2);
        Caveats.assertNoDuplicates(cs);
    }

    function test_AssertNoDuplicates_DupReverts() public {
        Caveats.Caveat[] memory cs = new Caveats.Caveat[](2);
        cs[0] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, 1);
        cs[1] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, 99);
        vm.expectRevert(
            abi.encodeWithSelector(Caveats.DuplicateCaveatType.selector, Caveats.SPEND_CAP_TOTAL)
        );
        h.assertNoDuplicates(cs);
    }

    function test_AssertNoDuplicates_TooManyReverts() public {
        Caveats.Caveat[] memory cs = new Caveats.Caveat[](uint256(Caveats.MAX_CAVEATS_PER_MANDATE) + 1);
        for (uint256 i = 0; i < cs.length; ++i) {
            cs[i] = Caveats.Caveat({
                caveatType: bytes4(uint32(i + 1)),
                parameters: hex"00",
                schemaVersion: 1
            });
        }
        vm.expectRevert(Caveats.TooManyCaveats.selector);
        h.assertNoDuplicates(cs);
    }
}
