// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Settlement, IERC20} from "../src/Settlement.sol";
import {Mandate} from "../src/Mandate.sol";
import {DelegationRegistry} from "../src/DelegationRegistry.sol";
import {Caveats} from "../src/Caveats.sol";
import {IMandate} from "../src/interfaces/IMandate.sol";
import {Revocation} from "../src/Revocation.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title Settlement tests against real Mandate + DelegationRegistry.
/// @notice Targets contract-architecture.md invariants:
///         I-04 (revocation grace), I-05 (nonce uniqueness),
///         I-09 (provider whitelist), I-12 (global nonce set / cross-provider replay).
///         Mandate is now real — caveat-driven rejection bubbles up through
///         IMandate.InvalidReason instead of a mock-controlled value.
contract SettlementTest is Test {
    bytes32 internal constant CAP_INFERENCE_CALL = keccak256("CAP_INFERENCE_CALL");

    MockUSDC internal usdc;
    Mandate internal mandate;
    DelegationRegistry internal registry;
    Revocation internal revocation;
    ProviderRegistry internal providerRegistry;
    Settlement internal settlement;

    uint256 internal holderPk = uint256(keccak256("frost.settlement.test.holder"));
    address internal holder;
    address internal provider = address(0xBABE);
    address internal providerB = address(0xC0DE);
    // `mandateId` is a sub of `rootId` so the ancestor-revoke path is
    // exercisable against a real Revocation contract (revoking the root
    // makes mandateId's ancestor chain past-grace).
    bytes32 internal rootId;
    bytes32 internal mandateId;

    function setUp() public {
        holder = vm.addr(holderPk);

        usdc = new MockUSDC();
        providerRegistry = new ProviderRegistry(address(this));
        registry = new DelegationRegistry(address(this));
        revocation = new Revocation(address(this), registry);
        mandate = new Mandate(address(this), registry, revocation);
        settlement =
            new Settlement(IERC20(address(usdc)), mandate, revocation, providerRegistry);

        registry.setMandateContract(address(mandate));
        revocation.setMandate(address(mandate));
        mandate.setSettlement(address(settlement));

        // Root mandate: address(this) holds it so it can issue the sub below.
        // Carries CAP_INFERENCE_CALL + CAP_REDELEGATE + parametric redelegate
        // caveat so the chain can extend. Provider whitelist and spend caps
        // match what the sub uses — intersection-of-equals is a no-op.
        rootId = mandate.issueMandate(address(this), _settlementCaveats(), 0);

        // Sub mandate held by `holder`. Inherits parent's caveats verbatim
        // (sub passes the same set; intersection is identity).
        mandateId = mandate.issueSubMandate(rootId, holder, _settlementCaveats(), 1);

        providerRegistry.approveProvider(provider, bytes32(0), bytes32(0), 1);
        providerRegistry.approveProvider(providerB, bytes32(0), bytes32(0), 1);
        usdc.mint(holder, 1_000_000_000);
    }

    function _settlementCaveats() internal view returns (Caveats.Caveat[] memory cs) {
        cs = new Caveats.Caveat[](5);
        bytes32[] memory caps = new bytes32[](2);
        caps[0] = CAP_INFERENCE_CALL;
        caps[1] = keccak256("CAP_REDELEGATE");
        cs[0] = Caveats.encodeBytes32Array(Caveats.CAPABILITY_WHITELIST, caps);
        cs[1] = Caveats.encodeUint256(Caveats.SPEND_CAP_TOTAL, 1_000_000_000); // 1000 USDC
        cs[2] = Caveats.encodeUint256(Caveats.SPEND_CAP_PER_CALL, 500_000_000);
        address[] memory provs = new address[](2);
        provs[0] = provider;
        provs[1] = providerB;
        cs[3] = Caveats.encodeAddressArray(Caveats.PROVIDER_WHITELIST, provs);
        cs[4] = Caveats.encodeCapRedelegate(10, type(uint128).max);
    }

    // ------------------------------------------------------------------
    // Signature helpers
    // ------------------------------------------------------------------

    function _signAuth(uint256 pk, address prov, uint256 amount, bytes32 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typeHash = keccak256(
            "PaymentAuthorization(bytes32 mandateId,address provider,uint256 amount,bytes32 paymentNonce)"
        );
        bytes32 structHash = keccak256(abi.encode(typeHash, mandateId, prov, amount, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------------------
    // Happy path
    // ------------------------------------------------------------------

    function test_Settle_HappyPath_TransfersAndMarksNonce() public {
        bytes32 nonce = keccak256("nonce-1");
        bytes memory sig = _signAuth(holderPk, provider, 1_000_000, nonce);

        vm.expectEmit(true, true, false, true, address(settlement));
        emit Settlement.SettlementCompleted(mandateId, provider, 1_000_000, nonce, block.number);

        settlement.settle(mandateId, provider, 1_000_000, nonce, sig);

        assertTrue(settlement.spentNonces(nonce));
        assertEq(usdc.balanceOf(holder), 999_000_000);
        assertEq(usdc.balanceOf(provider), 1_000_000);
        assertEq(mandate.getMandate(mandateId).cumulativeSpend, 1_000_000);
    }

    // ------------------------------------------------------------------
    // I-05: nonce replay
    // ------------------------------------------------------------------

    function test_I05_NonceReplay_Rejected() public {
        bytes32 nonce = keccak256("nonce-replay");
        bytes memory sig = _signAuth(holderPk, provider, 100, nonce);

        settlement.settle(mandateId, provider, 100, nonce, sig);

        vm.expectRevert(abi.encodeWithSelector(Settlement.NonceAlreadySpent.selector, nonce));
        settlement.settle(mandateId, provider, 100, nonce, sig);
    }

    // ------------------------------------------------------------------
    // I-12: cross-provider replay (§6.4 — the signed digest binds provider)
    // ------------------------------------------------------------------

    function test_I12_SignatureBoundToProvider_RejectsCrossProviderReplay() public {
        bytes32 nonce = keccak256("nonce-providerA");
        bytes memory sig = _signAuth(holderPk, provider, 100, nonce);

        vm.expectRevert(Settlement.InvalidSignature.selector);
        settlement.settle(mandateId, providerB, 100, nonce, sig);
    }

    // ------------------------------------------------------------------
    // I-09: provider whitelist (registry side — happens before Mandate)
    // ------------------------------------------------------------------

    function test_I09_RegistryRejection() public {
        address rogue = address(0xDEAD);
        bytes32 nonce = keccak256("nonce-rogue");
        bytes memory sig = _signAuth(holderPk, rogue, 100, nonce);

        vm.expectRevert(abi.encodeWithSelector(Settlement.ProviderNotApproved.selector, rogue));
        settlement.settle(mandateId, rogue, 100, nonce, sig);
    }

    // ------------------------------------------------------------------
    // I-04: revocation grace window
    // ------------------------------------------------------------------

    function test_I04_RevokedInsideGrace_StillSettles() public {
        // address(this) is mandateId's issuer (it called issueSubMandate).
        revocation.revoke(mandateId);

        bytes32 nonce = keccak256("nonce-grace");
        bytes memory sig = _signAuth(holderPk, provider, 50, nonce);
        settlement.settle(mandateId, provider, 50, nonce, sig);

        assertEq(usdc.balanceOf(provider), 50);
    }

    function test_I04_RevokedPastGrace_Rejected() public {
        uint64 revokedAt = uint64(block.number);
        revocation.revoke(mandateId);
        vm.roll(block.number + 31);

        bytes32 nonce = keccak256("nonce-past-grace");
        bytes memory sig = _signAuth(holderPk, provider, 50, nonce);

        vm.expectRevert(
            abi.encodeWithSelector(Settlement.MandateRevokedPastGrace.selector, revokedAt, block.number)
        );
        settlement.settle(mandateId, provider, 50, nonce, sig);
    }

    function test_I04_AncestorRevokedPastGrace_Rejected() public {
        // Revoke the root; the sub (mandateId) sees its ancestor revoked, and
        // Settlement should reject once grace lapses.
        uint64 revokedAt = uint64(block.number);
        revocation.revoke(rootId);
        vm.roll(block.number + 31);

        bytes32 nonce = keccak256("nonce-ancestor");
        bytes memory sig = _signAuth(holderPk, provider, 50, nonce);
        vm.expectRevert(
            abi.encodeWithSelector(Settlement.MandateRevokedPastGrace.selector, revokedAt, block.number)
        );
        settlement.settle(mandateId, provider, 50, nonce, sig);
    }

    // ------------------------------------------------------------------
    // Mandate-side rejection bubbles up — real Mandate caveat enforcement
    // ------------------------------------------------------------------

    function test_MandateRejection_BubblesPerCallCap() public {
        // Per-call cap is 500_000_000; ask for 500_000_001.
        bytes32 nonce = keccak256("nonce-percall");
        bytes memory sig = _signAuth(holderPk, provider, 500_000_001, nonce);
        usdc.mint(holder, 1_000_000_000); // ensure balance is fine; rejection is caveat-side

        vm.expectRevert(
            abi.encodeWithSelector(
                Settlement.MandateAuthorizationFailed.selector,
                IMandate.InvalidReason.SpendCapPerCallExceeded
            )
        );
        settlement.settle(mandateId, provider, 500_000_001, nonce, sig);
    }

    function test_MandateRejection_BubblesTotalSpendCap() public {
        // Spend up to just under the total cap, then attempt to push it over.
        // SPEND_CAP_TOTAL is 1_000_000_000. Two settlements of 500_000_000 each
        // sit exactly at the cap; a third 1-USDC call must reject.
        bytes32 n1 = keccak256("nonce-tot-1");
        bytes32 n2 = keccak256("nonce-tot-2");
        bytes32 n3 = keccak256("nonce-tot-3");
        settlement.settle(mandateId, provider, 500_000_000, n1, _signAuth(holderPk, provider, 500_000_000, n1));
        settlement.settle(mandateId, provider, 500_000_000, n2, _signAuth(holderPk, provider, 500_000_000, n2));

        // _signAuth calls domainSeparator() which would consume the cheat; hoist.
        bytes memory sig3 = _signAuth(holderPk, provider, 1, n3);
        vm.expectRevert(
            abi.encodeWithSelector(
                Settlement.MandateAuthorizationFailed.selector,
                IMandate.InvalidReason.SpendCapTotalExceeded
            )
        );
        settlement.settle(mandateId, provider, 1, n3, sig3);
    }

    // ------------------------------------------------------------------
    // USDC transfer failure → revert; nonce NOT marked spent
    // ------------------------------------------------------------------

    function test_TransferFailure_RevertsAndNonceNotMarked() public {
        usdc.setFailNextTransfer(true);

        bytes32 nonce = keccak256("nonce-transferfail");
        bytes memory sig = _signAuth(holderPk, provider, 100, nonce);

        vm.expectRevert(Settlement.UsdcTransferFailed.selector);
        settlement.settle(mandateId, provider, 100, nonce, sig);

        assertFalse(settlement.spentNonces(nonce));
        // Mandate's cumulativeSpend was incremented inside validateMandateForOperation
        // but the outer revert rolled it back.
        assertEq(mandate.getMandate(mandateId).cumulativeSpend, 0);
    }

    // ------------------------------------------------------------------
    // Signature rejection paths
    // ------------------------------------------------------------------

    function test_WrongSigner_Rejected() public {
        uint256 wrongPk = uint256(keccak256("not-the-holder"));
        bytes32 nonce = keccak256("nonce-wrong-signer");
        bytes memory sig = _signAuth(wrongPk, provider, 100, nonce);

        vm.expectRevert(Settlement.InvalidSignature.selector);
        settlement.settle(mandateId, provider, 100, nonce, sig);
    }

    function test_BadSigLength_Rejected() public {
        bytes32 nonce = keccak256("nonce-badlen");
        bytes memory sig = hex"deadbeef";
        vm.expectRevert(Settlement.InvalidSignature.selector);
        settlement.settle(mandateId, provider, 100, nonce, sig);
    }

    function test_ZeroAmount_Rejected() public {
        bytes32 nonce = keccak256("nonce-zero");
        bytes memory sig = _signAuth(holderPk, provider, 0, nonce);
        vm.expectRevert(Settlement.ZeroAmount.selector);
        settlement.settle(mandateId, provider, 0, nonce, sig);
    }

    function test_UnknownMandate_Rejected() public {
        bytes32 unknown = bytes32(uint256(0xDEADBEEF));
        bytes32 nonce = keccak256("nonce-unknown");
        // Build signature against `unknown`, not the real mandateId.
        bytes32 typeHash = keccak256(
            "PaymentAuthorization(bytes32 mandateId,address provider,uint256 amount,bytes32 paymentNonce)"
        );
        bytes32 structHash = keccak256(abi.encode(typeHash, unknown, provider, uint256(100), nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(holderPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(abi.encodeWithSelector(Settlement.MandateUnknown.selector, unknown));
        settlement.settle(unknown, provider, 100, nonce, sig);
    }

    // ------------------------------------------------------------------
    // Pre-flight helper
    // ------------------------------------------------------------------

    function test_GetRevocationStatus_BeforeAndAfterGrace() public {
        (bool revoked, uint64 atBlock) = settlement.getRevocationStatus(mandateId);
        assertFalse(revoked);
        assertEq(uint256(atBlock), 0);

        revocation.revoke(mandateId);
        (revoked, atBlock) = settlement.getRevocationStatus(mandateId);
        assertFalse(revoked, "inside grace");

        vm.roll(block.number + 31);
        (revoked,) = settlement.getRevocationStatus(mandateId);
        assertTrue(revoked, "past grace");
    }
}
