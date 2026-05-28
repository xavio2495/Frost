# Spike 2 — Venice Crypto-RPC rate limit under demo-shaped load

## Goal

Stress Venice's Crypto-RPC with the shape of read traffic the cross-DEX demo will generate (3 parallel pricers × ~10 `eth_call`s) and measure: does it fit under the 100 req/min budget? If not, does batch RPC save us?

## Method

Two passes:

1. **Sequential per pricer, parallel across pricers.** 3 worker tasks; each makes ~10 `eth_call` reads (fake quoter calls on Base Sepolia — payload doesn't need to be a real DEX response, only realistic in size). Run for 60 seconds. Count successes, 429s, p50/p95 latency.
2. **Batch RPC.** Same workload, but each pricer bundles its 10 calls into a single batch request. Compare.

## Run

```
cd spikes
pnpm install
pnpm spike:2
```

Requires `VENICE_API_KEY`.

## Pass criteria

- Demo workload fits under 100 req/min OR batching brings it under, with numbers recorded.
- If neither: surface immediately; would need to request a rate-limit raise from Venice.
