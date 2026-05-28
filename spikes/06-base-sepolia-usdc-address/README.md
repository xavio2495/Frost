# Spike 6 — Base Sepolia USDC address

## Goal

Confirm the canonical USDC contract address on Base Sepolia. This address will be hardcoded immutably in `Settlement` per `contract-architecture.md`.

## Method

1. Look up the address in Circle's official testnet table: <https://developers.circle.com/stablecoins/usdc-on-test-networks>
2. Look up the address in Base's official docs: <https://docs.base.org/base-chain/network-information/base-sepolia-testnet>
3. Call `name()`, `symbol()`, `decimals()` on the address via Venice Crypto-RPC. Expect `"USD Coin"` / `"USDC"` / `6`.
4. PASS if all three sources agree.

## Run

```
pnpm install
pnpm spike:6
```

Requires `VENICE_API_KEY` in `spikes/.env`.

## Expected address

`0x036CbD53842c5426634e7929541eC2318f3dCF7e` (Circle + Base docs as of 2026-05-28).
