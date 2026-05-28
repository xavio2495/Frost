// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Mandate} from "../src/Mandate.sol";
import {DelegationRegistry} from "../src/DelegationRegistry.sol";
import {Caveats} from "../src/Caveats.sol";
import {IMandate} from "../src/interfaces/IMandate.sol";
import {Revocation} from "../src/Revocation.sol";

/// @title Mandate tests.
/// @notice Covers issuance (root + sub), paranoid defaults, caveat
///         intersection across types, I-02 cumulative spend, I-11 rate-limit
///         monotonicity, I-13 aggregate enforcement (integration with
///         DelegationRegistry), and validateMandateForOperation dispatch.
contract MandateTest is Test {
    bytes32 internal constant CAP_INFERENCE_CALL = keccak256("CAP_INFERENCE_CALL");
    bytes32 internal constant CAP_REDELEGATE = keccak256("CAP_REDELEGATE");
    bytes32 internal constant CAP_ONCHAIN = keccak256("CAP_ONCHAIN_EXECUTION");

    DelegationRegistry internal reg;
    Mandate internal mandate;
    Revocation internal revocation;

    address internal admin = address(this);
    address internal settlementAddr = address(0xBABE);
    address internal issuer = address(0xA11CE);
    address internal masterHolder = address(0xB0B);
    address internal subHolder = address(0xC4FE);
    address internal provider = address(0xEEEE);

    function setUp() public {
        reg = new DelegationRegistry(admin);
        revocation = new Revocation(admin, reg);
        mandate = new Mandate(admin, reg, revocation);
        reg.setMandateContract(address(mandate));
        revocation.setMandate(address(mandate));
        mandate.setSettlement(settlementAddr);
    }

    // ------------------------------------------------------------------
    // Caveat builders
    // ------------------------------------------------------------------

    function _caps(bytes32[1] memory single) internal pure returns (Caveats.Caveat memory) {
        bytes32[] memory arr = new bytes32[](1);
        arr[0] = single[0];
        return Caveats.encodeBytes32Array(Caveats.CAPABILITY_WHITELIST, arr);
    }

    function _capsArr(bytes32[] memory arr) internal pure returns (Caveats.Caveat memory) {
        return Caveats.encodeBytes32Array(Caveats.CAPABILITY_WHITELIST, arr);
    }

    function _provs(address[1] memory single) internal pure returns (Caveats.Caveat memory) {
        address[] memory arr = new address[](1);
        arr[0] = single[0];
        return Caveats.encodeAddressArray(Caveats.PROVIDER_WHITELIST, arr);
    }

    function _rootCaveats(uint256 spendCap)
        internal
        pure
        returns (Caveats.Caveat[] memory cs)
    {
        cs = new Caveats.Caveat[](2);
        bytes32[] memory caps = new bytes32[](2);
        caps[0] = CAP_INFERENCE_CALL;
        caps[1] = CAP_REDELEGATE;
        cs[0] = Caveats.encodeBytes32Array(Caveats.CAPABILITY_WHITELIST, caps);
        cs[1] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, spendCap);
    }

    // ------------------------------------------------------------------
    // issueMandate
    // ------------------------------------------------------------------

    function test_IssueMandate_HappyPath() public {
        Caveats.Caveat[] memory cs = _rootCaveats(1_000_000);
        vm.prank(issuer);
        bytes32 id = mandate.issueMandate(masterHolder, cs, 1);

        IMandate.MandateView memory v = mandate.getMandate(id);
        assertEq(v.issuer, issuer);
        assertEq(v.holder, masterHolder);
        assertEq(v.parentMandateId, bytes32(0));
        assertEq(v.cumulativeSpend, 0);
        assertFalse(v.revoked);

        // Mandate is registered in registry as root.
        assertEq(reg.parentOf(id), bytes32(0));
        assertEq(reg.rootOf(id), id);
    }

    function test_IssueMandate_NonceReuseReverts() public {
        Caveats.Caveat[] memory cs = _rootCaveats(100);
        vm.prank(issuer);
        mandate.issueMandate(masterHolder, cs, 7);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(Mandate.NonceAlreadyUsed.selector, issuer, 7));
        mandate.issueMandate(masterHolder, cs, 7);
    }

    function test_IssueMandate_MissingCapabilityWhitelistReverts() public {
        Caveats.Caveat[] memory cs = new Caveats.Caveat[](1);
        cs[0] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, 100);
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(Mandate.ParanoidDefaultMissing.selector, Caveats.CAPABILITY_WHITELIST)
        );
        mandate.issueMandate(masterHolder, cs, 1);
    }

    function test_IssueMandate_MissingSpendCapReverts() public {
        Caveats.Caveat[] memory cs = new Caveats.Caveat[](1);
        cs[0] = _caps([CAP_INFERENCE_CALL]);
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(Mandate.ParanoidDefaultMissing.selector, Caveats.SPEND_CAP_TOTAL)
        );
        mandate.issueMandate(masterHolder, cs, 1);
    }

    // ------------------------------------------------------------------
    // issueSubMandate
    // ------------------------------------------------------------------

    function _issueRootWithRedelegate(uint256 spendCap, uint8 maxSub, uint256 maxBudget)
        internal
        returns (bytes32)
    {
        Caveats.Caveat[] memory cs = new Caveats.Caveat[](3);
        bytes32[] memory caps = new bytes32[](2);
        caps[0] = CAP_INFERENCE_CALL;
        caps[1] = CAP_REDELEGATE;
        cs[0] = _capsArr(caps);
        cs[1] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, spendCap);
        cs[2] = Caveats.encodeCapRedelegate(maxSub, maxBudget);
        vm.prank(issuer);
        return mandate.issueMandate(masterHolder, cs, 100);
    }

    function _subCaveatsBudget(uint256 budget) internal pure returns (Caveats.Caveat[] memory cs) {
        cs = new Caveats.Caveat[](2);
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CAP_INFERENCE_CALL;
        cs[0] = _capsArrPure(caps);
        cs[1] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, budget);
    }

    function _capsArrPure(bytes32[] memory arr) internal pure returns (Caveats.Caveat memory) {
        return Caveats.encodeBytes32Array(Caveats.CAPABILITY_WHITELIST, arr);
    }

    function test_IssueSubMandate_HappyPath() public {
        bytes32 root = _issueRootWithRedelegate(1_000_000, 5, 100_000);
        Caveats.Caveat[] memory sub = _subCaveatsBudget(10_000);

        vm.prank(masterHolder);
        bytes32 subId = mandate.issueSubMandate(root, subHolder, sub, 1);

        IMandate.MandateView memory v = mandate.getMandate(subId);
        assertEq(v.parentMandateId, root);
        assertEq(v.holder, subHolder);

        (uint8 cnt, uint256 budget) = reg.getAggregateRedelegationState(root);
        assertEq(uint256(cnt), 1);
        assertEq(budget, 10_000);
    }

    function test_IssueSubMandate_NotParentHolderReverts() public {
        bytes32 root = _issueRootWithRedelegate(1_000_000, 5, 100_000);
        Caveats.Caveat[] memory sub = _subCaveatsBudget(10_000);
        vm.prank(address(0xDEADC0DE));
        vm.expectRevert(Mandate.NotParentHolder.selector);
        mandate.issueSubMandate(root, subHolder, sub, 1);
    }

    function test_IssueSubMandate_ParentMissingRedelegateCapReverts() public {
        // Root without CAP_REDELEGATE in capability whitelist.
        Caveats.Caveat[] memory cs = new Caveats.Caveat[](2);
        cs[0] = _caps([CAP_INFERENCE_CALL]);
        cs[1] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, 1_000_000);
        vm.prank(issuer);
        bytes32 root = mandate.issueMandate(masterHolder, cs, 200);

        Caveats.Caveat[] memory sub = _subCaveatsBudget(10_000);
        vm.prank(masterHolder);
        vm.expectRevert(Mandate.ParentLacksRedelegate.selector);
        mandate.issueSubMandate(root, subHolder, sub, 1);
    }

    function test_I13_SubMandate_BudgetExceedsAggregateReverts() public {
        bytes32 root = _issueRootWithRedelegate(1_000_000, 5, 5_000);
        Caveats.Caveat[] memory sub = _subCaveatsBudget(6_000);
        vm.prank(masterHolder);
        vm.expectRevert(
            abi.encodeWithSelector(DelegationRegistry.MaxAggregateBudgetExceeded.selector, root)
        );
        mandate.issueSubMandate(root, subHolder, sub, 1);
    }

    function test_IssueSubMandate_IntersectsSpendCapMin() public {
        bytes32 root = _issueRootWithRedelegate(50_000, 5, 100_000);
        // Sub requests 100_000 but parent has 50_000 → intersection clamps to 50_000.
        Caveats.Caveat[] memory sub = _subCaveatsBudget(100_000);
        vm.prank(masterHolder);
        bytes32 subId = mandate.issueSubMandate(root, subHolder, sub, 1);

        Caveats.Caveat[] memory stored = mandate.getCaveats(subId);
        uint256 storedCap;
        for (uint256 i = 0; i < stored.length; ++i) {
            if (stored[i].caveatType == Caveats.SPEND_CAP_TOTAL) {
                storedCap = abi.decode(stored[i].parameters, (uint256));
            }
        }
        assertEq(storedCap, 50_000, "spend cap should clamp to parent");
    }

    function test_IssueSubMandate_InheritsTtlFromParent() public {
        // Root has TTL_EXPIRY, sub does not. Sub should inherit it.
        Caveats.Caveat[] memory cs = new Caveats.Caveat[](4);
        bytes32[] memory caps = new bytes32[](2);
        caps[0] = CAP_INFERENCE_CALL;
        caps[1] = CAP_REDELEGATE;
        cs[0] = _capsArr(caps);
        cs[1] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, 100_000);
        cs[2] = Caveats.encodeCapRedelegate(5, 100_000);
        cs[3] = Caveats.encodeUint64(Caveats.TTL_EXPIRY, uint64(block.timestamp + 1 days));
        vm.prank(issuer);
        bytes32 root = mandate.issueMandate(masterHolder, cs, 300);

        Caveats.Caveat[] memory sub = _subCaveatsBudget(10_000);
        vm.prank(masterHolder);
        bytes32 subId = mandate.issueSubMandate(root, subHolder, sub, 1);

        Caveats.Caveat[] memory stored = mandate.getCaveats(subId);
        bool foundTtl = false;
        for (uint256 i = 0; i < stored.length; ++i) {
            if (stored[i].caveatType == Caveats.TTL_EXPIRY) {
                foundTtl = true;
                assertEq(abi.decode(stored[i].parameters, (uint64)), uint64(block.timestamp + 1 days));
            }
        }
        assertTrue(foundTtl, "TTL should inherit from parent");
    }

    // ------------------------------------------------------------------
    // validateMandateForOperation — access control + happy path
    // ------------------------------------------------------------------

    function _issueProviderRoot(uint256 spendCap, uint256 perCallCap) internal returns (bytes32) {
        Caveats.Caveat[] memory cs = new Caveats.Caveat[](4);
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CAP_INFERENCE_CALL;
        cs[0] = _capsArr(caps);
        cs[1] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, spendCap);
        cs[2] = Caveats.encodeUint256(Caveats.SPEND_CAP_PER_CALL, perCallCap);
        cs[3] = _provs([provider]);
        vm.prank(issuer);
        return mandate.issueMandate(masterHolder, cs, 400);
    }

    function test_Validate_OnlySettlement() public {
        bytes32 id = _issueProviderRoot(1_000, 100);
        vm.expectRevert(Mandate.CallerNotSettlement.selector);
        mandate.validateMandateForOperation(id, CAP_INFERENCE_CALL, provider, 50, bytes32(0));
    }

    function test_I02_Validate_BumpsCumulativeSpend() public {
        bytes32 id = _issueProviderRoot(1_000, 100);
        vm.prank(settlementAddr);
        (bool ok, IMandate.InvalidReason reason) =
            mandate.validateMandateForOperation(id, CAP_INFERENCE_CALL, provider, 50, bytes32(0));
        assertTrue(ok);
        assertEq(uint256(reason), uint256(IMandate.InvalidReason.OK));
        assertEq(mandate.getMandate(id).cumulativeSpend, 50);
    }

    function test_I02_Validate_RejectsWhenCumulativeWouldExceedCap() public {
        bytes32 id = _issueProviderRoot(100, 100);
        vm.prank(settlementAddr);
        mandate.validateMandateForOperation(id, CAP_INFERENCE_CALL, provider, 90, bytes32(0));
        vm.prank(settlementAddr);
        (bool ok, IMandate.InvalidReason reason) =
            mandate.validateMandateForOperation(id, CAP_INFERENCE_CALL, provider, 20, bytes32(0));
        assertFalse(ok);
        assertEq(uint256(reason), uint256(IMandate.InvalidReason.SpendCapTotalExceeded));
    }

    function test_Validate_PerCallCap() public {
        bytes32 id = _issueProviderRoot(1_000, 50);
        vm.prank(settlementAddr);
        (bool ok, IMandate.InvalidReason reason) =
            mandate.validateMandateForOperation(id, CAP_INFERENCE_CALL, provider, 51, bytes32(0));
        assertFalse(ok);
        assertEq(uint256(reason), uint256(IMandate.InvalidReason.SpendCapPerCallExceeded));
    }

    function test_Validate_CapabilityNotPermitted() public {
        bytes32 id = _issueProviderRoot(1_000, 100);
        vm.prank(settlementAddr);
        (bool ok, IMandate.InvalidReason reason) =
            mandate.validateMandateForOperation(id, CAP_ONCHAIN, provider, 10, bytes32(0));
        assertFalse(ok);
        assertEq(uint256(reason), uint256(IMandate.InvalidReason.CapabilityNotPermitted));
    }

    function test_Validate_ProviderNotPermitted() public {
        bytes32 id = _issueProviderRoot(1_000, 100);
        vm.prank(settlementAddr);
        (bool ok, IMandate.InvalidReason reason) = mandate.validateMandateForOperation(
            id, CAP_INFERENCE_CALL, address(0xBADBAD), 10, bytes32(0)
        );
        assertFalse(ok);
        assertEq(uint256(reason), uint256(IMandate.InvalidReason.ProviderNotPermitted));
    }

    function test_Validate_Expired() public {
        Caveats.Caveat[] memory cs = new Caveats.Caveat[](4);
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CAP_INFERENCE_CALL;
        cs[0] = _capsArr(caps);
        cs[1] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, 1_000);
        cs[2] = _provs([provider]);
        cs[3] = Caveats.encodeUint64(Caveats.TTL_EXPIRY, uint64(block.timestamp + 100));
        vm.prank(issuer);
        bytes32 id = mandate.issueMandate(masterHolder, cs, 500);

        vm.warp(block.timestamp + 200);
        vm.prank(settlementAddr);
        (bool ok, IMandate.InvalidReason reason) =
            mandate.validateMandateForOperation(id, CAP_INFERENCE_CALL, provider, 10, bytes32(0));
        assertFalse(ok);
        assertEq(uint256(reason), uint256(IMandate.InvalidReason.Expired));
    }

    // ------------------------------------------------------------------
    // I-11: rate-limit token bucket
    // ------------------------------------------------------------------

    function test_I11_RateLimit_TokenConsumption() public {
        Caveats.Caveat[] memory cs = new Caveats.Caveat[](4);
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CAP_INFERENCE_CALL;
        cs[0] = _capsArr(caps);
        cs[1] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, 1_000_000);
        cs[2] = _provs([provider]);
        cs[3] = Caveats.encodeRateLimit(3, 1, 3, uint64(block.timestamp));
        vm.prank(issuer);
        bytes32 id = mandate.issueMandate(masterHolder, cs, 600);

        // 3 calls in same block all succeed.
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(settlementAddr);
            (bool ok,) =
                mandate.validateMandateForOperation(id, CAP_INFERENCE_CALL, provider, 10, bytes32(0));
            assertTrue(ok, "consumption 1-3 should succeed");
        }
        // 4th in same block fails (no refill yet at refillRate=1/sec with delta=0).
        vm.prank(settlementAddr);
        (bool ok4, IMandate.InvalidReason reason) =
            mandate.validateMandateForOperation(id, CAP_INFERENCE_CALL, provider, 10, bytes32(0));
        assertFalse(ok4);
        assertEq(uint256(reason), uint256(IMandate.InvalidReason.RateLimited));

        // Warp 2 seconds → 2 tokens refilled.
        vm.warp(block.timestamp + 2);
        vm.prank(settlementAddr);
        (bool ok5,) =
            mandate.validateMandateForOperation(id, CAP_INFERENCE_CALL, provider, 10, bytes32(0));
        assertTrue(ok5);
        vm.prank(settlementAddr);
        (bool ok6,) =
            mandate.validateMandateForOperation(id, CAP_INFERENCE_CALL, provider, 10, bytes32(0));
        assertTrue(ok6);
        vm.prank(settlementAddr);
        (bool ok7,) =
            mandate.validateMandateForOperation(id, CAP_INFERENCE_CALL, provider, 10, bytes32(0));
        assertFalse(ok7, "third post-refill call should rate-limit");
    }

    function test_RateLimit_SaturatesAtCapacity() public {
        Caveats.Caveat[] memory cs = new Caveats.Caveat[](4);
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CAP_INFERENCE_CALL;
        cs[0] = _capsArr(caps);
        cs[1] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, 1_000_000);
        cs[2] = _provs([provider]);
        cs[3] = Caveats.encodeRateLimit(10, 1, 0, uint64(block.timestamp));
        vm.prank(issuer);
        bytes32 id = mandate.issueMandate(masterHolder, cs, 700);

        // Warp 1000 seconds (way past capacity) → bucket should refill to 10, not overflow.
        vm.warp(block.timestamp + 1_000);
        for (uint256 i = 0; i < 10; ++i) {
            vm.prank(settlementAddr);
            (bool ok,) =
                mandate.validateMandateForOperation(id, CAP_INFERENCE_CALL, provider, 1, bytes32(0));
            assertTrue(ok, "should succeed up to capacity");
        }
        vm.prank(settlementAddr);
        (bool okOver,) =
            mandate.validateMandateForOperation(id, CAP_INFERENCE_CALL, provider, 1, bytes32(0));
        assertFalse(okOver, "11th call in same block must rate-limit");
    }

    // ------------------------------------------------------------------
    // Sub-mandate consumes parent's rate-limit token
    // ------------------------------------------------------------------

    function test_SubMandateIssuance_ConsumesParentToken() public {
        Caveats.Caveat[] memory cs = new Caveats.Caveat[](4);
        bytes32[] memory caps = new bytes32[](2);
        caps[0] = CAP_INFERENCE_CALL;
        caps[1] = CAP_REDELEGATE;
        cs[0] = _capsArr(caps);
        cs[1] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, 1_000_000);
        cs[2] = Caveats.encodeCapRedelegate(5, 100_000);
        cs[3] = Caveats.encodeRateLimit(1, 0, 1, uint64(block.timestamp));
        vm.prank(issuer);
        bytes32 root = mandate.issueMandate(masterHolder, cs, 800);

        Caveats.Caveat[] memory sub = _subCaveatsBudget(10_000);
        vm.prank(masterHolder);
        mandate.issueSubMandate(root, subHolder, sub, 1); // consumes parent's only token

        // Second sub-mandate should fail at rate-limit pre-check.
        Caveats.Caveat[] memory sub2 = _subCaveatsBudget(10_000);
        vm.prank(masterHolder);
        vm.expectRevert(Mandate.ParentRateLimited.selector);
        mandate.issueSubMandate(root, subHolder, sub2, 2);
    }
}
