# Spike 5 — Private-mempool relay availability on Base Sepolia

**Status:** ⚠️ PASS-with-fallback
**Date:** 2026-05-28
**Run by:** Claude (desk research)

## Method

Reviewed the public docs and marketing pages for the four most-cited private-mempool relays:

- Flashbots Protect
- bloXroute
- Merkle / blink
- Blocknative

## Observations

| Provider | Base Mainnet | Base Sepolia | Notes |
|---|---|---|---|
| Flashbots Protect | No (Ethereum mainnet + Sepolia/Holesky only as of search) | No | Flashbots docs explicitly list supported networks as Ethereum mainnet + Sepolia + Holesky; "actively building support for other networks, including L2s." No Base Sepolia coverage. |
| bloXroute | Limited (focus on BSC/SOL; ETH mainnet supported) | No | Marketing pages emphasize BSC, Solana, Ethereum. No Base Sepolia. |
| Merkle (blink) | **Yes** (Base listed among supported chains) | Not documented | Their docs list Ethereum, BSC, Polygon, **Base**, Solana, Arbitrum. Testnet support is not advertised. Worth a direct inquiry if mainnet plans need a partner. |
| Blocknative | N/A | No | The Blocknative team has joined Deloitte; users advised to plan migration before 2026-06-19. Treat as discontinued for our purposes. |

## Verdict

No reliable private-mempool relay exists on Base Sepolia today.

## Decision impact

Confirms the **locked fallback** from `HANDOFF.md` and `contract-architecture.md` §1.4:

> "If none on testnet: demo via 1Shot's submission with private-mempool design documented; mainnet will use real relay."

Action items:

1. Executor sub-agent on testnet → submit via 1Shot. Private-mempool semantics are designed in but only enforced at mainnet.
2. For mainnet, **Merkle (blink)** is the most likely partner — they already support Base. Add to `hackathon-plan.md` Phase-2 follow-up list.
3. No code change required by this spike.

## Sources

- Flashbots Protect supported networks — <https://docs.flashbots.net/flashbots-protect/quick-start>
- Merkle private pool — <https://docs.merkle.io/private-pool/what-is-private-mempool>
- bloXroute — <https://bloxroute.com/>
- Blocknative — <https://www.blocknative.com/>
