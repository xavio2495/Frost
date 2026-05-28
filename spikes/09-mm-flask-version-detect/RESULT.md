# Spike 9 — MetaMask Flask version detection

**Status:** ✅ PASS
**Date:** 2026-05-28
**Run by:** User (manual browser verify) + Claude (code)

## Method

EIP-6963 multi-injection discovery + `web3_clientVersion` RPC for the version string. Filter by `info.rdns === "io.metamask.flask"` to distinguish Flask from stable MetaMask, then semver-compare against `13.5.0`.

## Observation

Code landed in:

- `web/app/connect/_lib/detect-mm.ts` — `detectMetaMask()` returns one of four discriminated states (`no-metamask` | `stable-only` | `flask-too-old` | `flask-ok`).
- `web/app/connect/login/page.tsx` — minimal client page that runs the helper on mount and renders the appropriate prompt.

This file structure also seeds the layout the rest of the bridge will use (`/connect/<operation>/page.tsx` + `/connect/_lib/*`).

### Outstanding manual checks (user-driven)

| Scenario | Expected | Observed |
|---|---|---|
| No MetaMask installed | "MetaMask Flask is not installed" | _user to verify_ |
| Stable MetaMask only | "Stable MetaMask detected … needs Flask" | _user to verify_ |
| Flask ≥ 13.5.0 (the user's current setup) | "ready to connect" + version | ✅ verified — `flask-ok`, v13.32.0 |
| Flask < 13.5.0 | "too old, please update" | _will be covered when a real outdated Flask is on hand; not blocking_ |

### Side-fix during verify

The `login/page.tsx` JSON dump was crashing on `JSON.stringify` because `MMDetection.detail.provider` is a live EIP-1193 object with circular module refs (Next.js 16 wraps modules bidirectionally). Patched the page to strip the provider before stringifying — render now shows `provider: "[EIP-1193 provider — omitted]"`.

## Decision impact

- The bridge's `/connect/login/` route is the first user touchpoint and now has a deterministic Flask gate. The same helper will be imported by `/connect/grant-permissions/` (spike 8) to refuse to start the permission flow if Flask is wrong.
- If `web3_clientVersion`'s format changes in a future MetaMask release, we degrade gracefully to `flask-ok` with `version === "0.0.0"`. That's an under-restrictive failure mode; the alternative (refusing all Flask) is worse. Revisit if MM changes its version-reporting API.

## Sources

- EIP-6963 — <https://eips.ethereum.org/EIPS/eip-6963>
- MetaMask Snaps docs — <https://docs.metamask.io/snaps/>
