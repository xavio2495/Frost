// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Revocation} from "../src/Revocation.sol";
import {Mandate} from "../src/Mandate.sol";
import {DelegationRegistry} from "../src/DelegationRegistry.sol";
import {Caveats} from "../src/Caveats.sol";
import {IMandate} from "../src/interfaces/IMandate.sol";

/// @title Revocation tests.
/// @notice Covers §8.3 access control (I-10), ancestor-walk semantics for
///         isAncestorRevoked / nearestRevokedAtBlock, and the one-time
///         setMandate wiring.
contract RevocationTest is Test {
    bytes32 internal constant CAP_INFERENCE_CALL = keccak256("CAP_INFERENCE_CALL");
    bytes32 internal constant CAP_REDELEGATE = keccak256("CAP_REDELEGATE");

    DelegationRegistry internal registry;
    Revocation internal revocation;
    Mandate internal mandate;

    address internal admin = address(this);
    address internal settlementAddr = address(0xBABE);

    address internal rootIssuer = address(0xA11CE);
    address internal rootHolder = address(0xB0B);
    address internal subHolder = address(0xC4FE);
    address internal grandHolder = address(0xD00D);
    address internal stranger = address(0xDEAD);

    bytes32 internal rootId;
    bytes32 internal subId;
    bytes32 internal grandId;

    function setUp() public {
        registry = new DelegationRegistry(admin);
        revocation = new Revocation(admin, registry);
        mandate = new Mandate(admin, registry, revocation);

        registry.setMandateContract(address(mandate));
        revocation.setMandate(address(mandate));
        mandate.setSettlement(settlementAddr);

        // Root mandate: rootIssuer → rootHolder. Carries CAP_REDELEGATE +
        // parametric caveat so the chain can extend.
        vm.prank(rootIssuer);
        rootId = mandate.issueMandate(rootHolder, _redelegableCaveats(1_000_000), 1);

        // Sub: rootHolder → subHolder. Same caveats (carry through).
        vm.prank(rootHolder);
        subId = mandate.issueSubMandate(rootId, subHolder, _redelegableCaveats(500_000), 2);

        // Grandchild: subHolder → grandHolder.
        vm.prank(subHolder);
        grandId = mandate.issueSubMandate(subId, grandHolder, _redelegableCaveats(100_000), 3);
    }

    function _redelegableCaveats(uint256 spendCap)
        internal
        pure
        returns (Caveats.Caveat[] memory cs)
    {
        cs = new Caveats.Caveat[](3);
        bytes32[] memory caps = new bytes32[](2);
        caps[0] = CAP_INFERENCE_CALL;
        caps[1] = CAP_REDELEGATE;
        cs[0] = Caveats.encodeBytes32Array(Caveats.CAPABILITY_WHITELIST, caps);
        cs[1] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, spendCap);
        // CAP_REDELEGATE: maxSubMandates=10, aggregate budget capacious.
        cs[2] = Caveats.encodeCapRedelegate(10, type(uint128).max);
    }

    // ------------------------------------------------------------------
    // setMandate wiring
    // ------------------------------------------------------------------

    function test_SetMandate_RejectsNonAdmin() public {
        Revocation r = new Revocation(admin, registry);
        vm.prank(stranger);
        vm.expectRevert(Revocation.OnlyAdmin.selector);
        r.setMandate(address(mandate));
    }

    function test_SetMandate_RejectsZero() public {
        Revocation r = new Revocation(admin, registry);
        vm.expectRevert(Revocation.MandateZero.selector);
        r.setMandate(address(0));
    }

    function test_SetMandate_RejectsSecondCall() public {
        vm.expectRevert(Revocation.MandateAlreadySet.selector);
        revocation.setMandate(address(mandate));
    }

    // ------------------------------------------------------------------
    // revoke — access control matrix (§8.3, I-10)
    // ------------------------------------------------------------------

    function test_Revoke_ByIssuer() public {
        // subId was issued by rootHolder; rootHolder is both sub's issuer
        // AND sub's parent holder. Test pure issuer-auth on root instead.
        vm.prank(rootIssuer);
        revocation.revoke(rootId);
        assertTrue(revocation.isRevoked(rootId));
        assertEq(revocation.revokedAtBlock(rootId), uint64(block.number));
        assertEq(revocation.revokedBy(rootId), rootIssuer);
    }

    function test_Revoke_ByParentHolder() public {
        // grandId's parent is subId; subId.holder is subHolder.
        vm.prank(subHolder);
        revocation.revoke(grandId);
        assertTrue(revocation.isRevoked(grandId));
    }

    function test_Revoke_ByRootIssuer() public {
        // grandId's root is rootId; rootId.issuer is rootIssuer.
        // rootIssuer is not the grand's issuer or parent's holder.
        vm.prank(rootIssuer);
        revocation.revoke(grandId);
        assertTrue(revocation.isRevoked(grandId));
    }

    function test_Revoke_RejectsUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Revocation.NotAuthorized.selector, stranger));
        revocation.revoke(grandId);
    }

    function test_Revoke_RootMandate_OnlyIssuerAuthorizes() public {
        // For a root mandate, parent's holder doesn't exist. Strangers and
        // even rootHolder (who is the holder, not the issuer) must be rejected.
        vm.prank(rootHolder);
        vm.expectRevert(abi.encodeWithSelector(Revocation.NotAuthorized.selector, rootHolder));
        revocation.revoke(rootId);
    }

    function test_Revoke_RejectsAlreadyRevoked() public {
        vm.prank(rootIssuer);
        revocation.revoke(rootId);
        vm.prank(rootIssuer);
        vm.expectRevert(abi.encodeWithSelector(Revocation.AlreadyRevoked.selector, rootId));
        revocation.revoke(rootId);
    }

    function test_Revoke_RejectsUnknownMandate() public {
        bytes32 unknown = bytes32(uint256(0xC0FFEE));
        vm.prank(rootIssuer);
        vm.expectRevert(abi.encodeWithSelector(Revocation.UnknownMandate.selector, unknown));
        revocation.revoke(unknown);
    }

    function test_Revoke_EmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(revocation));
        emit Revocation.MandateRevoked(rootId, rootIssuer, uint64(block.number));
        vm.prank(rootIssuer);
        revocation.revoke(rootId);
    }

    // ------------------------------------------------------------------
    // isRevoked / revokedAtBlock
    // ------------------------------------------------------------------

    function test_IsRevoked_FalseByDefault() public view {
        assertFalse(revocation.isRevoked(rootId));
        assertFalse(revocation.isRevoked(subId));
        assertFalse(revocation.isRevoked(grandId));
        assertEq(revocation.revokedAtBlock(rootId), 0);
    }

    // ------------------------------------------------------------------
    // isAncestorRevoked — ancestor walk
    // ------------------------------------------------------------------

    function test_IsAncestorRevoked_SelfRevoked() public {
        vm.prank(subHolder);
        revocation.revoke(grandId);
        assertTrue(revocation.isAncestorRevoked(grandId));
    }

    function test_IsAncestorRevoked_ParentRevoked() public {
        vm.prank(rootHolder); // rootHolder is subId's issuer (it called issueSubMandate)
        revocation.revoke(subId);
        assertTrue(revocation.isAncestorRevoked(grandId));
        assertTrue(revocation.isAncestorRevoked(subId));
        assertFalse(revocation.isAncestorRevoked(rootId));
    }

    function test_IsAncestorRevoked_RootRevoked() public {
        vm.prank(rootIssuer);
        revocation.revoke(rootId);
        assertTrue(revocation.isAncestorRevoked(grandId));
        assertTrue(revocation.isAncestorRevoked(subId));
        assertTrue(revocation.isAncestorRevoked(rootId));
    }

    function test_IsAncestorRevoked_FalseWhenNoRevocation() public view {
        assertFalse(revocation.isAncestorRevoked(grandId));
    }

    function test_IsAncestorRevoked_UnknownMandate_False() public view {
        // Unregistered mandates have no parent — parentOf returns bytes32(0),
        // the loop terminates immediately, and we return false.
        assertFalse(revocation.isAncestorRevoked(bytes32(uint256(0xC0FFEE))));
    }

    // ------------------------------------------------------------------
    // nearestRevokedAtBlock — earliest-revocation semantics
    // ------------------------------------------------------------------

    function test_NearestRevokedAtBlock_ZeroWhenNoneRevoked() public view {
        assertEq(revocation.nearestRevokedAtBlock(grandId), 0);
    }

    function test_NearestRevokedAtBlock_SelfRevoked() public {
        vm.prank(subHolder);
        revocation.revoke(grandId);
        assertEq(revocation.nearestRevokedAtBlock(grandId), uint64(block.number));
    }

    function test_NearestRevokedAtBlock_AncestorOnly() public {
        uint64 rootBlock = uint64(block.number);
        vm.prank(rootIssuer);
        revocation.revoke(rootId);
        // Walking from grand → sub → root finds the root's revocation block.
        assertEq(revocation.nearestRevokedAtBlock(grandId), rootBlock);
    }

    function test_NearestRevokedAtBlock_ReturnsMinAcrossChain() public {
        // Revoke root at block A, then advance and revoke sub at block B > A.
        // nearestRevokedAtBlock(grand) must return A (the worst-case grace
        // anchor — once A is past grace, the whole chain is past grace).
        uint64 rootBlock = uint64(block.number);
        vm.prank(rootIssuer);
        revocation.revoke(rootId);

        vm.roll(block.number + 10);
        vm.prank(rootHolder);
        revocation.revoke(subId);

        assertEq(revocation.nearestRevokedAtBlock(grandId), rootBlock);
    }

    function test_NearestRevokedAtBlock_LaterLeafRevocation_StillReturnsRoot() public {
        // Symmetric to the above: revoke sub first, then root later — still
        // returns the smaller block (here, sub's earlier block).
        uint64 subBlock = uint64(block.number);
        vm.prank(rootHolder);
        revocation.revoke(subId);

        vm.roll(block.number + 10);
        vm.prank(rootIssuer);
        revocation.revoke(rootId);

        assertEq(revocation.nearestRevokedAtBlock(grandId), subBlock);
    }

    // ------------------------------------------------------------------
    // Mandate.getMandate.revoked reflects ancestor revocation
    // ------------------------------------------------------------------

    function test_MandateView_RevokedFlag_ReflectsAncestorRevocation() public {
        IMandate.MandateView memory view0 = mandate.getMandate(grandId);
        assertFalse(view0.revoked);

        vm.prank(rootIssuer);
        revocation.revoke(rootId);

        IMandate.MandateView memory view1 = mandate.getMandate(grandId);
        assertTrue(view1.revoked);
    }
}
