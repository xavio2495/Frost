// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RefillableMandate} from "../src/RefillableMandate.sol";
import {Mandate} from "../src/Mandate.sol";
import {Revocation} from "../src/Revocation.sol";
import {DelegationRegistry} from "../src/DelegationRegistry.sol";
import {Caveats} from "../src/Caveats.sol";
import {IMandate} from "../src/interfaces/IMandate.sol";

/// @title RefillableMandate tests.
/// @notice Covers §4 — creation validation, refill semantics, total-cap I-03,
///         minRefillInterval, depletion threshold, permissionlessness, and
///         policy revocation. Wires the full stack (DelegationRegistry,
///         Revocation, Mandate) the same way `Revocation.t.sol` does.
contract RefillableMandateTest is Test {
    bytes32 internal constant CAP_INFERENCE_CALL = keccak256("CAP_INFERENCE_CALL");

    DelegationRegistry internal registry;
    Revocation internal revocation;
    Mandate internal mandate;
    RefillableMandate internal refillable;

    address internal admin = address(this);
    address internal settlementAddr = address(0xBABE);

    address internal user = address(0xA11CE);
    address internal holder = address(0xB0B);
    address internal provider = address(0xEEEE);
    address internal stranger = address(0xDEAD);

    function setUp() public {
        registry = new DelegationRegistry(admin);
        revocation = new Revocation(admin, registry);
        mandate = new Mandate(admin, registry, revocation);

        registry.setMandateContract(address(mandate));
        revocation.setMandate(address(mandate));
        mandate.setSettlement(settlementAddr);

        refillable = new RefillableMandate(mandate, revocation);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Active-mandate caveats sized exactly to `perRefillAmount`.
    ///      Includes CAPABILITY_WHITELIST (CAP_INFERENCE_CALL), SPEND_CAP_TOTAL,
    ///      and PROVIDER_WHITELIST so that `validateMandateForOperation` accepts
    ///      a settlement call from the test settlement address.
    function _activeCaveats(uint256 perRefillAmount)
        internal
        view
        returns (Caveats.Caveat[] memory cs)
    {
        cs = new Caveats.Caveat[](3);
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CAP_INFERENCE_CALL;
        cs[0] = Caveats.encodeBytes32Array(Caveats.CAPABILITY_WHITELIST, caps);
        cs[1] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, perRefillAmount);
        address[] memory provs = new address[](1);
        provs[0] = provider;
        cs[2] = Caveats.encodeAddressArray(Caveats.PROVIDER_WHITELIST, provs);
    }

    function _defaultTerms(uint256 totalCap, uint256 perRefillAmount)
        internal
        pure
        returns (RefillableMandate.RefillTerms memory)
    {
        return RefillableMandate.RefillTerms({
            totalCap: totalCap,
            perRefillAmount: perRefillAmount,
            refillThreshold: perRefillAmount / 10, // 10% remaining triggers refill
            minRefillInterval: 60
        });
    }

    /// @dev Deplete the current active mandate via the Settlement-prank path
    ///      until `remaining < threshold`. Returns the cumulativeSpend used.
    function _depleteActive(bytes32 parentAuthId) internal {
        RefillableMandate.RefillPolicy memory p = refillable.getRefillStatus(parentAuthId);
        // Spend exactly perRefillAmount so remaining = 0, well below any
        // threshold the test cares about.
        vm.prank(settlementAddr);
        mandate.validateMandateForOperation(
            p.activeMandateId, CAP_INFERENCE_CALL, provider, p.perRefillAmount, bytes32(0)
        );
    }

    function _create(uint256 totalCap, uint256 perRefillAmount, uint256 userNonce)
        internal
        returns (bytes32 parentAuthId, bytes32 activeMandateId)
    {
        Caveats.Caveat[] memory cs = _activeCaveats(perRefillAmount);
        RefillableMandate.RefillTerms memory terms = _defaultTerms(totalCap, perRefillAmount);
        vm.prank(user);
        (parentAuthId, activeMandateId) =
            refillable.createRefillableMandate(holder, cs, terms, userNonce);
    }

    // ------------------------------------------------------------------
    // createRefillableMandate
    // ------------------------------------------------------------------

    function test_Create_HappyPath() public {
        Caveats.Caveat[] memory cs = _activeCaveats(1_000);
        RefillableMandate.RefillTerms memory terms = _defaultTerms(10_000, 1_000);

        vm.prank(user);
        (bytes32 parentAuthId, bytes32 activeMandateId) =
            refillable.createRefillableMandate(holder, cs, terms, 1);

        RefillableMandate.RefillPolicy memory p = refillable.getRefillStatus(parentAuthId);
        assertEq(p.user, user);
        assertEq(p.holder, holder);
        assertEq(p.totalCap, 10_000);
        assertEq(p.perRefillAmount, 1_000);
        assertEq(p.totalRefilled, 1_000, "totalRefilled seeded to perRefillAmount");
        assertEq(p.refillThreshold, 100);
        assertEq(p.minRefillInterval, 60);
        assertEq(p.lastRefillTimestamp, uint64(block.timestamp));
        assertEq(p.activeMandateId, activeMandateId);
        assertFalse(p.revoked);

        // The active mandate is a real registered mandate held by `holder`.
        IMandate.MandateView memory v = mandate.getMandate(activeMandateId);
        assertEq(v.holder, holder);
        assertEq(v.issuer, address(refillable));
        assertEq(v.cumulativeSpend, 0);
    }

    function test_Create_RejectsZeroPerRefillAmount() public {
        Caveats.Caveat[] memory cs = _activeCaveats(0);
        RefillableMandate.RefillTerms memory terms = _defaultTerms(10_000, 0);
        vm.prank(user);
        vm.expectRevert(RefillableMandate.ZeroRefillAmount.selector);
        refillable.createRefillableMandate(holder, cs, terms, 1);
    }

    function test_Create_RejectsPerRefillExceedsTotal() public {
        Caveats.Caveat[] memory cs = _activeCaveats(10_000);
        RefillableMandate.RefillTerms memory terms = RefillableMandate.RefillTerms({
            totalCap: 5_000,
            perRefillAmount: 10_000,
            refillThreshold: 100,
            minRefillInterval: 60
        });
        vm.prank(user);
        vm.expectRevert(RefillableMandate.PerRefillExceedsTotal.selector);
        refillable.createRefillableMandate(holder, cs, terms, 1);
    }

    function test_Create_RejectsThresholdExceedsPerRefill() public {
        Caveats.Caveat[] memory cs = _activeCaveats(1_000);
        RefillableMandate.RefillTerms memory terms = RefillableMandate.RefillTerms({
            totalCap: 10_000,
            perRefillAmount: 1_000,
            refillThreshold: 1_500,
            minRefillInterval: 60
        });
        vm.prank(user);
        vm.expectRevert(RefillableMandate.ThresholdExceedsPerRefill.selector);
        refillable.createRefillableMandate(holder, cs, terms, 1);
    }

    function test_Create_RejectsMissingSpendCap() public {
        // Active caveats without SPEND_CAP_TOTAL — the per-refill enforcement
        // can't bind, so we reject at construction time.
        Caveats.Caveat[] memory cs = new Caveats.Caveat[](2);
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CAP_INFERENCE_CALL;
        cs[0] = Caveats.encodeBytes32Array(Caveats.CAPABILITY_WHITELIST, caps);
        address[] memory provs = new address[](1);
        provs[0] = provider;
        cs[1] = Caveats.encodeAddressArray(Caveats.PROVIDER_WHITELIST, provs);
        RefillableMandate.RefillTerms memory terms = _defaultTerms(10_000, 1_000);
        vm.prank(user);
        vm.expectRevert(RefillableMandate.SpendCapMissing.selector);
        refillable.createRefillableMandate(holder, cs, terms, 1);
    }

    function test_Create_RejectsSpendCapMismatch() public {
        // Build caveats whose SPEND_CAP_TOTAL ≠ perRefillAmount.
        Caveats.Caveat[] memory cs = _activeCaveats(500);
        RefillableMandate.RefillTerms memory terms = _defaultTerms(10_000, 1_000);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(RefillableMandate.SpendCapMismatch.selector, uint256(1_000), uint256(500))
        );
        refillable.createRefillableMandate(holder, cs, terms, 1);
    }

    function test_Create_RejectsHolderZero() public {
        Caveats.Caveat[] memory cs = _activeCaveats(1_000);
        RefillableMandate.RefillTerms memory terms = _defaultTerms(10_000, 1_000);
        vm.prank(user);
        vm.expectRevert(RefillableMandate.HolderZero.selector);
        refillable.createRefillableMandate(address(0), cs, terms, 1);
    }

    function test_Create_RejectsDuplicateParentAuthId() public {
        // Same (user, holder, userNonce) ⇒ same parentAuthId. But the first
        // call already marks userNonce used, so the second call reverts at
        // the nonce check before reaching the policy-exists check. To exercise
        // the PolicyAlreadyExists path we'd need to write to storage directly;
        // the nonce guard is the practical first line of defense and is what
        // a caller would actually hit.
        _create(10_000, 1_000, 1);
        Caveats.Caveat[] memory cs = _activeCaveats(1_000);
        RefillableMandate.RefillTerms memory terms = _defaultTerms(10_000, 1_000);
        vm.prank(user);
        vm.expectRevert(RefillableMandate.NonceAlreadyUsed.selector);
        refillable.createRefillableMandate(holder, cs, terms, 1);
    }

    function test_Create_NonceIsPerUser() public {
        // Same nonce, different user → no collision.
        _create(10_000, 1_000, 42);
        Caveats.Caveat[] memory cs = _activeCaveats(1_000);
        RefillableMandate.RefillTerms memory terms = _defaultTerms(10_000, 1_000);
        vm.prank(stranger);
        (bytes32 parentAuthId,) = refillable.createRefillableMandate(holder, cs, terms, 42);
        assertTrue(parentAuthId != bytes32(0));
    }

    // ------------------------------------------------------------------
    // triggerRefill
    // ------------------------------------------------------------------

    function test_TriggerRefill_HappyPath() public {
        (bytes32 parentAuthId, bytes32 oldActiveId) = _create(10_000, 1_000, 1);

        // Deplete the active mandate so refill is allowed.
        _depleteActive(parentAuthId);
        // Advance past minRefillInterval.
        vm.warp(block.timestamp + 61);

        vm.prank(stranger); // permissionless
        bytes32 newActiveId = refillable.triggerRefill(parentAuthId);

        assertTrue(newActiveId != oldActiveId, "refill mints a fresh mandateId");
        assertTrue(revocation.isRevoked(oldActiveId), "old mandate revoked");
        assertFalse(revocation.isRevoked(newActiveId), "new mandate live");

        RefillableMandate.RefillPolicy memory p = refillable.getRefillStatus(parentAuthId);
        assertEq(p.activeMandateId, newActiveId);
        assertEq(p.totalRefilled, 2_000, "totalRefilled bumped by perRefillAmount");
        assertEq(p.lastRefillTimestamp, uint64(block.timestamp));

        // The new mandate has zero cumulativeSpend and the full perRefillAmount cap.
        IMandate.MandateView memory v = mandate.getMandate(newActiveId);
        assertEq(v.cumulativeSpend, 0);
        assertEq(v.holder, holder);
    }

    function test_TriggerRefill_RejectsUnknownPolicy() public {
        bytes32 phantom = bytes32(uint256(0xC0FFEE));
        vm.expectRevert(abi.encodeWithSelector(RefillableMandate.UnknownPolicy.selector, phantom));
        refillable.triggerRefill(phantom);
    }

    function test_TriggerRefill_RejectsWhenActiveNotDepleted() public {
        (bytes32 parentAuthId,) = _create(10_000, 1_000, 1);
        vm.warp(block.timestamp + 61);

        // Spend less than (perRefill - threshold) → remaining stays above threshold.
        RefillableMandate.RefillPolicy memory p0 = refillable.getRefillStatus(parentAuthId);
        vm.prank(settlementAddr);
        mandate.validateMandateForOperation(
            p0.activeMandateId, CAP_INFERENCE_CALL, provider, 100, bytes32(0)
        );

        // remaining = 1000 - 100 = 900, threshold = 100. 900 >= 100 → reject.
        vm.expectRevert(
            abi.encodeWithSelector(RefillableMandate.ActiveMandateNotDepleted.selector, uint256(900), uint256(100))
        );
        refillable.triggerRefill(parentAuthId);
    }

    function test_TriggerRefill_RejectsWhenIntervalNotElapsed() public {
        (bytes32 parentAuthId,) = _create(10_000, 1_000, 1);
        _depleteActive(parentAuthId);
        // No warp — minRefillInterval=60 hasn't elapsed since creation.
        uint64 nextEligibleAt = uint64(block.timestamp) + 60;
        vm.expectRevert(
            abi.encodeWithSelector(RefillableMandate.RefillTooSoon.selector, nextEligibleAt)
        );
        refillable.triggerRefill(parentAuthId);
    }

    function test_TriggerRefill_RejectsWhenTotalCapWouldBeExceeded() public {
        // totalCap = 2*perRefillAmount → exactly one refill is permitted.
        // Initial create sets totalRefilled = 1000 (one cycle worth).
        (bytes32 parentAuthId,) = _create(2_000, 1_000, 1);

        // Cycle 1.
        _depleteActive(parentAuthId);
        vm.warp(block.timestamp + 61);
        refillable.triggerRefill(parentAuthId); // totalRefilled = 2000

        // Cycle 2 would push totalRefilled to 3000 > totalCap.
        _depleteActive(parentAuthId);
        vm.warp(block.timestamp + 61);
        vm.expectRevert(
            abi.encodeWithSelector(
                RefillableMandate.TotalCapExceeded.selector,
                uint256(2_000),
                uint256(1_000),
                uint256(2_000)
            )
        );
        refillable.triggerRefill(parentAuthId);
    }

    function test_TriggerRefill_RejectsWhenPolicyRevoked() public {
        (bytes32 parentAuthId,) = _create(10_000, 1_000, 1);
        vm.prank(user);
        refillable.revokeRefillPolicy(parentAuthId);

        _depleteActive(parentAuthId);
        vm.warp(block.timestamp + 61);
        vm.expectRevert(abi.encodeWithSelector(RefillableMandate.PolicyRevoked.selector, parentAuthId));
        refillable.triggerRefill(parentAuthId);
    }

    function test_TriggerRefill_Permissionless() public {
        (bytes32 parentAuthId,) = _create(10_000, 1_000, 1);
        _depleteActive(parentAuthId);
        vm.warp(block.timestamp + 61);
        // A truly random EOA succeeds.
        vm.prank(address(0xCAFEBABE));
        refillable.triggerRefill(parentAuthId);
        RefillableMandate.RefillPolicy memory p = refillable.getRefillStatus(parentAuthId);
        assertEq(p.totalRefilled, 2_000);
    }

    function test_TriggerRefill_HandlesAlreadyRevokedActiveMandate() public {
        // Holder revokes the active mandate externally. The next triggerRefill
        // must NOT revert on the revoke step; it should issue a fresh mandate
        // and proceed normally.
        (bytes32 parentAuthId, bytes32 oldActiveId) = _create(10_000, 1_000, 1);

        // The current active mandate's issuer is `refillable`. So the holder
        // (= parent's holder in the §8.3 auth matrix is N/A here; the active
        // mandate is a ROOT mandate, and the issuer is `refillable`). The
        // only authorized revoker is the issuer (`refillable` itself) or the
        // root issuer (also `refillable`). Therefore we route through this
        // contract by pranking as `refillable` to simulate an out-of-band
        // revocation. Equivalent to triggerRefill having raced with an admin
        // revoke pathway.
        vm.prank(address(refillable));
        revocation.revoke(oldActiveId);
        assertTrue(revocation.isRevoked(oldActiveId));

        // cumulativeSpend is still 0; force depletion by spending up to the cap.
        // But validateMandateForOperation is settlement-gated, and the mandate
        // is revoked... however validateMandateForOperation doesn't actually
        // check revocation status (that's Settlement's job). It just bumps
        // cumulative spend. So we can still drain it through the settlement
        // prank path.
        _depleteActive(parentAuthId);
        vm.warp(block.timestamp + 61);

        // triggerRefill must succeed despite the old mandate being pre-revoked.
        vm.prank(stranger);
        bytes32 newActiveId = refillable.triggerRefill(parentAuthId);
        assertTrue(newActiveId != oldActiveId);
        assertFalse(revocation.isRevoked(newActiveId));
    }

    // ------------------------------------------------------------------
    // revokeRefillPolicy
    // ------------------------------------------------------------------

    function test_RevokePolicy_HappyPath() public {
        (bytes32 parentAuthId, bytes32 activeId) = _create(10_000, 1_000, 1);
        vm.prank(user);
        refillable.revokeRefillPolicy(parentAuthId);

        RefillableMandate.RefillPolicy memory p = refillable.getRefillStatus(parentAuthId);
        assertTrue(p.revoked);

        // §4.4: the active mandate is NOT revoked by policy revocation.
        assertFalse(revocation.isRevoked(activeId));
    }

    function test_RevokePolicy_RejectsNonUser() public {
        (bytes32 parentAuthId,) = _create(10_000, 1_000, 1);
        vm.prank(stranger);
        vm.expectRevert(RefillableMandate.NotPolicyUser.selector);
        refillable.revokeRefillPolicy(parentAuthId);
    }

    function test_RevokePolicy_RejectsAlreadyRevoked() public {
        (bytes32 parentAuthId,) = _create(10_000, 1_000, 1);
        vm.prank(user);
        refillable.revokeRefillPolicy(parentAuthId);
        vm.prank(user);
        vm.expectRevert(RefillableMandate.AlreadyRevoked.selector);
        refillable.revokeRefillPolicy(parentAuthId);
    }

    function test_RevokePolicy_RejectsUnknownPolicy() public {
        bytes32 phantom = bytes32(uint256(0xC0FFEE));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(RefillableMandate.UnknownPolicy.selector, phantom));
        refillable.revokeRefillPolicy(phantom);
    }

    // ------------------------------------------------------------------
    // Property: I-03 — totalRefilled never exceeds totalCap.
    // ------------------------------------------------------------------

    function testFuzz_I03_TotalRefilledNeverExceedsTotalCap(uint128 totalCapRaw, uint64 perRaw)
        public
    {
        // Keep values modest for runtime; the property is independent of scale.
        uint256 perRefillAmount = uint256(perRaw) % 5_000 + 1; // [1, 5000]
        uint256 totalCap = uint256(totalCapRaw) % 50_000 + perRefillAmount; // ≥ perRefill
        vm.assume(perRefillAmount <= totalCap);

        Caveats.Caveat[] memory cs = _activeCaveats(perRefillAmount);
        RefillableMandate.RefillTerms memory terms = RefillableMandate.RefillTerms({
            totalCap: totalCap,
            perRefillAmount: perRefillAmount,
            refillThreshold: 1,
            minRefillInterval: 1
        });
        vm.prank(user);
        (bytes32 parentAuthId,) = refillable.createRefillableMandate(holder, cs, terms, 1);

        // Drive refills until the contract refuses on cap. Bound loop to
        // keep fuzz runtime sane.
        for (uint256 i = 0; i < 60; ++i) {
            // Invariant under test: I-03.
            RefillableMandate.RefillPolicy memory p = refillable.getRefillStatus(parentAuthId);
            assertLe(p.totalRefilled, p.totalCap, "I-03");

            _depleteActive(parentAuthId);
            vm.warp(block.timestamp + 2);

            // Try a refill. If the cap would be exceeded, the call reverts
            // and we stop. Use try/catch to detect the terminal state.
            try refillable.triggerRefill(parentAuthId) {
                // continue
            } catch {
                // Cap reached (or some other terminal). Final invariant check:
                // totalRefilled is within one perRefillAmount of totalCap.
                RefillableMandate.RefillPolicy memory pf = refillable.getRefillStatus(parentAuthId);
                assertLe(pf.totalRefilled, pf.totalCap, "I-03 terminal");
                assertGe(
                    pf.totalRefilled + pf.perRefillAmount,
                    pf.totalCap,
                    "loop should terminate near the cap"
                );
                return;
            }
        }
        // If the loop completed, we still must satisfy I-03 (it just means
        // 60 cycles weren't enough to hit the cap — fine for runtime).
        RefillableMandate.RefillPolicy memory pEnd = refillable.getRefillStatus(parentAuthId);
        assertLe(pEnd.totalRefilled, pEnd.totalCap, "I-03 end");
    }
}
