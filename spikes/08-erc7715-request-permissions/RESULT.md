# Spike 8 — ERC-7715 `wallet_requestExecutionPermissions` end-to-end

**Status:** ✅ PASS
**Date:** 2026-05-28
**Run by:** User (Flask click-through) + Claude (code)
**Flask version:** v13.32.0

## Method

- `web/app/connect/grant-permissions/page.tsx` reuses `detectMetaMask()` from spike 9 to grab the Flask-only EIP-6963 provider.
- Before requesting permissions, the page ensures (a) account connected (`eth_requestAccounts`) and (b) network is Base Sepolia (`wallet_switchEthereumChain` with `wallet_addEthereumChain` fallback). Both were necessary — Flask's permission-preview UI calls `getTokenBalanceAndMetadata` on the configured chain and fails with `-32001` if the chain isn't present.
- The signed result POSTs back to `localhost:<port>/callback` with the challenge.

## Schema evolution observed

The shape Flask 13.32 accepts is **not** the one in the older docs/spec drafts. Three iterations:

1. **First try (per draft spec)**: `{ chainId, expiry, signer, permission, isAdjustmentAllowed }` — Flask responded with `"Invalid params: 0 > to - Expected a string ... 0 > expiry - Expected a value of type 'never' ... 0 > signer - Expected a value of type 'never' ..."`. So `to` is required, top-level `expiry`/`signer`/`isAdjustmentAllowed` are forbidden.
2. **Second try**: `{ chainId, to, permission: { type, data, isAdjustmentAllowed } }` — Flask responded with `"Failed type validation: 0.rules: Required"`. The EIP-7715 §Rules array is mandatory.
3. **Third try (PASSING)**: added `rules: [{ type: "expiry", data: { timestamp } }]`. Schema validated; Flask then errored on chain config (`-32001 Failed to fetch token balance and metadata`), which was fixed by the chain-switch preflight.

### The shape Flask 13.32 accepts

```json
[
  {
    "chainId": "0x14a34",
    "to": "<delegate address>",
    "permission": {
      "type": "native-token-stream",
      "data": {
        "amountPerSecond": "0x1",
        "maxAmount": "0x1",
        "initialAmount": "0x0",
        "startTime": <unix-sec>,
        "justification": "Frost spike 8 — ERC-7715 round-trip test"
      },
      "isAdjustmentAllowed": true
    },
    "rules": [
      { "type": "expiry", "data": { "timestamp": <unix-sec> } }
    ]
  }
]
```

No top-level `expiry` or `signer` — Flask derives the signer from the connected account, and the EIP's canonical `expiry` rule lives in `rules`.

## Observation

```
state: done
Done. Callback HTTP 200.
```

Granted payload (selected fields, full payload archived in MEMORY):

```json
{
  "chainId": "0x14a34",
  "from": "0xce4389ACb79463062c362fACB8CB04513fA3D8D8",
  "to": "0x0000000000000000000000000000000000000001",
  "delegationManager": "0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3",
  "permission": { "type": "native-token-stream", ... },
  "rules": [ { "type": "expiry", "data": { "timestamp": 1779946106 } } ],
  "context": "0x0000...0041030eecb17f0f8bb24...c00...",
  "dependencies": []
}
```

| Check | Expected | Observed |
|---|---|---|
| Flask permission UI rendered | yes | ✅ |
| Approval returned without error | yes | ✅ |
| Callback delivered to Tauri | yes | ✅ HTTP 200 |
| `granted[0].permission.type === "native-token-stream"` | yes | ✅ |
| `from` field present (granter) | yes | ✅ user's MM account |
| `to` field matches request | yes | ✅ placeholder delegate |
| `delegationManager` present | yes | ✅ `0xdb9B...7dB3` (Base Sepolia MM Delegation Manager) |
| `context` blob present | yes | ✅ 1156 bytes — ABI-encoded delegation chain incl. signature |

## Decision impact

- **Architecture's load-bearing signing channel is confirmed.** Week-1 Day 2-7 (bridge build proper) can proceed.
- **Two new locked facts:**
  - `delegationManager` on Base Sepolia: `0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3` — Settlement / redemption contracts need this address.
  - The dapp must switch/add Base Sepolia *before* calling `wallet_requestExecutionPermissions`; otherwise Flask fails preview rendering with `-32001`. Document in `wallet-bridge-spec.md`.
- **Three new caveats for the spec doc:**
  - The EIP-7715 schema in MetaMask Flask 13.32 differs from older spec drafts in three places (no top-level `signer`/`expiry`/`isAdjustmentAllowed`; mandatory `rules` array; required `to`). Pin the schema in `wallet-bridge-spec.md` to what Flask actually accepts today.
  - `dependencies: []` field present in response — meaning TBD. Likely a list of prerequisite delegations for chained-redemption scenarios.
  - Even with a 1-wei stream and 30-min expiry, Flask still required a configured Base Sepolia network — there's no "minimum-impact override" that bypasses the metadata fetch.

## Sources

- ERC-7715 — <https://eips.ethereum.org/EIPS/eip-7715>
- Empirical Flask 13.32 schema — derived from this spike's iterative validation errors
