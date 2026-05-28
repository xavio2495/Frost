// Control for spike 1: submit via PUBLIC RPC (publicnode.com), watch the same
// newPendingTransactions feed. If the tx is also invisible here, the
// "PRIVATE_MEMPOOL" verdict from the Venice run is an L2 sequencer property,
// not a Venice routing property.
import { parseEther, keccak256, type Hash } from "viem";
import WebSocket from "ws";
import { BASE_SEPOLIA_HTTP, BASE_SEPOLIA_WS, testWallet } from "../shared/base-sepolia.js";

const OBS_TIMEOUT_MS = 60_000;
const now = () => Date.now();

async function observePending(target: Hash): Promise<number | null> {
  return new Promise((resolve) => {
    const ws = new WebSocket(BASE_SEPOLIA_WS);
    let subId: string | null = null;
    let done = false;
    const finish = (t: number | null) => { if (done) return; done = true; try { ws.close(); } catch {}; resolve(t); };
    const timer = setTimeout(() => finish(null), OBS_TIMEOUT_MS);
    ws.on("open", () => ws.send(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_subscribe", params: ["newPendingTransactions"] })));
    ws.on("message", (raw) => {
      const m = JSON.parse(raw.toString());
      if (m.id === 1 && typeof m.result === "string") { subId = m.result; return; }
      if (m.method === "eth_subscription" && m.params?.subscription === subId) {
        const h = (m.params.result as string).toLowerCase();
        if (h === target.toLowerCase()) { clearTimeout(timer); finish(now()); }
      }
    });
    ws.on("error", () => finish(null));
  });
}

async function pollInclusion(hash: Hash, started: number) {
  const deadline = started + OBS_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const r = await fetch(BASE_SEPOLIA_HTTP, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getTransactionReceipt", params: [hash] }) });
    const j = await r.json() as { result?: { blockNumber?: string } | null };
    if (j.result?.blockNumber) return Date.now();
    await new Promise((x) => setTimeout(x, 1500));
  }
  return null;
}

async function main() {
  const { account, walletClient } = testWallet();
  console.log(`Wallet: ${account.address}`);
  const tx = await walletClient.prepareTransactionRequest({ account, to: account.address, value: parseEther("0") });
  const serialized = await walletClient.signTransaction(tx);
  const txHash = keccak256(serialized) as Hash;
  console.log(`Pre-computed hash: ${txHash}`);
  console.log("Subscribing to public pending feed...");
  const pendingP = observePending(txHash);
  await new Promise((r) => setTimeout(r, 1500));
  console.log(`Submitting via PUBLIC RPC: ${BASE_SEPOLIA_HTTP}`);
  const t0 = now();
  const r = await fetch(BASE_SEPOLIA_HTTP, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_sendRawTransaction", params: [serialized] }) });
  const j = await r.json() as { result?: Hash; error?: { message: string } };
  if (j.error) { console.error("submit error:", j.error); process.exit(1); }
  console.log(`  hash: ${j.result}`);
  const inc = await pollInclusion(j.result!, t0);
  const pend = await pendingP;
  console.log(`\nTimings (rel submit):`);
  console.log(`  submit       +0ms`);
  console.log(`  seen pending ${pend === null ? "—" : "+" + (pend - t0) + "ms"}`);
  console.log(`  included     ${inc === null ? "—" : "+" + (inc - t0) + "ms"}`);
  const verdict = pend !== null ? "SEEN_IN_PUBLIC_PENDING" : "INVISIBLE_IN_PUBLIC_PENDING";
  console.log(`\nCONTROL VERDICT: ${verdict}`);
}

main().catch((e) => { console.error("FAIL:", e); process.exit(1); });
