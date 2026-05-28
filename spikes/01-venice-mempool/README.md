# Spike 1 — Venice `eth_sendRawTransaction` mempool semantics

## Goal

Determine whether transactions submitted via Venice's Crypto-RPC reach Base Sepolia's *public* mempool (visible to anyone subscribed to `newPendingTransactions`) or whether Venice routes them through a private channel. Threat T-21's mitigation strategy hinges on this.

## Method

1. Open a WebSocket to a public Base Sepolia node (`wss://base-sepolia.publicnode.com`).
2. Subscribe to `newPendingTransactions` (full bodies, so we can match by hash).
3. Sign a tiny self-transfer (0 ETH from the test wallet to itself, low priority fee).
4. Submit via Venice's `eth_sendRawTransaction`. Capture `tx_submit_ts`.
5. Watch the WS subscription for the resulting hash. Capture `seen_in_pending_ts` (if it ever appears).
6. Poll the public RPC for inclusion. Capture `included_ts`.

Decision:

- `seen_in_pending` BEFORE `included` → **public mempool** (executor must continue using 1Shot for the write path; locked decision stands).
- `seen_in_pending` never observed, only `included` → **private mempool** (Venice could theoretically replace 1Shot; surface that finding so the team can debate it).

## Run

```
cd spikes
pnpm install
pnpm spike:1
```

Requires in `.env`: `VENICE_API_KEY`, `BASE_SEPOLIA_PK` (funded with at least 0.001 ETH for gas).

## Pass criteria

A definitive PUBLIC or PRIVATE label with the timestamps for both observations.
