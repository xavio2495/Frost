// Stub for spike 3 — the empirical phases happen after Phase 1 baseline is
// run from a real workspace that has `venice-x402-client` installed. Keeping
// this as a placeholder so spikes/README.md links to a real file.
//
// Next steps for whoever runs this:
//
// 1. Phase 1 baseline:
//      pnpm add venice-x402-client
//      then write a 10-line script: new VeniceClient(privateKey), do one
//      chat completion, observe the on-chain USDC settlement.
//
// 2. Phase 2 Smart Account:
//      pnpm add @metamask/smart-accounts-kit
//      build a toMetaMaskSmartAccount(...) instance, and try to inject it
//      into the SDK. Document the exact signing call site touched.
//
// See README.md in this folder.
console.error("Spike 3 harness intentionally not implemented yet.");
console.error("Read spikes/03-venice-x402-mm-smart-accts/README.md for the procedure.");
console.error("(This stub is here so the index in spikes/README.md has a real file to link to.)");
process.exit(2);
