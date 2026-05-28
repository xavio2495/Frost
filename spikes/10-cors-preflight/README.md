# Spike 10 — CORS preflight on the Tauri callback server

## Goal

Confirm that the browser's `OPTIONS /callback` preflight succeeds against the Tauri local server for both the dev origin (`http://localhost:3000`) and the prod origin (`https://port42.vercel.app`), with the correct `Access-Control-Allow-*` headers.

## Implementation

CORS handling lives in `frost/src-tauri/src/wallet_bridge.rs`. Two functions are relevant:

- `allowed_origins()` — returns `["https://port42.vercel.app", "http://localhost:3000"]` in dev builds (`#[cfg(debug_assertions)]`), and `["https://port42.vercel.app"]` only in release.
- `write_preflight()` — responds `204 No Content` with:
  ```
  Access-Control-Allow-Origin: <origin>
  Access-Control-Allow-Methods: POST, OPTIONS
  Access-Control-Allow-Headers: Content-Type
  Access-Control-Max-Age: 600
  Vary: Origin
  ```
  When the incoming `Origin` header is not in the allowlist, `Allow-Origin` is set to `null` (the browser will refuse the subsequent POST, which is what we want).

## Verification

### Path A — exercised by spike 7 (recommended)

When you click Run in `/bridge` with `operation = echo`, the browser at `localhost:3000` POSTs cross-origin to `localhost:<ephemeral>/callback`. Modern browsers send an OPTIONS preflight first because the request includes `Content-Type: application/json` (a non-simple header).

Open Chrome DevTools → Network and confirm:

- One `OPTIONS /callback` returns `204` with `access-control-allow-origin: http://localhost:3000`.
- One `POST /callback` returns `200`.

If you see only the POST (no OPTIONS), the request was treated as "simple"; verify by inspecting headers. If the OPTIONS fails, the POST is blocked and the Svelte UI will time out.

### Path B — prod-origin smoke test

```
# In frost/src-tauri, build in release mode:
cargo build --release
# Then run the desktop app with FROST_BRIDGE_BASE forcing the prod connect host:
$env:FROST_BRIDGE_BASE = "https://port42.vercel.app"   # PowerShell
```

Trigger `/bridge` → Run with `echo`. The browser will load the prod page (once deployed); the prod page POSTs back to the same `localhost:<port>/callback` from origin `https://port42.vercel.app`. The OPTIONS should also succeed.

### Path C — quick CLI curl (no browser)

```
# Replace <port> with the port printed in the Tauri console.
curl -i -X OPTIONS http://127.0.0.1:<port>/callback `
  -H "Origin: http://localhost:3000" `
  -H "Access-Control-Request-Method: POST" `
  -H "Access-Control-Request-Headers: Content-Type"
```

Expected: `204 No Content` with the three Allow-* headers above.

```
curl -i -X OPTIONS http://127.0.0.1:<port>/callback `
  -H "Origin: https://evil.example.com" `
  -H "Access-Control-Request-Method: POST"
```

Expected: `204` with `Access-Control-Allow-Origin: null` — the browser will refuse the follow-up POST, which is the security property we want.

## Pass criteria

- Dev preflight from `http://localhost:3000` returns 204 with the right headers.
- Prod preflight from `https://port42.vercel.app` returns 204 with the right headers.
- An untrusted origin returns `Allow-Origin: null` (or no Allow-Origin), blocking the POST.
