# Spike 4 — Event-to-notification latency on Base Sepolia

Free alternative to Alchemy Notify: **Tenderly Web3 Actions**.

## Goal

Measure median latency from on-chain event emission to webhook delivery on Base Sepolia. The demo's "moment 1" timing depends on this number; if >5 s, we adjust the script.

## Method

### One-time setup (manual, via Tenderly UI)

1. Sign up at <https://dashboard.tenderly.co> (free tier; no card).
2. Create a new project. Note the account slug + project slug; put them in `spikes/.env` as `TENDERLY_ACCOUNT_SLUG` and `TENDERLY_PROJECT_SLUG`.
3. Generate an access token; put in `.env` as `TENDERLY_ACCESS_KEY`.
4. Provision a `webhook.site` URL (or a temporary Cloudflare tunnel pointing to a local recorder) and put it in `.env` as `WEBHOOK_RECEIVER_URL`.
5. In Tenderly → Web3 Actions → New Action: trigger = `Event Emitted`, network = Base Sepolia, contract = the Emitter address from step 7 below, event signature = `event Ping(uint256 nonce, uint256 ts)`. Action handler = a tiny JS function that POSTs `{ block, nonce, recvTs: Date.now() }` to `WEBHOOK_RECEIVER_URL`.
6. Save and enable the action.
7. Deploy `Emitter.sol` (single line: `function ping() external { emit Ping(++nonce, block.timestamp); }`) to Base Sepolia. Address goes in `.env` as `EMITTER_ADDRESS`. Foundry one-liner:
   ```
   forge create Emitter --rpc-url https://base-sepolia.publicnode.com --private-key $BASE_SEPOLIA_PK
   ```

### Run

```
cd spikes
pnpm install
pnpm spike:4
```

The script fires 5 `ping()`s spaced 10 s apart, records the block timestamp at inclusion, then polls `webhook.site`'s JSON API to read each delivery's `recvTs`, and prints the deltas.

## Pass criteria

- Five samples gathered.
- Median latency recorded in `RESULT.md`.
- If median > 5 s, surface to update demo pacing.

## Fallback path

If Tenderly free tier is restricted in 2026, switch to:

- QuickNode Streams (free tier),
- or self-hosted: subscribe to `eth_subscribe('logs', { address: EMITTER_ADDRESS })` over the public WS endpoint, measure block→client delivery. Different surface (no separate webhook hop) but answers "how fast can a sub-agent learn about an event".
