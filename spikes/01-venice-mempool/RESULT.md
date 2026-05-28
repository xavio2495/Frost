# Spike 1 — Venice `eth_sendRawTransaction` mempool semantics

**Status:** ✅ PASS (with caveat)
**Date:** 2026-05-28
**Run by:** Claude (automated)
**Verdict:** Venice's RPC submission path is **behaviorally invisible to public mempool subscribers** on Base Sepolia.

## Method

1. Sign a zero-value self-transfer with the funded test wallet (no state change, no value moved).
2. Subscribe to `newPendingTransactions` over a public Base Sepolia WS (`wss://base-sepolia.publicnode.com`).
3. Submit via the Venice Crypto-RPC and observe whether the hash hits the public pending feed before inclusion.
4. **Control:** repeat (1)–(3) but submit through the public RPC directly (`control.ts`). This isolates Venice's routing from the L2's sequencer behavior — if the control is also invisible, the verdict is "L2 architectural" rather than "Venice-specific."

## Observation

```
Venice route:
  Pre-computed tx hash: 0x54d75f5423a5b8b6d61538d579a4720fdb7f6c2ae06f6f50f663939be88810d5
  submit         +0ms
  seen pending   —             ← never appeared
  included       +2978ms
  VERDICT: PRIVATE_MEMPOOL

Public RPC control (publicnode.com):
  Pre-computed tx hash: 0x9b8ea58b0aafe1453016a894983b07890864d2c5061286a73a6b148e54c4475f
  submit         +0ms
  seen pending   +278ms        ← appeared in public feed
  included       +2614ms
  CONTROL VERDICT: SEEN_IN_PUBLIC_PENDING
```

The control shows publicnode.com's pending feed does work — txs submitted through it appear within ~300 ms. The Venice-routed tx never appeared in that feed before inclusion. The behavior is therefore **Venice-specific**, not a Base-Sepolia sequencer artifact.

## Decision impact

- **Locked decision stands:** executor sub-agents continue to submit through 1Shot, not Venice. The threat model (T-21) demands an *explicit* private-pool guarantee, not just observed invisibility — one observation against publicnode does not preclude propagation to other nodes / MEV searchers.
- **New finding worth recording:** Venice's routing is at least *not equivalent to a vanilla public RPC*. This raises the possibility (to be verified with Venice directly) that Venice may itself be MEV-protected on supported chains.
- Re-test on mainnet before relying on this property for anything load-bearing.

## Caveats

- One sample. Could be coincidence — sequencer might have included the tx faster than `publicnode.com`'s pending-feed gossip on this specific block. The control mitigates this somewhat (control was seen at +278 ms with a 2.6 s inclusion window — so publicnode's feed is functional on the same WS connection in the same time window).
- Venice's exact routing target (Base sequencer direct? private relay? proxied through a public node?) is not determinable from this experiment alone — it would need either docs from Venice or a multi-node observation.
- This experiment cost 1 Venice RPC call. Account balance impact: negligible.

## Files

- `run.ts` — Venice submission + public mempool observer
- `control.ts` — public-RPC submission control (sister script)
