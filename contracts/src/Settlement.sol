// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMandate} from "./interfaces/IMandate.sol";
import {IRevocation} from "./interfaces/IRevocation.sol";
import {IProviderRegistry} from "./interfaces/IProviderRegistry.sol";

/// @dev Minimal IERC20 surface — Settlement only needs transferFrom.
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title Settlement — x402 USDC settlement endpoint for Frost / Port-42.
/// @notice Highest-stakes contract in the system (contract-architecture.md §6).
///         Verifies a payment is authorized under a valid, non-revoked mandate;
///         enforces replay protection; transfers USDC.
contract Settlement {
    // ---------------------------------------------------------------------
    // Constants (§4 Day-Zero Decisions + §6)
    // ---------------------------------------------------------------------

    /// @notice Per §4 / hackathon-plan.md Day-Zero #3. Sub-mandates and the
    ///         executor's pre-submission check tolerate revocations within this
    ///         window so providers absorb late-call loss (T-02).
    uint64 public constant REVOCATION_LATENCY_BLOCKS = 30;

    /// @notice EIP-712 PaymentAuthorization type hash. The signed object commits
    ///         to (mandateId, provider, amount, paymentNonce); binding provider
    ///         here is the §6.4 / I-12 defense against cross-provider replay even
    ///         if the off-chain nonce generator drifts.
    bytes32 internal constant _PAYMENT_AUTH_TYPEHASH = keccak256(
        "PaymentAuthorization(bytes32 mandateId,address provider,uint256 amount,bytes32 paymentNonce)"
    );

    bytes32 internal constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant _NAME_HASH = keccak256(bytes("Frost Settlement"));
    bytes32 internal constant _VERSION_HASH = keccak256(bytes("1"));

    // ---------------------------------------------------------------------
    // Immutables
    // ---------------------------------------------------------------------
    IERC20 public immutable usdc;
    IMandate public immutable mandate;
    IRevocation public immutable revocation;
    IProviderRegistry public immutable providerRegistry;

    uint256 internal immutable _cachedChainId;
    bytes32 internal immutable _cachedDomainSeparator;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice Global spent-nonce set (I-12). One mapping for all mandates and
    ///         all providers — cross-provider replay defeated by provider being
    ///         baked into the off-chain nonce (§6.4).
    mapping(bytes32 paymentNonce => bool) public spentNonces;

    uint256 private _reentrancyStatus = 1;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error Reentrancy();
    error InvalidSignature();
    error ZeroAmount();
    error NonceAlreadySpent(bytes32 paymentNonce);
    error MandateAuthorizationFailed(IMandate.InvalidReason reason);
    error ProviderNotApproved(address provider);
    error MandateRevokedPastGrace(uint64 revokedAtBlock, uint256 currentBlock);
    error UsdcTransferFailed();
    error MandateUnknown(bytes32 mandateId);

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event SettlementCompleted(
        bytes32 indexed mandateId,
        address indexed provider,
        uint256 amount,
        bytes32 paymentNonce,
        uint256 blockNumber
    );

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    constructor(IERC20 _usdc, IMandate _mandate, IRevocation _revocation, IProviderRegistry _registry) {
        usdc = _usdc;
        mandate = _mandate;
        revocation = _revocation;
        providerRegistry = _registry;
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator(block.chainid);
    }

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------
    modifier nonReentrant() {
        if (_reentrancyStatus != 1) revert Reentrancy();
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    // ---------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------

    /// @notice Authorizes and executes a single x402 settlement.
    /// @dev Reentrancy: guarded. USDC is the only external token contract; if a
    ///      future deployment whitelists a malicious "USDC", the guard prevents
    ///      reentrant settle() calls but does not protect callers of USDC.
    ///      Per §6.3, the ordering is: verify → validateMandate (state mutation)
    ///      → transferFrom → mark nonce. transferFrom comes BEFORE nonce mark
    ///      because a failed transfer must revert the whole call (no half-spent
    ///      nonce).
    /// @param mandateId      The mandate whose authority pays for this call.
    /// @param provider       The address receiving USDC (the x402 endpoint operator).
    /// @param amount         USDC amount (6 decimals).
    /// @param paymentNonce   Off-chain-generated nonce per §6.4. Reused only by bug.
    /// @param signature      EIP-712 signature over PaymentAuthorization, from the
    ///                       mandate's holder.
    function settle(
        bytes32 mandateId,
        address provider,
        uint256 amount,
        bytes32 paymentNonce,
        bytes calldata signature
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (spentNonces[paymentNonce]) revert NonceAlreadySpent(paymentNonce);

        // 1. Signature verification — must come before any state mutation. Each
        //    PaymentAuthorization commits to (mandateId, provider, amount, nonce)
        //    so a signature scoped to provider A cannot be replayed against B.
        IMandate.MandateView memory m = mandate.getMandate(mandateId);
        if (m.holder == address(0)) revert MandateUnknown(mandateId);

        bytes32 digest = _hashPaymentAuthorization(mandateId, provider, amount, paymentNonce);
        address signer = _recover(digest, signature);
        if (signer == address(0) || signer != m.holder) revert InvalidSignature();

        // 2. Revocation grace window (I-04). Reject the settlement once the
        //    REVOCATION_LATENCY_BLOCKS window has elapsed for the nearest revoked
        //    ancestor (or this mandate itself).
        uint64 revokedAt = revocation.nearestRevokedAtBlock(mandateId);
        if (revokedAt != 0 && block.number > uint256(revokedAt) + REVOCATION_LATENCY_BLOCKS) {
            revert MandateRevokedPastGrace(revokedAt, block.number);
        }

        // 3. Provider allowlist (§7 / I-09).
        if (!providerRegistry.isApproved(provider)) revert ProviderNotApproved(provider);

        // 4. Caveat enforcement — Mandate runs the full check and mutates state
        //    (rate-limit token consumption, cumulativeSpend bump). The mandate
        //    PROVIDER_WHITELIST is checked here too (not in this contract) so the
        //    two-layer "registry says provider exists" + "mandate says holder
        //    permits this provider" stays cleanly separated.
        (bool valid, IMandate.InvalidReason reason) =
            mandate.validateMandateForOperation(mandateId, _capabilityFor(provider), provider, amount, bytes32(0));
        if (!valid) revert MandateAuthorizationFailed(reason);

        // 5. Move funds.
        bool ok = usdc.transferFrom(m.holder, provider, amount);
        if (!ok) revert UsdcTransferFailed();

        // 6. Mark nonce — last, so a revert in 5 does not lock the nonce.
        spentNonces[paymentNonce] = true;

        emit SettlementCompleted(mandateId, provider, amount, paymentNonce, block.number);
    }

    /// @notice Recomputes the ancestor-aware revocation state used by §6.3.
    ///         Public helper so providers can pre-flight high-value calls (§6.3).
    /// @return revoked       True iff this mandate or an ancestor is revoked AND
    ///                       the grace window has elapsed (i.e. settle() would
    ///                       reject right now).
    /// @return revokedAtBlock_  The nearest revocation block; 0 if none.
    function getRevocationStatus(bytes32 mandateId)
        external
        view
        returns (bool revoked, uint64 revokedAtBlock_)
    {
        revokedAtBlock_ = revocation.nearestRevokedAtBlock(mandateId);
        revoked = (revokedAtBlock_ != 0 && block.number > uint256(revokedAtBlock_) + REVOCATION_LATENCY_BLOCKS);
    }

    // ---------------------------------------------------------------------
    // EIP-712
    // ---------------------------------------------------------------------

    /// @notice Returns the cached domain separator, or rebuilds it on a chain fork.
    function domainSeparator() public view returns (bytes32) {
        if (block.chainid == _cachedChainId) return _cachedDomainSeparator;
        return _buildDomainSeparator(block.chainid);
    }

    function _buildDomainSeparator(uint256 chainId) internal view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, chainId, address(this))
        );
    }

    function _hashPaymentAuthorization(
        bytes32 mandateId,
        address provider,
        uint256 amount,
        bytes32 paymentNonce
    ) internal view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(_PAYMENT_AUTH_TYPEHASH, mandateId, provider, amount, paymentNonce));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @dev Provider→capability mapping. MVP: all Settlement-routed payments are
    ///      treated as CAP_INFERENCE_CALL (§2.3). When the registry surfaces a
    ///      provider's declared capability, route through that instead. Keeps the
    ///      single check function signature in IMandate clean.
    function _capabilityFor(address /* provider */) internal pure returns (bytes32) {
        return keccak256("CAP_INFERENCE_CALL");
    }

    /// @dev ECDSA recover with low-s malleability check and v normalization.
    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 0x20))
            v := byte(0, calldataload(add(sig.offset, 0x40)))
        }
        // EIP-2 low-s
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return address(0);
        }
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, r, s);
    }
}
