// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DelegationRegistry} from "../src/DelegationRegistry.sol";
import {Caveats} from "../src/Caveats.sol";

/// @title DelegationRegistry tests.
/// @notice Pins I-06 (depth bound), I-07 (fan-out bound), I-13 (aggregate
///         budget enforcement), and access control (only Mandate writes).
contract DelegationRegistryTest is Test {
    DelegationRegistry internal reg;
    address internal admin = address(0xAD000);
    address internal mandate = address(0xDEAD0000);
    address internal holder = address(0xCAFE);

    function setUp() public {
        vm.prank(admin);
        reg = new DelegationRegistry(admin);
        vm.prank(admin);
        reg.setMandateContract(mandate);
    }

    // ------------------------------------------------------------------
    // setMandateContract
    // ------------------------------------------------------------------

    function test_SetMandateContract_OneShot() public {
        DelegationRegistry r = new DelegationRegistry(address(this));
        r.setMandateContract(mandate);
        assertEq(r.mandateContract(), mandate);

        vm.expectRevert(DelegationRegistry.MandateContractAlreadySet.selector);
        r.setMandateContract(address(0xBEEF));
    }

    function test_SetMandateContract_OnlyAdmin() public {
        DelegationRegistry r = new DelegationRegistry(admin);
        vm.expectRevert(DelegationRegistry.OnlyMandate.selector);
        r.setMandateContract(mandate);
    }

    function test_SetMandateContract_RejectsZero() public {
        DelegationRegistry r = new DelegationRegistry(address(this));
        vm.expectRevert(DelegationRegistry.MandateContractZero.selector);
        r.setMandateContract(address(0));
    }

    // ------------------------------------------------------------------
    // registerMandate access control
    // ------------------------------------------------------------------

    function test_RegisterMandate_OnlyMandateContract() public {
        bytes32 id = keccak256("attacker-root");
        vm.expectRevert(DelegationRegistry.OnlyMandate.selector);
        reg.registerMandate(id, bytes32(0), holder, 0, 0, 0);
    }

    // ------------------------------------------------------------------
    // Root registration
    // ------------------------------------------------------------------

    function test_RegisterRoot_SetsParentRootDepth() public {
        bytes32 id = keccak256("root-1");
        vm.prank(mandate);
        reg.registerMandate(id, bytes32(0), holder, 0, 0, 0);

        assertEq(reg.parentOf(id), bytes32(0));
        assertEq(reg.rootOf(id), id);
        assertEq(uint256(reg.depthOf(id)), 0);
        assertTrue(reg.isRegistered(id));
        bytes32[] memory hs = reg.mandatesByHolder(holder);
        assertEq(hs.length, 1);
        assertEq(hs[0], id);
    }

    function test_RegisterRoot_DuplicateReverts() public {
        bytes32 id = keccak256("dup");
        vm.prank(mandate);
        reg.registerMandate(id, bytes32(0), holder, 0, 0, 0);

        vm.prank(mandate);
        vm.expectRevert(abi.encodeWithSelector(DelegationRegistry.MandateAlreadyRegistered.selector, id));
        reg.registerMandate(id, bytes32(0), holder, 0, 0, 0);
    }

    // ------------------------------------------------------------------
    // Sub registration
    // ------------------------------------------------------------------

    function _registerRoot(bytes32 id) internal {
        vm.prank(mandate);
        reg.registerMandate(id, bytes32(0), holder, 0, 0, 0);
    }

    function _registerSub(
        bytes32 id,
        bytes32 parent,
        uint256 subBudget,
        uint8 parentMaxSub,
        uint256 parentMaxBudget
    ) internal {
        vm.prank(mandate);
        reg.registerMandate(id, parent, holder, subBudget, parentMaxSub, parentMaxBudget);
    }

    function test_RegisterSub_InheritsRootAndBumpsDepth() public {
        bytes32 root = keccak256("r-1");
        bytes32 sub = keccak256("s-1");
        _registerRoot(root);
        _registerSub(sub, root, 100, 5, 1_000);

        assertEq(reg.parentOf(sub), root);
        assertEq(reg.rootOf(sub), root);
        assertEq(uint256(reg.depthOf(sub)), 1);

        (uint8 count, uint256 budget) = reg.getAggregateRedelegationState(root);
        assertEq(uint256(count), 1);
        assertEq(budget, 100);
    }

    function test_RegisterSub_UnknownParentReverts() public {
        bytes32 sub = keccak256("orphan");
        bytes32 fakeParent = keccak256("ghost");
        vm.prank(mandate);
        vm.expectRevert(abi.encodeWithSelector(DelegationRegistry.UnknownMandate.selector, fakeParent));
        reg.registerMandate(sub, fakeParent, holder, 0, 1, 1);
    }

    // ------------------------------------------------------------------
    // I-06: MAX_DELEGATION_DEPTH (=5)
    // ------------------------------------------------------------------

    function test_I06_DepthBound_Allows5() public {
        bytes32 prev = keccak256("d-root");
        _registerRoot(prev);
        for (uint8 i = 1; i <= Caveats.MAX_DELEGATION_DEPTH; ++i) {
            bytes32 next = keccak256(abi.encode("depth", i));
            _registerSub(next, prev, 0, 10, 10_000);
            assertEq(uint256(reg.depthOf(next)), uint256(i));
            prev = next;
        }
    }

    function test_I06_DepthBound_Rejects6() public {
        bytes32 prev = keccak256("d6-root");
        _registerRoot(prev);
        for (uint8 i = 1; i <= Caveats.MAX_DELEGATION_DEPTH; ++i) {
            bytes32 next = keccak256(abi.encode("depth6", i));
            _registerSub(next, prev, 0, 10, 10_000);
            prev = next;
        }
        bytes32 tooDeep = keccak256("too-deep");
        vm.prank(mandate);
        vm.expectRevert(
            abi.encodeWithSelector(DelegationRegistry.MaxDepthExceeded.selector, Caveats.MAX_DELEGATION_DEPTH + 1)
        );
        reg.registerMandate(tooDeep, prev, holder, 0, 10, 10_000);
    }

    // ------------------------------------------------------------------
    // I-07: MAX_FAN_OUT_PER_NODE (=10)
    // ------------------------------------------------------------------

    function test_I07_FanOutBound_Allows10() public {
        bytes32 root = keccak256("fan-root");
        _registerRoot(root);
        for (uint8 i = 0; i < Caveats.MAX_FAN_OUT_PER_NODE; ++i) {
            _registerSub(keccak256(abi.encode("fan", i)), root, 0, 100, 10_000);
        }
        assertEq(reg.childrenOf(root).length, Caveats.MAX_FAN_OUT_PER_NODE);
    }

    function test_I07_FanOutBound_Rejects11() public {
        bytes32 root = keccak256("fan11-root");
        _registerRoot(root);
        for (uint8 i = 0; i < Caveats.MAX_FAN_OUT_PER_NODE; ++i) {
            _registerSub(keccak256(abi.encode("fan11", i)), root, 0, 100, 10_000);
        }
        vm.prank(mandate);
        vm.expectRevert(abi.encodeWithSelector(DelegationRegistry.MaxFanOutExceeded.selector, root));
        reg.registerMandate(keccak256("overflow"), root, holder, 0, 100, 10_000);
    }

    // ------------------------------------------------------------------
    // I-13: Aggregate redelegation bounds
    // ------------------------------------------------------------------

    function test_I13_MaxSubMandatesEnforced() public {
        bytes32 root = keccak256("mx-root");
        _registerRoot(root);
        _registerSub(keccak256("mx-1"), root, 100, /*parentMaxSub=*/ 2, 10_000);
        _registerSub(keccak256("mx-2"), root, 100, 2, 10_000);
        vm.prank(mandate);
        vm.expectRevert(abi.encodeWithSelector(DelegationRegistry.MaxSubMandatesExceeded.selector, root));
        reg.registerMandate(keccak256("mx-3"), root, holder, 100, 2, 10_000);
    }

    function test_I13_AggregateBudgetEnforced() public {
        bytes32 root = keccak256("ab-root");
        _registerRoot(root);
        _registerSub(keccak256("ab-1"), root, 600, 10, /*parentMaxBudget=*/ 1_000);
        vm.prank(mandate);
        vm.expectRevert(abi.encodeWithSelector(DelegationRegistry.MaxAggregateBudgetExceeded.selector, root));
        reg.registerMandate(keccak256("ab-2"), root, holder, 500, 10, 1_000);
    }

    // ------------------------------------------------------------------
    // isAncestorOf walk
    // ------------------------------------------------------------------

    function test_IsAncestorOf_WalksChain() public {
        bytes32 root = keccak256("anc-root");
        bytes32 mid = keccak256("anc-mid");
        bytes32 leaf = keccak256("anc-leaf");
        _registerRoot(root);
        _registerSub(mid, root, 0, 10, 10_000);
        _registerSub(leaf, mid, 0, 10, 10_000);

        assertTrue(reg.isAncestorOf(root, leaf));
        assertTrue(reg.isAncestorOf(mid, leaf));
        assertTrue(reg.isAncestorOf(root, mid));
        assertFalse(reg.isAncestorOf(leaf, root));
        assertFalse(reg.isAncestorOf(leaf, mid));
    }

    function test_GetAncestorChain_OrdersRootFirst() public {
        bytes32 root = keccak256("g-root");
        bytes32 mid = keccak256("g-mid");
        bytes32 leaf = keccak256("g-leaf");
        _registerRoot(root);
        _registerSub(mid, root, 0, 10, 10_000);
        _registerSub(leaf, mid, 0, 10, 10_000);

        bytes32[] memory chain = reg.getAncestorChain(leaf);
        assertEq(chain.length, 2);
        assertEq(chain[0], root);
        assertEq(chain[1], mid);
    }
}
