# Day-1 Verification Spikes

Empirical checks that must pass before Frost's architecture is locked. See `HANDOFF.md` §"Day 1: Mandatory verification spikes".

Each subfolder is a self-contained harness. Run order: Wave A (6, 5, 9) → Wave B (1, 2, 4, 7) → Wave C (3, 8, 10).

## Status board — 2026-05-28

| # | Spike | Status | Result |
|---|---|---|---|
| 1 | Venice `eth_sendRawTransaction` mempool semantics | ✅ PASS — Venice-routed tx invisible to public mempool (vs. control) | [01-venice-mempool/RESULT.md](./01-venice-mempool/RESULT.md) |
| 2 | Venice Crypto-RPC rate limit under demo load | ✅ PASS — 100 req/min, batching counts as 1; demo needs batching | [02-venice-rate-limit/RESULT.md](./02-venice-rate-limit/RESULT.md) |
| 3 | `venice-x402-client` × MM Smart Accounts compat | ⚠️ PASS-with-caveat (desk research) | [03-venice-x402-mm-smart-accts/RESULT.md](./03-venice-x402-mm-smart-accts/RESULT.md) |
| 4 | Event → delivery latency on Base Sepolia | ✅ PASS (WS-fallback path; median 3.2 s) | [04-event-webhook-latency/RESULT.md](./04-event-webhook-latency/RESULT.md) |
| 5 | Private-mempool relay availability on Base Sepolia | ⚠️ PASS-with-fallback | [05-private-mempool-base-sepolia/RESULT.md](./05-private-mempool-base-sepolia/RESULT.md) |
| 6 | Base Sepolia USDC address | ✅ PASS | [06-base-sepolia-usdc-address/RESULT.md](./06-base-sepolia-usdc-address/RESULT.md) |
| 7 | Tauri ↔ browser ↔ MM ↔ Tauri callback round-trip | ✅ PASS (after Windows opener fix) | [07-tauri-bridge-roundtrip/RESULT.md](./07-tauri-bridge-roundtrip/RESULT.md) |
| 8 | ERC-7715 `requestExecutionPermissions` e2e | ✅ PASS — signed grant + delegationManager `0xdb9B…7dB3` | [08-erc7715-request-permissions/RESULT.md](./08-erc7715-request-permissions/RESULT.md) |
| 9 | MetaMask Flask version detection | ✅ PASS (Flask v13.32.0 detected) | [09-mm-flask-version-detect/RESULT.md](./09-mm-flask-version-detect/RESULT.md) |
| 10 | CORS preflight on Tauri callback server | ✅ PASS (dev path; evil-origin curl check owed) | [10-cors-preflight/RESULT.md](./10-cors-preflight/RESULT.md) |

Status legend: ✅ PASS · ❌ FAIL · ⚠️ PASS-with-caveats · 🚫 BLOCKED · ⏳ pending

## What's owed before architecture lock

1. ~~Fund Venice~~ — DONE. Account funded with $1; spikes 1 & 2 ran successfully and produced load-bearing findings (Venice routing is non-public-mempool, 100 req/min cap, batching = 1 request).
2. ~~Tenderly signup~~ — superseded. Spike 4 uses the WS-fallback path (`eth_subscribe` over public WS) and PASSes with a 3.2 s median.
3. **Run the manual e2e** for spikes 7, 8, 9, 10:
   - `cd frost && npm run tauri dev`
   - `cd web && npm install && npm run dev`
   - In the Tauri window, navigate to `/bridge` and run each operation in turn.
4. **Spike 3 phase 2**: install `venice-x402-client` + `@metamask/smart-accounts-kit` in a workspace and run the two adapter paths. Defer until Week 1 Day 4 — not architecture-blocking.

**Architecture is locked.** All ten Day-1 spikes pass (with documented caveats per spike). The remaining items below are cleanup, not blockers:

- Spike 3 phase 2 (Venice x402 × MM Smart Accounts adapter implementation) — Week 1 Day 4.
- Spike 10 evil-origin curl check — 5 minutes before Week 1 Day 2 bridge build.
- Promote `delegationManager` address `0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3` (Base Sepolia) into `HANDOFF.md` "Locked decisions".
- Pin the Flask-13.32 ERC-7715 schema into `wallet-bridge-spec.md` (current draft uses the older shape).

## Planned follow-up work (not Day-1 spikes)

- **Sepolia-side x402 testbed.** Venice's x402 paywall is mainnet-only. For the demo path on Base Sepolia (and for any contributor who hasn't funded Venice), build a local x402 facilitator + receiver pair on Base Sepolia that exercises the EIP-3009 `transferWithAuthorization` flow against test USDC. The real Venice integration is the documented production path; the testbed is the contributor- and demo-friendly path. Tracked in `HANDOFF.md` (to add) — Week-1+ scope, not a verification spike.

## Running

1. Copy `.env.example` → `.env` at `spikes/` root and fill the values.
2. From `spikes/`: `npm install` (already done if you ran spike 6).
3. Each spike's `README.md` documents its run command.

## Layout

```
spikes/
  shared/                # viem clients, Venice RPC wrapper, constants
  NN-<slug>/
    README.md            # what + how to run
    run.ts | run.ps1     # the harness
    RESULT.md            # filled in after running
```

Harnesses are disposable — they exist to produce evidence, not to be reused as library code. Two exceptions: (a) `shared/base-sepolia.ts` captures constants used by later builds, and (b) the wallet-bridge skeleton in `frost/src-tauri/src/wallet_bridge.rs` + `web/app/connect/` survives spike 7 and is what Week-1 Day 2-7 extends.
