# Spike 9 — MetaMask Flask version detection

## Goal

Land a concrete, reusable detection helper that reliably answers: *is MetaMask Flask >= 13.5.0 installed in this browser?* This is the precondition for the bridge's `/connect/login/` page; without it the user sees a confusing failure later when ERC-7715 calls are rejected.

## Method (locked)

EIP-6963 multi-injection discovery, filtered by `rdns`:

- `io.metamask.flask` → Flask (what we want)
- `io.metamask` → stable MetaMask (prompt user to install Flask)
- nothing → prompt to install Flask

Version is read via the `web3_clientVersion` RPC method, which MetaMask answers with a string like `MetaMask/v13.5.0/flask/<commit>`. Falls back to `0.0.0` if unparseable.

## Deliverables (already in repo)

- `web/app/connect/_lib/detect-mm.ts` — the reusable helper. Exports `detectMetaMask()` and `FLASK_REQUIRED_VERSION`.
- `web/app/connect/login/page.tsx` — minimal page that demonstrates the four detection outcomes. This is also the page that spike 7 will reuse for the bridge round-trip.

## Run

```
cd web
npm install
npm run dev
```

Open `http://localhost:3000/connect/login/` with various combinations:

1. Browser **without any MetaMask**: should show "MetaMask Flask is not installed".
2. Browser with **only stable MetaMask**: should show "Stable MetaMask detected … needs Flask".
3. Browser with **Flask >= 13.5.0**: should show green "ready to connect" with version.
4. Browser with **Flask but pretending to be < 13.5.0** (manually downgrade or mock `web3_clientVersion`): should show "too old".

## Pass criteria

- Cases 1, 2, 3 verified manually by the user.
- Case 4 either verified or noted as "trusts the EIP-6963 rdns + version string; no further runtime guard".

## Sources

- EIP-6963 — <https://eips.ethereum.org/EIPS/eip-6963>
- MetaMask multichain / Snaps detection notes — <https://docs.metamask.io/snaps/>
