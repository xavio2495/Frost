import { parseEther, type Hash } from "viem";
import WebSocket from "ws";
import { BASE_SEPOLIA_HTTP, BASE_SEPOLIA_WS, testWallet } from "../shared/base-sepolia.js";
import { VeniceRpc } from "../shared/venice-rpc.js";

const OBS_TIMEOUT_MS = 60_000;

function now() { return Date.now(); }
function rel(t0: number, t: number | null) { return t === null ? "—" : `+${t - t0}ms`; }

async function observePending(targetHash: Hash, startedAt: number): Promise<number | null> {
  return new Promise((resolve) => {
    const ws = new WebSocket(BASE_SEPOLIA_WS);
    let subId: string | null = null;
    let resolved = false;
    const finish = (t: number | null) => {
      if (resolved) return;
      resolved = true;
      try { ws.close(); } catch {}
      resolve(t);
    };
    const timer = setTimeout(() => finish(null), OBS_TIMEOUT_MS);
    ws.on("open", () => {
      ws.send(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_subscribe", params: ["newPendingTransactions"] }));
    });
    ws.on("message", (raw) => {
      try {
        const msg = JSON.parse(raw.toString());
        if (msg.id === 1 && typeof msg.result === "string") {
          subId = msg.result;
          return;
        }
        if (msg.method === "eth_subscription" && msg.params?.subscription === subId) {
          const hash = msg.params.result as string;
          if (hash && hash.toLowerCase() === targetHash.toLowerCase()) {
            clearTimeout(timer);
            finish(now());
          }
        }
      } catch { /* ignore */ }
    });
    ws.on("error", () => finish(null));
  });
}

async function pollInclusion(hash: Hash, startedAt: number): Promise<number | null> {
  const deadline = startedAt + OBS_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const res = await fetch(BASE_SEPOLIA_HTTP, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getTransactionReceipt", params: [hash] }),
    });
    const json = await res.json() as { result?: { blockNumber?: string } | null };
    if (json.result && json.result.blockNumber) return Date.now();
    await new Promise((r) => setTimeout(r, 1500));
  }
  return null;
}

async function main() {
  const { account, walletClient } = testWallet();
  const rpc = new VeniceRpc({ network: "base-sepolia" });

  console.log(`Wallet: ${account.address}`);

  const tx = await walletClient.prepareTransactionRequest({
    account,
    to: account.address,
    value: parseEther("0"),
  });
  const serialized = await walletClient.signTransaction(tx);
  const txHashLocal = `0x${(await import("viem")).keccak256(serialized).slice(2)}` as Hash;

  console.log(`Pre-computed tx hash: ${txHashLocal}`);
  console.log("Subscribing to pending tx feed on public Base Sepolia node...");

  const t0 = now();
  const pendingPromise = observePending(txHashLocal, t0);
  // Small head start so the WS subscription is live before we submit.
  await new Promise((r) => setTimeout(r, 1500));

  console.log("Submitting via Venice RPC...");
  const submitTs = now();
  const res = await rpc.call<Hash>("eth_sendRawTransaction", [serialized]);
  if (res.error || !res.result) {
    console.error("Venice eth_sendRawTransaction error:", res.error);
    process.exit(1);
  }
  const txHash = res.result;
  console.log(`  hash from Venice: ${txHash}`);
  if (txHash.toLowerCase() !== txHashLocal.toLowerCase()) {
    console.warn("  WARNING: returned hash differs from locally computed hash");
  }

  const inclusionTs = await pollInclusion(txHash, submitTs);
  const pendingTs = await pendingPromise;

  console.log(`\nTimings (relative to submission):`);
  console.log(`  submit         ${rel(submitTs, submitTs)}`);
  console.log(`  seen pending   ${rel(submitTs, pendingTs)}`);
  console.log(`  included       ${rel(submitTs, inclusionTs)}`);

  let verdict: "PUBLIC_MEMPOOL" | "PRIVATE_MEMPOOL" | "UNCERTAIN";
  if (pendingTs !== null && inclusionTs !== null && pendingTs <= inclusionTs) {
    verdict = "PUBLIC_MEMPOOL";
  } else if (pendingTs === null && inclusionTs !== null) {
    verdict = "PRIVATE_MEMPOOL";
  } else {
    verdict = "UNCERTAIN";
  }
  console.log(`\nVERDICT: ${verdict}`);
}

main().catch((e) => { console.error("FAIL:", e); process.exit(1); });
