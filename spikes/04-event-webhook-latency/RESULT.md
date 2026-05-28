# Spike 4 — Event-to-delivery latency on Base Sepolia

**Status:** ✅ PASS
**Date:** 2026-05-28
**Run by:** Claude (automated)
**Path:** **WS fallback** (`eth_subscribe('logs')` over public Base Sepolia WS) — Tenderly Web3 Actions deferred per user choice.

## Method

1. Compiled `Emitter.sol` (`compile.ts`) and deployed via the funded Base Sepolia test wallet. Emitter address cached in `.deployed`.
2. Opened a WebSocket to `wss://base-sepolia.publicnode.com` and subscribed `eth_subscribe('logs', { address, topics: [Ping] })`.
3. Fired 5 `ping()` transactions, 10 s apart. Recorded:
   - `sendTs` — wall clock right before `sendTransaction`
   - `blockTs` — `block.timestamp * 1000` from the receipt
   - `recvTs` — wall clock when the WS pushed the log
4. The meaningful latency for "moment 1" demo pacing is `recvTs - sendTs` (submit-to-observed). `recvTs - blockTs` goes negative on Base Sepolia (~-3 s) because the block proposer's timestamp typically lands ~one slot ahead of when the log reaches a subscriber.

## Observation

```
Emitter:        0x56378bcc125ee84d2503983be8a0ed6815d18b83
Ping topic0:    0x2cbdbe00cebef89186c967208065ecaafca1aa8a8971c4ccaa8ac017a9cad9ae
WS endpoint:    wss://base-sepolia.publicnode.com
```

| # | tx | block | sendTs | blockTs | recvTs | recv-send (ms) |
|---|---|---|---|---|---|---|
| 1 | `0x541c8c03…` | 42085914 | 1779940110881 | 1779940116000 | 1779940113021 | **2140** |
| 2 | `0xe2fcad5c…` | 42085920 | 1779940121612 | 1779940128000 | 1779940124984 | **3372** |
| 3 | `0xa474fb55…` | 42085926 | 1779940132924 | 1779940140000 | 1779940136991 | **4067** |
| 4 | `0x07783177…` | 42085931 | 1779940144958 | 1779940150000 | 1779940147026 | **2068** |
| 5 | `0x088e590b…` | 42085937 | 1779940155765 | 1779940162000 | 1779940159000 | **3235** |

**Median submit→deliver latency: 3,235 ms (range 2,068 – 4,067 ms).** All 5 samples landed within 5 seconds. Raw payload in `raw-results.json`.

## Decision impact

- Demo script's "moment 1" pacing (≤ 5 s) is comfortable with the WS-fallback observer. No re-design needed.
- The demo can observe contract events via a direct WS subscription rather than booking a Tenderly Web3 Action. Saves the Tenderly dependency for the hackathon build.
- If we later want webhook delivery (mobile push, queue ingestion, etc.), revisit Tenderly — but the architecture does not require it.

## Caveats

- `publicnode.com` is unauthenticated and rate-limited; for production we'd front this with QuickNode/Alchemy/Tenderly Node. The latency floor on a paid node is typically lower.
- Latencies are one-shot from a Windows host on residential broadband; results may vary by ±500 ms.
- Block-timestamp arithmetic is unreliable on L2s — do not use `blockTs` as a latency baseline; use the moment of `sendTs` or `eth_blockNumber` poll instead.

## Sources

- viem `webSocket` transport + `eth_subscribe` — https://viem.sh/docs/clients/transports/websocket.html
- Base Sepolia public WS — https://docs.base.org/base-chain/network-information/base-sepolia-testnet
