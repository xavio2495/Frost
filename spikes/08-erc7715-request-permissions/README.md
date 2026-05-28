# Spike 8 — ERC-7715 `wallet_requestExecutionPermissions` end-to-end

## Goal

The real load-bearing operation. Confirm that a permission spec composed by Frost can travel through the bridge, get signed by the user's MetaMask Flask via `wallet_requestExecutionPermissions`, and return to Tauri as a structurally valid permissions object.

We are **not** redeeming the permission in this spike — that's a later milestone (executor sub-agent + redemption contract). PASS criterion is "Frost receives the signed permissions object."

## Method

Reuses the bridge from spike 7. New route handles spike 8:

- `web/app/connect/grant-permissions/page.tsx` — runs `detectMetaMask()` from `_lib/detect-mm.ts`; if Flask is OK, calls `provider.request({ method: "wallet_requestExecutionPermissions", params: [...] })` with a conservative `native-token-stream` request on Base Sepolia (`amountPerSecond: 0x1`, `maxAmount: 0x1`, 30-min expiry). The signed result POSTs back to `localhost:<port>/callback` with the challenge.

The Rust side already supports `WalletOperation::GrantPermissions` (route_segment = `grant-permissions`) — no Rust changes needed.

## Run

1. From `frost/`: `npm run tauri dev`.
2. From `web/`: `npm install && npm run dev`.
3. In Tauri, `/bridge`, pick `grant_permissions`, set Params to e.g. `{ "session_account": "0x<your-test-session-key-address>" }`, click Run.
4. The browser opens to `localhost:3000/connect/grant-permissions/?…`. The page detects Flask, then opens a MetaMask popup with the structured permission request.
5. Approve in MetaMask. The page POSTs the signed permissions back. Tauri shows the `body.granted` in its result panel.

## Pass criteria

- `granted` arrives in the Tauri result panel.
- `granted[0].permission.type === "native-token-stream"`.
- `granted[0].signer.data.address` matches the `session_account` we passed in.
- A `signature` or equivalent attestation field is present (exact shape depends on MetaMask's response).
- No CORS, no challenge-mismatch errors.

## Failure modes worth distinguishing

- "method not found" → MetaMask Flask is too old or wallet_requestExecutionPermissions isn't enabled. Update Flask.
- Popup never appears → page might not be detecting Flask correctly; check `detect-mm.ts` output in DevTools.
- MetaMask returns an error about permission shape → adjust `defaultPermissionRequest()` to match the current ERC-7715 schema.
