# Spike 6 — Base Sepolia USDC address

**Status:** ✅ PASS
**Date:** 2026-05-28
**Run by:** Claude (automated)

## Method

1. Cross-referenced Circle's testnet USDC table and Base docs — both list the address below.
2. Called `name()` / `symbol()` / `decimals()` against the address via a public Base Sepolia RPC.
3. Venice-RPC cross-check attempted on 2026-05-28 17:xx with `VENICE_API_KEY` populated. Venice returned `{"error":"Insufficient USD or Diem balance to complete request. Visit https://venice.ai/settings/api to add credits."}` — the key authenticates but the account has zero credits. **Public RPC verification stands; Venice cross-check is bonus and blocked on funding the Venice account.**

## Observation

```
Probing USDC at 0x036CbD53842c5426634e7929541eC2318f3dCF7e on Base Sepolia.

[public RPC: https://base-sepolia.publicnode.com]
  name():     USDC
  symbol():   USDC
  decimals(): 6

[Venice RPC] skipped — VENICE_API_KEY not set

PASS
```

`name()` returns `"USDC"` (rather than `"USD Coin"`) — that matches Circle's deployed testnet artifact and is not a red flag.

## Canonical address

```
0x036CbD53842c5426634e7929541eC2318f3dCF7e
```

Recorded in `spikes/shared/base-sepolia.ts` as `USDC_BASE_SEPOLIA`.

## Decision impact

- The `Settlement` contract (per `contract-architecture.md`) hardcodes this address immutably. Use this constant when scaffolding `contracts/`.
- Add to `HANDOFF.md` "Locked decisions" once promoted.

## TODO

- [ ] Fund the Venice account (https://venice.ai/settings/api) and re-run for the Venice-RPC bonus check.

## Sources

- Circle USDC on test networks — <https://developers.circle.com/stablecoins/usdc-on-test-networks>
- Base Sepolia network info — <https://docs.base.org/base-chain/network-information/base-sepolia-testnet>
