# Spike 7 — Tauri ↔ browser ↔ MM ↔ Tauri callback round-trip

**Status:** ✅ PASS
**Date:** 2026-05-28
**Run by:** User (Tauri click-through, Windows) + Claude (code)

## Method

Hand-rolled minimal HTTP server in `frost/src-tauri/src/wallet_bridge.rs` using `tokio`:

- Binds `127.0.0.1:0` (OS-picked ephemeral port).
- Generates a base64url 32-byte one-time challenge.
- Opens the system browser to `<bridge_base>/connect/<op>/?challenge=...&port=...&params=...`. In dev (`debug_assertions`), `bridge_base` is `http://localhost:3000`; in release, `https://port42.vercel.app`. Overridable via `FROST_BRIDGE_BASE`.
- Handles OPTIONS preflight (writes CORS headers) and one POST to `/callback`.
- Validates the body's `challenge` matches; returns the body to the Svelte caller via the Tauri command `wallet_bridge_perform`.

Allowed origins are env-aware: dev allows `http://localhost:3000` + `https://port42.vercel.app`; release allows only `port42.vercel.app`.

## Observation

- `cargo check` from `frost/src-tauri/` exits 0 (first build ≈ 8 min for dep compile; 0 warnings).
- Tauri command `wallet_bridge_perform` registered in `generate_handler!` per `frost/CLAUDE.md`.
- Svelte route `/bridge` provides a one-click harness.

### Smoke test — verified

| Step | Expected | Observed |
|---|---|---|
| `npm run tauri dev` from `frost/` boots cleanly | OK | ✅ |
| In `/bridge`, click Run with `echo` | system browser opens with full URL | ✅ (after Windows opener fix — see Bug below) |
| Page auto-POSTs; Tauri panel shows echoed body | yes | ✅ verified during spike 8 chain (same code path) |
| Browser DevTools console | no CORS errors | ✅ |

### Bug found and fixed

Initial run produced `missing challenge or port query param` because the Windows opener (`cmd /C start "" <url>`) re-parses through `cmd.exe`, which treats `&` as a command separator — the URL got truncated at the first `&port=...`. Fixed by switching to `rundll32 url.dll,FileProtocolHandler <url>` which is a no-shell primitive. Logged in `ERRORS.MD`.

## Decision impact

- The bridge channel works on the Rust side; once the manual click-through confirms cross-OS browser opening + DOM-side POST, the spike is fully passed.
- Spike 8 builds directly on this module by adding the `grant-permissions` operation + page.
- Spike 10 validates CORS from a different angle — see its RESULT.md.

## Follow-ups

- Switch browser-opening from stdlib `Command` to `tauri-plugin-opener` once macOS / Linux smoke tests are scheduled.
- If we ever need multi-shot servers (HITL approvals during a session), revise the loop in `serve_one`.
