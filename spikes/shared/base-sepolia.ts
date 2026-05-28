import "dotenv/config";
import { createPublicClient, createWalletClient, http, webSocket, type Address } from "viem";
import { baseSepolia } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";

export const CHAIN = baseSepolia;
export const CHAIN_ID = 84532;

// Canonical Base Sepolia USDC — verified by spike 6 on YYYY-MM-DD.
// Source: Circle docs (https://developers.circle.com/stablecoins/usdc-on-test-networks)
// + Base docs (https://docs.base.org/base-chain/network-information/base-sepolia-testnet)
// + on-chain symbol()/decimals() call (see spike 6 RESULT.md).
export const USDC_BASE_SEPOLIA: Address = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";

export const BASE_SEPOLIA_HTTP =
  process.env.BASE_SEPOLIA_HTTP ?? "https://base-sepolia.publicnode.com";
export const BASE_SEPOLIA_WS =
  process.env.BASE_SEPOLIA_WS ?? "wss://base-sepolia.publicnode.com";

export const VENICE_RPC_BASE =
  process.env.VENICE_RPC_BASE ?? "https://api.venice.ai/api/v1/crypto/rpc";

export function veniceRpcUrl(network = "base-sepolia"): string {
  return `${VENICE_RPC_BASE}/${network}`;
}

export function publicClientHttp(rpc = BASE_SEPOLIA_HTTP) {
  return createPublicClient({ chain: CHAIN, transport: http(rpc) });
}

export function publicClientWs(rpc = BASE_SEPOLIA_WS) {
  return createPublicClient({ chain: CHAIN, transport: webSocket(rpc) });
}

export function veniceClient(apiKey = process.env.VENICE_API_KEY) {
  if (!apiKey) throw new Error("VENICE_API_KEY not set");
  return createPublicClient({
    chain: CHAIN,
    transport: http(veniceRpcUrl(), {
      fetchOptions: { headers: { Authorization: `Bearer ${apiKey}` } },
    }),
  });
}

export function testWallet(pk = process.env.BASE_SEPOLIA_PK) {
  if (!pk || pk === "0x") throw new Error("BASE_SEPOLIA_PK not set");
  const hex = (pk.startsWith("0x") ? pk : "0x" + pk) as `0x${string}`;
  const account = privateKeyToAccount(hex);
  const walletClient = createWalletClient({ account, chain: CHAIN, transport: http(BASE_SEPOLIA_HTTP) });
  return { account, walletClient };
}
