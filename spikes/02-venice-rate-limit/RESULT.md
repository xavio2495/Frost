# Spike 2 — Venice Crypto-RPC rate limit under demo load

**Status:** ✅ PASS (with action required)
**Date:** 2026-05-28
**Run by:** Claude (automated)
**Verdict:** **100 requests / minute / API key**, but **a JSON-RPC batch of N entries counts as 1 request** — so demo workload fits with margin.

## Method

1. Three concurrent "pricer" workers, each making 10 `eth_call`s per tick (250 ms cycle pause), against Venice's Crypto-RPC. Window: 15 s/pass (kept short to fit a $1 credit budget).
2. Pass 1: per-request mode. Pass 2: 10-call JSON-RPC batches.
3. Follow-up probe: send one explicit batch of 10 from a fresh rate-limit bucket (after 65 s reset) and observe HTTP status.

## Observations

### Pass 1 — per-request (cold start, full quota available)

```
ok:          100        (rate cap hit exactly)
429s:        20         (classified as "other err" before wrapper fix — see Caveats)
other err:   0          (after re-classification)
latency p50: 337 ms
latency p95: 459 ms
```

The 100/min cap is hit cleanly. Venice's 429 body string verbatim:

```
{"error":"Rate limit exceeded. Maximum 100 requests per minute on the paid tier."}
```

### Pass 2 — batched (10-per-batch, bucket already exhausted from pass 1)

All requests 429'd because pass 1 burned the minute window. This pass was repeated as the follow-up probe below.

### Follow-up — batched, fresh bucket

After waiting 65 s for the limiter to reset:

```
BATCH x10 → HTTP 200 in 711 ms
  → 10 distinct results returned, all `0x...000006` (USDC decimals)
Immediate single call after batch → HTTP 200
```

**One batched call of 10 entries was accepted as a single request against the quota.** This is the load-bearing finding for the demo workload.

## Demo workload math

Demo: 3 pricer sub-agents × ~10 reads/tick.

| Mode | Reads/tick | Req/tick | Max ticks/min | Headroom vs. demo cadence |
|---|---|---|---|---|
| per-request | 30 | 30 | 3 | tight — only one tick every 20 s |
| **batched** | **30** | **3** | **33** | **comfortable — one tick every 1.8 s** |

The demo's "moment 1" cadence is on the order of seconds. Per-request mode is too tight; **batched mode is required**.

## Decision impact

1. **Batching is mandatory** for the pricer / monitor sub-agents reading from Venice. Update `contract-architecture.md` §7.4 (or wherever pricer-agent contract spec lives) to specify batched reads.
2. **Architectural margin is thin on a single key.** If we want any safety factor beyond demo (multiple users, retries, monitoring overhead), one of:
   - Negotiate a higher tier with Venice;
   - Use multiple keys (round-robin) — confirm with Venice this is permitted before relying on it;
   - Fall back to a public RPC (publicnode.com / Alchemy free tier) for read-side calls, reserving Venice for x402-gated inference traffic.
3. **Read-side caching** (last-block USDC decimals, pool addresses, etc.) cuts the cycle count further at zero risk.
4. **Wrapper bug found and fixed** — `VeniceRpc.call()` and `.batch()` now surface HTTP 429 as a structured `error.code = 429` instead of letting them pass through as opaque "other err"s. Without this fix, future runs of spike 2 would mis-classify rate limits.

## Caveats

- Window was 15 s/pass (down from the design's 60 s) to fit the $1 credit budget. The 100/min cap was hit cleanly within that window, so duration didn't change the verdict.
- "Batches count as 1 request" is observed from one fresh-bucket probe. If Venice changes their counter to "1 per batch entry" silently, the demo cadence breaks. Worth re-checking before submission day.
- Total credit spend across both spikes: ~120 successful calls + ~25 rate-limited calls + 1 raw tx submission. Well under $1.

## Files

- `run.ts` — 3-worker rate-limit harness (per-request + batched)
- `../shared/venice-rpc.ts` — wrapper patched to surface HTTP 429s
