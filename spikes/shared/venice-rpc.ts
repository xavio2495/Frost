import "dotenv/config";
import { veniceRpcUrl } from "./base-sepolia.js";

export type RpcRequest = { jsonrpc: "2.0"; id: number | string; method: string; params: unknown[] };
export type RpcResponse<T = unknown> = {
  jsonrpc: "2.0";
  id: number | string;
  result?: T;
  error?: { code: number; message: string };
};

export class VeniceRpc {
  private url: string;
  private headers: Record<string, string>;

  constructor(opts?: { network?: string; apiKey?: string }) {
    const apiKey = opts?.apiKey ?? process.env.VENICE_API_KEY;
    if (!apiKey) throw new Error("VENICE_API_KEY not set");
    this.url = veniceRpcUrl(opts?.network ?? "base-sepolia");
    this.headers = {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    };
  }

  async call<T>(method: string, params: unknown[] = []): Promise<RpcResponse<T>> {
    const body: RpcRequest = { jsonrpc: "2.0", id: Date.now(), method, params };
    const res = await fetch(this.url, {
      method: "POST",
      headers: this.headers,
      body: JSON.stringify(body),
    });
    return this.parse<T>(res);
  }

  async batch<T = unknown>(items: { method: string; params: unknown[] }[]): Promise<RpcResponse<T>[]> {
    const body: RpcRequest[] = items.map((it, i) => ({
      jsonrpc: "2.0",
      id: i,
      method: it.method,
      params: it.params,
    }));
    const res = await fetch(this.url, {
      method: "POST",
      headers: this.headers,
      body: JSON.stringify(body),
    });
    // Venice returns non-200 (e.g., 429) with a single error envelope even for batched
    // requests. Surface that as one error per requested item so callers can classify.
    const text = await res.text();
    if (res.status === 429 || !text.trim().startsWith("[")) {
      const err = { code: res.status, message: this.extractError(text) || text };
      return items.map((_, i) => ({ jsonrpc: "2.0", id: i, error: err })) as RpcResponse<T>[];
    }
    return JSON.parse(text) as RpcResponse<T>[];
  }

  private async parse<T>(res: Response): Promise<RpcResponse<T>> {
    const text = await res.text();
    if (res.status === 429) {
      return { jsonrpc: "2.0", id: 0, error: { code: 429, message: this.extractError(text) || "rate limit" } };
    }
    try { return JSON.parse(text) as RpcResponse<T>; }
    catch { return { jsonrpc: "2.0", id: 0, error: { code: res.status, message: text } }; }
  }

  private extractError(text: string): string | null {
    try { const j = JSON.parse(text); return j.error?.message ?? j.error ?? null; } catch { return null; }
  }
}
