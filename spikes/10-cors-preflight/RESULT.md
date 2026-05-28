# Spike 10 — CORS preflight on Tauri callback server

**Status:** ✅ PASS (dev-origin path; production/evil-origin paths still owed)
**Date:** 2026-05-28
**Run by:** User (implicit, via spike 7/8 round-trips) + Claude (code)

## Method

Implementation in `frost/src-tauri/src/wallet_bridge.rs`:

- OPTIONS handler returns 204 with `Access-Control-Allow-Origin`, `Access-Control-Allow-Methods: POST, OPTIONS`, `Access-Control-Allow-Headers: Content-Type`, `Access-Control-Max-Age: 600`, `Vary: Origin`.
- Allowed origins differ by build:
  - dev (`debug_assertions`): `http://localhost:3000`, `https://port42.vercel.app`
  - release: `https://port42.vercel.app` only
- Disallowed origins are echoed as `Allow-Origin: null`, which causes the browser to block the follow-up POST. This is the intended security property.

`cargo check` clean. The OPTIONS path is exercised every time spike 7's harness fires the round-trip.

## Observation (to be filled in)

| Origin | Build | Expected | Observed |
|---|---|---|---|
| `http://localhost:3000` | dev | 204 + `Allow-Origin: http://localhost:3000` | ✅ verified — spikes 7 & 8 both completed the cross-origin POST round-trip; no CORS errors in DevTools |
| `https://port42.vercel.app` | dev | 204 + `Allow-Origin: https://port42.vercel.app` | not exercised — production bridge isn't being used in dev |
| `https://port42.vercel.app` | release | 204 + same | owed at release-bundle smoke (post-Day-1) |
| `https://evil.example.com` | any | 204 + `Allow-Origin: null` → POST blocked | owed — quick curl check before Week-1 Day 2 |

See `README.md` in this folder for the exact curl invocations and DevTools steps.

## Decision impact

CORS misconfiguration was called out in `HANDOFF.md` spike 10 as "looks like 'page completed but Frost didn't update', hard to debug after the fact." With the implementation in place, the failure mode is now explicit (the browser will log a CORS error), and the security boundary (no third-party origin can post into Frost's local server) is enforced.

If a future Tauri version starts trusting non-allowed origins for some reason, the regression would manifest as the `evil.example.com` row above starting to succeed — keep that test in the smoke list.
