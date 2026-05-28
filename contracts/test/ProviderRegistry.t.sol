// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";

/// @title ProviderRegistry tests.
/// @notice Covers §7.3 admin allowlist semantics: approve / revoke / re-approve,
///         access control, manifest readback, active-list maintenance.
contract ProviderRegistryTest is Test {
    ProviderRegistry internal registry;

    address internal admin = address(this);
    address internal stranger = address(0xDEAD);

    address internal providerA = address(0xA11CE);
    address internal providerB = address(0xB0B);
    address internal providerC = address(0xC4FE);

    bytes32 internal manifestHashA = keccak256("manifest-A");
    bytes32 internal manifestUriA = keccak256("ipfs://manifest-A");
    bytes32 internal manifestHashB = keccak256("manifest-B");
    bytes32 internal manifestUriB = keccak256("ipfs://manifest-B");

    function setUp() public {
        registry = new ProviderRegistry(admin);
    }

    // ------------------------------------------------------------------
    // approveProvider
    // ------------------------------------------------------------------

    function test_ApproveProvider_HappyPath() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit ProviderRegistry.ProviderApproved(
            providerA, manifestHashA, manifestUriA, 1, uint64(block.timestamp)
        );
        registry.approveProvider(providerA, manifestHashA, manifestUriA, 1);

        assertTrue(registry.isApproved(providerA));

        (address addr, bytes32 mh, bytes32 mu, uint64 approvedAt, uint64 revokedAt, uint8 tier) =
            registry.providers(providerA);
        assertEq(addr, providerA);
        assertEq(mh, manifestHashA);
        assertEq(mu, manifestUriA);
        assertEq(approvedAt, uint64(block.timestamp));
        assertEq(revokedAt, 0);
        assertEq(tier, 1);
    }

    function test_ApproveProvider_RejectsNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(ProviderRegistry.OnlyAdmin.selector);
        registry.approveProvider(providerA, manifestHashA, manifestUriA, 1);
    }

    function test_ApproveProvider_RejectsZero() public {
        vm.expectRevert(ProviderRegistry.ProviderZero.selector);
        registry.approveProvider(address(0), manifestHashA, manifestUriA, 1);
    }

    function test_ApproveProvider_RejectsDuplicateActive() public {
        registry.approveProvider(providerA, manifestHashA, manifestUriA, 1);
        vm.expectRevert(
            abi.encodeWithSelector(ProviderRegistry.ProviderAlreadyApproved.selector, providerA)
        );
        registry.approveProvider(providerA, manifestHashB, manifestUriB, 2);
    }

    // ------------------------------------------------------------------
    // revokeProvider
    // ------------------------------------------------------------------

    function test_RevokeProvider_HappyPath() public {
        registry.approveProvider(providerA, manifestHashA, manifestUriA, 1);

        vm.expectEmit(true, false, false, true, address(registry));
        emit ProviderRegistry.ProviderRevoked(providerA, uint64(block.timestamp));
        registry.revokeProvider(providerA);

        assertFalse(registry.isApproved(providerA));

        (,,, , uint64 revokedAt,) = registry.providers(providerA);
        assertEq(revokedAt, uint64(block.timestamp));

        address[] memory active = registry.getActiveProviders();
        assertEq(active.length, 0);
    }

    function test_RevokeProvider_RejectsNonAdmin() public {
        registry.approveProvider(providerA, manifestHashA, manifestUriA, 1);
        vm.prank(stranger);
        vm.expectRevert(ProviderRegistry.OnlyAdmin.selector);
        registry.revokeProvider(providerA);
    }

    function test_RevokeProvider_RejectsZero() public {
        vm.expectRevert(ProviderRegistry.ProviderZero.selector);
        registry.revokeProvider(address(0));
    }

    function test_RevokeProvider_RejectsNeverApproved() public {
        vm.expectRevert(
            abi.encodeWithSelector(ProviderRegistry.ProviderNotApproved.selector, providerA)
        );
        registry.revokeProvider(providerA);
    }

    function test_RevokeProvider_RejectsAlreadyRevoked() public {
        registry.approveProvider(providerA, manifestHashA, manifestUriA, 1);
        registry.revokeProvider(providerA);
        vm.expectRevert(
            abi.encodeWithSelector(ProviderRegistry.ProviderNotApproved.selector, providerA)
        );
        registry.revokeProvider(providerA);
    }

    // ------------------------------------------------------------------
    // Re-approval after revoke
    // ------------------------------------------------------------------

    function test_ReapprovalAfterRevoke_Allowed() public {
        registry.approveProvider(providerA, manifestHashA, manifestUriA, 1);
        registry.revokeProvider(providerA);
        assertFalse(registry.isApproved(providerA));

        // Advance time so the new approvedAt is observably different.
        vm.warp(block.timestamp + 100);
        uint64 reApprovedAt = uint64(block.timestamp);

        registry.approveProvider(providerA, manifestHashB, manifestUriB, 2);
        assertTrue(registry.isApproved(providerA));

        (, bytes32 mh, bytes32 mu, uint64 approvedAt, uint64 revokedAt, uint8 tier) =
            registry.providers(providerA);
        assertEq(mh, manifestHashB);
        assertEq(mu, manifestUriB);
        assertEq(approvedAt, reApprovedAt);
        assertEq(revokedAt, 0, "revokedAt cleared on re-approve");
        assertEq(tier, 2);

        address[] memory active = registry.getActiveProviders();
        assertEq(active.length, 1);
        assertEq(active[0], providerA);
    }

    // ------------------------------------------------------------------
    // getManifest
    // ------------------------------------------------------------------

    function test_GetManifest_ReturnsStoredValues() public {
        registry.approveProvider(providerA, manifestHashA, manifestUriA, 1);
        (bytes32 mh, bytes32 mu) = registry.getManifest(providerA);
        assertEq(mh, manifestHashA);
        assertEq(mu, manifestUriA);
    }

    function test_GetManifest_ZeroForUnknown() public view {
        (bytes32 mh, bytes32 mu) = registry.getManifest(providerA);
        assertEq(mh, bytes32(0));
        assertEq(mu, bytes32(0));
    }

    // ------------------------------------------------------------------
    // getActiveProviders — add + remove tracking
    // ------------------------------------------------------------------

    function test_GetActiveProviders_ReflectsAddAndRemove() public {
        assertEq(registry.getActiveProviders().length, 0);

        registry.approveProvider(providerA, manifestHashA, manifestUriA, 1);
        registry.approveProvider(providerB, manifestHashB, manifestUriB, 1);
        registry.approveProvider(providerC, manifestHashA, manifestUriA, 2);

        address[] memory active = registry.getActiveProviders();
        assertEq(active.length, 3);

        // Revoke the middle entry — swap-pop semantics mean providerC takes
        // providerB's slot and the list shrinks to length 2.
        registry.revokeProvider(providerB);
        active = registry.getActiveProviders();
        assertEq(active.length, 2);
        assertTrue(registry.isApproved(providerA));
        assertFalse(registry.isApproved(providerB));
        assertTrue(registry.isApproved(providerC));

        // The remaining entries must be {providerA, providerC} in some order.
        bool sawA;
        bool sawC;
        for (uint256 i = 0; i < active.length; ++i) {
            if (active[i] == providerA) sawA = true;
            if (active[i] == providerC) sawC = true;
        }
        assertTrue(sawA);
        assertTrue(sawC);
    }

    // ------------------------------------------------------------------
    // isApproved
    // ------------------------------------------------------------------

    function test_IsApproved_FalseByDefault() public view {
        assertFalse(registry.isApproved(providerA));
        assertFalse(registry.isApproved(address(0)));
    }
}
