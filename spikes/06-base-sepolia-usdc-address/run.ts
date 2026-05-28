import { encodeFunctionData, decodeFunctionResult, type Address } from "viem";
import { USDC_BASE_SEPOLIA, BASE_SEPOLIA_HTTP } from "../shared/base-sepolia.js";
import { VeniceRpc } from "../shared/venice-rpc.js";

const ERC20_ABI = [
  { type: "function", name: "name", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
] as const;

type CallOne = (fn: "name" | "symbol" | "decimals") => Promise<string | number>;

function makePublicCaller(rpc: string, to: Address): CallOne {
  return async (fn) => {
    const data = encodeFunctionData({ abi: ERC20_ABI, functionName: fn });
    const res = await fetch(rpc, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to, data }, "latest"] }),
    });
    const json = (await res.json()) as { result?: `0x${string}`; error?: { message: string } };
    if (json.error) throw new Error(`${fn}: ${json.error.message}`);
    if (!json.result) throw new Error(`${fn}: no result`);
    return decodeFunctionResult({ abi: ERC20_ABI, functionName: fn, data: json.result }) as string | number;
  };
}

function makeVeniceCaller(to: Address): CallOne {
  const rpc = new VeniceRpc({ network: "base-sepolia" });
  return async (fn) => {
    const data = encodeFunctionData({ abi: ERC20_ABI, functionName: fn });
    const res = await rpc.call<`0x${string}`>("eth_call", [{ to, data }, "latest"]);
    if (res.error) throw new Error(`${fn}: ${res.error.message}`);
    if (!res.result) throw new Error(`${fn}: no result`);
    return decodeFunctionResult({ abi: ERC20_ABI, functionName: fn, data: res.result }) as string | number;
  };
}

async function probe(label: string, caller: CallOne) {
  console.log(`\n[${label}]`);
  const [name, symbol, decimals] = await Promise.all([caller("name"), caller("symbol"), caller("decimals")]);
  console.log(`  name():     ${name}`);
  console.log(`  symbol():   ${symbol}`);
  console.log(`  decimals(): ${decimals}`);
  return symbol === "USDC" && Number(decimals) === 6;
}

async function main() {
  const addr: Address = USDC_BASE_SEPOLIA;
  console.log(`Probing USDC at ${addr} on Base Sepolia.`);

  const publicOk = await probe(`public RPC: ${BASE_SEPOLIA_HTTP}`, makePublicCaller(BASE_SEPOLIA_HTTP, addr));

  let veniceOk: boolean | "skipped" = "skipped";
  if (process.env.VENICE_API_KEY) {
    try {
      veniceOk = await probe("Venice RPC", makeVeniceCaller(addr));
    } catch (e) {
      console.log(`  Venice probe FAILED: ${e instanceof Error ? e.message : String(e)}`);
      veniceOk = false;
    }
  } else {
    console.log("\n[Venice RPC] skipped — VENICE_API_KEY not set");
  }

  const overall = publicOk && veniceOk !== false;
  console.log("");
  console.log(overall ? "PASS" : "FAIL");
  if (!overall) process.exit(1);
}

main().catch((e) => {
  console.error("FAIL:", e);
  process.exit(1);
});
