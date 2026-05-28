# Spike 3 — `venice-x402-client` × MetaMask Smart Accounts

## Goal

Determine whether `venice-x402-client` accepts a MetaMask Smart Account as signer or needs an adapter shim.

## Findings (desk research)

Inspection of `github.com/veniceai/x402-client` indicates the public initialization surface accepts **only a private key**:

```ts
const venice = new VeniceClient(privateKey)
// or via env: WALLET_PRIVATE_KEY / WALLET_KEY
```

There is no documented `signer` / `account` / viem-wallet entry point as of 2026-05-28. The README does not mention `toMetaMaskSmartAccount`.

**Implication:** the client cannot, out of the box, sign x402 payments through a MetaMask Smart Account (which has no extractable private key — its signer is the user's EOA + the smart-account contract logic).

## Approach for the spike's empirical run

Two phases:

### Phase 1 — confirm the bare path works (informational)

Install `venice-x402-client`, pass a private key (the same `BASE_SEPOLIA_PK` from `.env`), make one inference call. This baselines that the SDK + Base USDC + Venice's x402 flow all work for us at all.

### Phase 2 — try wiring a Smart Account

Two adapter sketches to evaluate:

1. **Wrap a `toMetaMaskSmartAccount` instance** in a viem-compatible signer shape, then patch into `venice-x402-client` via whatever extension point exists. If no extension point, **fork or thin wrap** the SDK's signing call site to accept a generic `signTypedData`-capable interface.
2. **Bypass the SDK's payment flow** entirely: replicate the x402 PAYMENT-REQUIRED dance manually (read the 402, build the USDC `transferWithAuthorization` (EIP-3009) signed payload, attach as `X-PAYMENT` header, retry). The Smart Account signs the EIP-712 payload via its delegate-call signer path.

Path 2 is more work upfront but matches Frost's existing intent — the `Settlement` contract under our control already routes x402 settlements, and the master agent can mint sub-mandates that authorize specific token spends. Path 1 is the shortest hack to keep the SDK in the loop.

### Estimate

Per `HANDOFF.md` spike 3: "~1-2 days of adapter work if it fails." That estimate looks right.

## Code scaffold

This spike's `run.ts` is a stub — the actual adapter design happens after Phase 1 runs and we see the SDK's signing surface in detail. The README is the deliverable; the harness will be filled in once the spike is unblocked by adding `venice-x402-client` + `@metamask/smart-accounts-kit` to a real workspace (intentionally not in `spikes/package.json` yet to keep that minimal).

## Pass criteria

Either:

- (a) Phase 1 succeeds and Phase 2 reveals a clean extension point in the SDK we missed → minor wrapper.
- (b) Phase 1 succeeds and Phase 2 confirms a fork/replicate is needed → document the path; flag the ~1-2 day cost.

A real FAIL would be Phase 1 not working at all (the SDK can't talk to Venice via Base Sepolia USDC), which would re-open the inference-provider question — escalate immediately.

## Sources

- Venice x402 client repo — <https://github.com/veniceai/x402-client>
- Venice x402 announcement — <https://venice.ai/blog/venice-now-supports-x402>
- MetaMask Smart Account viem integration — <https://viem.sh/account-abstraction/accounts/smart/toMetaMaskSmartAccount>
