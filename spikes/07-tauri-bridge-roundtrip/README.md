# Spike 7 — Tauri ↔ browser ↔ MetaMask ↔ Tauri callback round-trip

## Goal

End-to-end smoke test of the wallet bridge channel: Tauri opens an ephemeral localhost server, opens the system browser to a hosted page, the page POSTs back, Tauri validates the challenge, returns to Svelte. No MetaMask involved yet — spike 8 layers MM on top.

## Deliverables (already in repo)

- `frost/src-tauri/src/wallet_bridge.rs` — hand-rolled HTTP server on `127.0.0.1:0`, challenge-bound, single-shot, CORS-aware. Exposes `wallet_bridge_perform` Tauri command.
- `frost/src-tauri/Cargo.toml` — adds `tokio`, `rand`, `base64`, `urlencoding`, `thiserror`.
- `frost/src-tauri/src/lib.rs` — registers `wallet_bridge_perform` in `generate_handler!`.
- `frost/src/routes/bridge/+page.svelte` — operator UI to fire the bridge.
- `web/app/connect/echo/page.tsx` — auto-POSTs the challenge back on mount.

Cargo check passes (`cargo check` in `frost/src-tauri/` — 7m 57s first build, 0 warnings).

## Run

1. **Web side**: from `web/`, run `npm install && npm run dev`. Confirm `http://localhost:3000/connect/echo/?challenge=foo&port=1` renders (it'll show "missing or invalid port" — that's fine, we just want the page to load).
2. **Tauri side**: from `frost/`, run `npm run tauri dev`.
3. In the Tauri window, navigate to `/bridge`.
4. With `operation = echo`, click **Run**. The system browser should open to `localhost:3000/connect/echo/?...`. The page auto-POSTs back. Tauri shows the JSON result with `challenge` + `hello: "world"`.

## Pass criteria

- The Svelte UI receives `{ challenge, body: { hello: "world", ... } }`.
- The challenge in the response matches what Tauri sent (binding works).
- No CORS errors in the browser console.
- Smoke-tested on Windows (user's primary platform). Mac/Linux noted as not-yet-tested.

## Known issues / follow-ups

- The browser opener for Linux/macOS is a stdlib `Command` — production should switch to `tauri-plugin-opener` for consistent behavior.
- The HTTP parser is hand-rolled and minimal. Sufficient for one OPTIONS + one POST; not a general-purpose server.
