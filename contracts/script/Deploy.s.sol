// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {DelegationRegistry} from "../src/DelegationRegistry.sol";
import {Revocation} from "../src/Revocation.sol";
import {Mandate} from "../src/Mandate.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {Settlement, IERC20} from "../src/Settlement.sol";
import {RefillableMandate} from "../src/RefillableMandate.sol";

/// @title Deploy — full Port-42 contract stack to a single network.
/// @notice Wiring order mirrors contracts/CLAUDE.md §"Wiring at deploy time".
contract Deploy is Script {
    // Base Sepolia USDC (locked, Day-1 spike 6).
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    // §7.4 MVP provider seeding. Manifest URIs are keccak256 of the canonical
    // endpoint URL strings — when real provider payment addresses are known on
    // Base Sepolia the admin can re-approve with the same URIs and the real
    // addresses, or revoke + re-approve. Tier 1 = basic across the board.
    bytes32 internal constant VENICE_X402_MANIFEST_URI =
        keccak256("https://api.venice.ai/api/v1/x402");
    bytes32 internal constant VENICE_RPC_MANIFEST_URI =
        keccak256("https://api.venice.ai/api/v1/crypto/rpc");
    bytes32 internal constant FROST_AUDIT_MANIFEST_URI =
        keccak256("https://audit.frost.dev/v1/commit");

    // Placeholder provider addresses derived from role names. Documented in
    // DEPLOYED_CONTRACTS.md; replace via approveProvider once real addresses
    // land. Using deterministic placeholders so the audit trail is clear.
    address internal constant VENICE_X402_PLACEHOLDER =
        address(uint160(uint256(keccak256("venice.x402.base-sepolia.placeholder"))));
    address internal constant VENICE_RPC_PLACEHOLDER =
        address(uint160(uint256(keccak256("venice.rpc.base-sepolia.placeholder"))));
    address internal constant FROST_AUDIT_PLACEHOLDER =
        address(uint160(uint256(keccak256("frost.audit.base-sepolia.placeholder"))));

    function run()
        external
        returns (
            DelegationRegistry registry,
            Revocation revocation,
            Mandate mandate,
            ProviderRegistry providerRegistry,
            Settlement settlement,
            RefillableMandate refillable
        )
    {
        // Broadcast signer (admin) is the --private-key passed to forge script.
        // tx.origin inside startBroadcast resolves to that account.
        vm.startBroadcast();
        address admin = tx.origin;

        console2.log("=== Frost / Port-42 deployment ===");
        console2.log("Chain id:", block.chainid);
        console2.log("Admin / deployer:", admin);
        console2.log("USDC:", BASE_SEPOLIA_USDC);

        // 1. DelegationRegistry
        registry = new DelegationRegistry(admin);
        console2.log("DelegationRegistry:", address(registry));

        // 2. Revocation (mandate binding deferred)
        revocation = new Revocation(admin, registry);
        console2.log("Revocation:", address(revocation));

        // 3. Mandate
        mandate = new Mandate(admin, registry, revocation);
        console2.log("Mandate:", address(mandate));

        // 4. registry.setMandateContract — lock-once
        registry.setMandateContract(address(mandate));

        // 5. revocation.setMandate — lock-once
        revocation.setMandate(address(mandate));

        // 6. ProviderRegistry + §7.4 MVP seeding
        providerRegistry = new ProviderRegistry(admin);
        console2.log("ProviderRegistry:", address(providerRegistry));

        providerRegistry.approveProvider(
            VENICE_X402_PLACEHOLDER, bytes32(0), VENICE_X402_MANIFEST_URI, 1
        );
        providerRegistry.approveProvider(
            VENICE_RPC_PLACEHOLDER, bytes32(0), VENICE_RPC_MANIFEST_URI, 1
        );
        providerRegistry.approveProvider(
            FROST_AUDIT_PLACEHOLDER, bytes32(0), FROST_AUDIT_MANIFEST_URI, 1
        );

        // 7. Settlement
        settlement = new Settlement(
            IERC20(BASE_SEPOLIA_USDC), mandate, revocation, providerRegistry
        );
        console2.log("Settlement:", address(settlement));

        // 8. mandate.setSettlement — lock-once
        mandate.setSettlement(address(settlement));

        // 9. RefillableMandate (no setter — issues mandates as its own issuer)
        refillable = new RefillableMandate(mandate, revocation);
        console2.log("RefillableMandate:", address(refillable));

        vm.stopBroadcast();

        console2.log("=== Seeded providers (placeholders) ===");
        console2.log("Venice x402:", VENICE_X402_PLACEHOLDER);
        console2.log("Venice RPC:", VENICE_RPC_PLACEHOLDER);
        console2.log("Frost audit:", FROST_AUDIT_PLACEHOLDER);
    }
}
