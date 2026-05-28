# Spike 3 — `venice-x402-client` × MetaMask Smart Accounts

**Status:** ⚠️ PASS-with-caveat (desk-research finding; empirical run deferred)
**Date:** 2026-05-28
**Run by:** Claude

## Method

Reviewed `github.com/veniceai/x402-client` public surface.

## Observation

The client's only documented constructor accepts a **private key**:

```ts
const venice = new VeniceClient(privateKey)
```

No `signer` / `account` / viem-wallet entry point is documented. A MetaMask Smart Account has no extractable private key — its signing is delegated through the smart-account contract and the user's EOA — so the client cannot be used as-is.

## Decision impact

Per `HANDOFF.md`'s pre-locked decision: this is "not architecturally blocking but ~1–2 days of work." Two adapter paths to evaluate during the build (see README.md):

1. **Wrap the SDK** with a generic `signTypedData`-capable signer (fork or PR).
2. **Replicate the x402 PAYMENT-REQUIRED flow manually** — build the EIP-3009 `transferWithAuthorization` payload, have the Smart Account sign it, attach as `X-PAYMENT` header.

Recommended order: do path 1 first (smaller change), fall back to path 2 if the SDK has no clean injection point.

## What's still owed

- Phase 1 baseline: `new VeniceClient(privateKey)` end-to-end with our test wallet — confirms Venice's x402 + Base USDC works for us at all.
- Phase 2: actually wire a Smart Account through one of the two paths.

Both phases are blocked on (a) installing the SDK in a real workspace (kept out of `spikes/package.json` to avoid pulling in heavy deps for a spike harness) and (b) deploying a MetaMask Smart Account from spike 8's session-account flow.

## Sources

- Venice x402 client — <https://github.com/veniceai/x402-client>
- Venice x402 launch post — <https://venice.ai/blog/venice-now-supports-x402>
- viem `toMetaMaskSmartAccount` — <https://viem.sh/account-abstraction/accounts/smart/toMetaMaskSmartAccount>
