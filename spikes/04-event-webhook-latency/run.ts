// Spike 4 — WS fallback path.
// Measures node->client log delivery latency over a public Base Sepolia WS.
// No Tenderly / webhook receiver required.
import "dotenv/config";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import { encodeFunctionData, toEventSelector, type Address, type Hex } from "viem";
import { BASE_SEPOLIA_HTTP, BASE_SEPOLIA_WS, testWallet, publicClientHttp } from "../shared/base-sepolia.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const artifact = JSON.parse(fs.readFileSync(path.join(__dirname, "Emitter.json"), "utf8"));
const cachePath = path.join(__dirname, ".deployed");

const SAMPLES = 5;
const INTERVAL_MS = 10_000;
const PING_SELECTOR = "0x5c36b186" as Hex; // keccak256("ping()")[0..4]
const PING_TOPIC0 = toEventSelector("Ping(uint256,uint256)");

async function deployIfNeeded(): Promise<Address> {
  if (process.env.EMITTER_ADDRESS) return process.env.EMITTER_ADDRESS as Address;
  if (fs.existsSync(cachePath)) {
    const cached = fs.readFileSync(cachePath, "utf8").trim() as Address;
    console.log(`Reusing cached Emitter: ${cached}`);
    return cached;
  }
  console.log("Deploying Emitter...");
  const { walletClient, account } = testWallet();
  const hash = await walletClient.deployContract({ account, abi: artifact.abi, bytecode: artifact.bytecode });
  const pc = publicClientHttp();
  const r = await pc.waitForTransactionReceipt({ hash });
  if (!r.contractAddress) throw new Error("no contractAddress in receipt");
  console.log(`Deployed at ${r.contractAddress} (block ${r.blockNumber})`);
  fs.writeFileSync(cachePath, r.contractAddress);
  return r.contractAddress;
}

type Sample = { idx: number; hash: Hex; sendTs: number; recvTs?: number; blockTs?: number; blockNumber?: bigint };

async function main() {
  const emitter = await deployIfNeeded();
  console.log(`Emitter:        ${emitter}`);
  console.log(`Ping topic0:    ${PING_TOPIC0}`);
  console.log(`WS endpoint:    ${BASE_SEPOLIA_WS}`);

  const samples: Sample[] = [];
  const pendingByHash = new Map<Hex, Sample>();

  const ws = new WebSocket(BASE_SEPOLIA_WS);
  await new Promise<void>((res, rej) => { ws.once("open", () => res()); ws.once("error", rej); });
  console.log("WS open. Subscribing to Ping logs...");

  let subId: string | null = null;
  let rpcId = 1;
  const subResolvers = new Map<number, (v: any) => void>();
  ws.on("message", (raw) => {
    const msg = JSON.parse(raw.toString());
    if (msg.id && subResolvers.has(msg.id)) { subResolvers.get(msg.id)!(msg); subResolvers.delete(msg.id); return; }
    if (msg.method === "eth_subscription" && msg.params?.subscription === subId) {
      const log = msg.params.result;
      const recvTs = Date.now();
      const txHash = log.transactionHash as Hex;
      const s = pendingByHash.get(txHash);
      if (s) { s.recvTs = recvTs; console.log(`  recv: ${txHash} @ ${recvTs}`); }
    }
  });

  const subscribe = () => new Promise<string>((resolve, reject) => {
    const id = rpcId++;
    subResolvers.set(id, (r) => { r.error ? reject(new Error(r.error.message)) : resolve(r.result); });
    ws.send(JSON.stringify({ jsonrpc: "2.0", id, method: "eth_subscribe", params: ["logs", { address: emitter, topics: [PING_TOPIC0] }] }));
  });
  subId = await subscribe();
  console.log(`Subscription id: ${subId}`);

  const { walletClient, account } = testWallet();
  const pc = publicClientHttp();
  const data = encodeFunctionData({ abi: artifact.abi, functionName: "ping" });

  console.log(`\nFiring ${SAMPLES} pings every ${INTERVAL_MS}ms...`);
  for (let i = 0; i < SAMPLES; i++) {
    const sendTs = Date.now();
    const hash = await walletClient.sendTransaction({ account, to: emitter, data, chain: walletClient.chain });
    const s: Sample = { idx: i + 1, hash, sendTs };
    samples.push(s);
    pendingByHash.set(hash, s);
    console.log(`  fire ${i + 1}: tx=${hash} sendTs=${sendTs}`);
    if (i < SAMPLES - 1) await new Promise((r) => setTimeout(r, INTERVAL_MS));
  }

  // Wait up to 30 s for last log + capture blockTs from receipts.
  console.log("\nWaiting for inclusion + log delivery...");
  await new Promise((r) => setTimeout(r, 15_000));
  for (const s of samples) {
    try {
      const r = await pc.getTransactionReceipt({ hash: s.hash });
      s.blockNumber = r.blockNumber;
      const blk = await pc.getBlock({ blockNumber: r.blockNumber });
      s.blockTs = Number(blk.timestamp) * 1000;
    } catch (e) { console.log(`  receipt fetch failed for ${s.hash}: ${e instanceof Error ? e.message : e}`); }
  }

  ws.close();

  console.log("\nResults:");
  const rows: string[] = [];
  rows.push("| # | tx | block | sendTs | blockTs | recvTs | recv-block (ms) | recv-send (ms) |");
  rows.push("|---|---|---|---|---|---|---|---|");
  const recvBlock: number[] = [];
  const recvSend: number[] = [];
  for (const s of samples) {
    const rb = s.recvTs && s.blockTs ? s.recvTs - s.blockTs : null;
    const rs = s.recvTs ? s.recvTs - s.sendTs : null;
    if (rb !== null) recvBlock.push(rb);
    if (rs !== null) recvSend.push(rs);
    rows.push(`| ${s.idx} | \`${s.hash.slice(0, 10)}…\` | ${s.blockNumber ?? "?"} | ${s.sendTs} | ${s.blockTs ?? "?"} | ${s.recvTs ?? "?"} | ${rb ?? "?"} | ${rs ?? "?"} |`);
  }
  for (const r of rows) console.log(r);
  const median = (a: number[]) => a.length ? a.slice().sort((x, y) => x - y)[Math.floor(a.length / 2)] : NaN;
  console.log(`\nMedian recv-block latency: ${median(recvBlock)} ms (${recvBlock.length}/${SAMPLES} samples)`);
  console.log(`Median recv-send latency:  ${median(recvSend)} ms (${recvSend.length}/${SAMPLES} samples)`);

  const writeup = {
    emitter, ws: BASE_SEPOLIA_WS, samples, medianRecvBlockMs: median(recvBlock), medianRecvSendMs: median(recvSend),
  };
  fs.writeFileSync(path.join(__dirname, "raw-results.json"), JSON.stringify(writeup, (_k, v) => typeof v === "bigint" ? v.toString() : v, 2));

  const pass = recvSend.length === SAMPLES && median(recvSend) <= 10_000;
  console.log(`\n${pass ? "PASS" : "FAIL"} (threshold: median send->recv <= 10s)`);
  process.exit(pass ? 0 : 1);
}

main().catch((e) => { console.error("FAIL:", e); process.exit(1); });
