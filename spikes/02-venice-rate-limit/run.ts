import { USDC_BASE_SEPOLIA } from "../shared/base-sepolia.js";
import { VeniceRpc } from "../shared/venice-rpc.js";
import { encodeFunctionData } from "viem";

const ABI = [
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
] as const;

const CALL_PARAMS = [{ to: USDC_BASE_SEPOLIA, data: encodeFunctionData({ abi: ABI, functionName: "decimals" }) }, "latest"];

type Result = { ok: number; rateLimited: number; otherErr: number; latencies: number[] };

async function pricer(rpc: VeniceRpc, durationMs: number, callsPerCycle: number, batched: boolean): Promise<Result> {
  const r: Result = { ok: 0, rateLimited: 0, otherErr: 0, latencies: [] };
  const deadline = Date.now() + durationMs;
  while (Date.now() < deadline) {
    if (batched) {
      const items = Array.from({ length: callsPerCycle }, () => ({ method: "eth_call", params: CALL_PARAMS }));
      const t0 = Date.now();
      try {
        const res = await rpc.batch(items);
        const dt = Date.now() - t0;
        let allOk = true;
        for (const e of res) {
          if (e.error) {
            allOk = false;
            if (e.error.message?.toLowerCase().includes("rate")) r.rateLimited++;
            else r.otherErr++;
          }
        }
        if (allOk) { r.ok += callsPerCycle; r.latencies.push(dt); }
      } catch { r.otherErr++; }
    } else {
      for (let i = 0; i < callsPerCycle; i++) {
        const t0 = Date.now();
        try {
          const res = await rpc.call("eth_call", CALL_PARAMS);
          const dt = Date.now() - t0;
          if (res.error) {
            if (res.error.message?.toLowerCase().includes("rate") || (res.error as any).code === 429) r.rateLimited++;
            else r.otherErr++;
          } else { r.ok++; r.latencies.push(dt); }
        } catch (e) {
          const msg = String(e);
          if (msg.includes("429")) r.rateLimited++; else r.otherErr++;
        }
      }
    }
    // Cycle pause ~ pricer "tick" — sub-agents won't hammer continuously.
    await new Promise((r) => setTimeout(r, 250));
  }
  return r;
}

function pct(arr: number[], p: number): number {
  if (arr.length === 0) return 0;
  const s = [...arr].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor(s.length * p))];
}

async function pass(label: string, durationMs: number, batched: boolean) {
  const rpc = new VeniceRpc({ network: "base-sepolia" });
  const workers = [pricer(rpc, durationMs, 10, batched), pricer(rpc, durationMs, 10, batched), pricer(rpc, durationMs, 10, batched)];
  const results = await Promise.all(workers);
  const total: Result = { ok: 0, rateLimited: 0, otherErr: 0, latencies: [] };
  for (const r of results) { total.ok += r.ok; total.rateLimited += r.rateLimited; total.otherErr += r.otherErr; total.latencies.push(...r.latencies); }
  const reqPerMin = Math.round((total.ok / (durationMs / 60_000)));
  console.log(`\n[${label}] window=${durationMs/1000}s batched=${batched}`);
  console.log(`  ok:          ${total.ok}  (~${reqPerMin}/min)`);
  console.log(`  429s:        ${total.rateLimited}`);
  console.log(`  other err:   ${total.otherErr}`);
  console.log(`  latency p50: ${pct(total.latencies, 0.5)}ms`);
  console.log(`  latency p95: ${pct(total.latencies, 0.95)}ms`);
  return total;
}

async function main() {
  // Budget-aware: default 15s window per pass (~2-3k calls total) to fit a $1
  // Venice credit budget with margin. Override with SPIKE2_WINDOW_MS env.
  const win = Number(process.env.SPIKE2_WINDOW_MS ?? 15_000);
  console.log(`Spike 2: Venice RPC rate-limit under demo load (3 pricers × 10 calls/cycle, ${win/1000}s/pass).`);
  await pass("pass 1 — per-request", win, false);
  await pass("pass 2 — batched",     win, true);
}

main().catch((e) => { console.error("FAIL:", e); process.exit(1); });
