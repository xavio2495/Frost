<script lang="ts">
  import { invoke } from "@tauri-apps/api/core";

  type Operation = "echo" | "login" | "grant_permissions" | "revoke" | "commit";

  let operation = $state<Operation>("echo");
  let paramsText = $state("{}");
  let timeoutSecs = $state(120);

  let pending = $state(false);
  let resultText = $state("");
  let errorText = $state("");

  async function run() {
    pending = true;
    resultText = "";
    errorText = "";
    try {
      let params: unknown = {};
      try { params = JSON.parse(paramsText); } catch (e) {
        errorText = "params is not valid JSON: " + String(e);
        pending = false;
        return;
      }
      const res = await invoke("wallet_bridge_perform", {
        args: { operation, params, timeout_secs: timeoutSecs },
      });
      resultText = JSON.stringify(res, null, 2);
    } catch (e) {
      errorText = typeof e === "string" ? e : JSON.stringify(e, null, 2);
    } finally {
      pending = false;
    }
  }
</script>

<main class="container">
  <nav><a href="/">← Home</a></nav>
  <h1>Frost wallet bridge — spike harness</h1>
  <p>Day-1 spikes 7, 8, 10. Pick an operation and click run; the system browser will open to the hosted bridge page; once the callback POSTs back, the result shows below.</p>

  <form onsubmit={(e) => { e.preventDefault(); run(); }}>
    <label>
      Operation:
      <select bind:value={operation}>
        <option value="echo">echo (spike 7)</option>
        <option value="login">login (spike 9 manual)</option>
        <option value="grant_permissions">grant_permissions (spike 8)</option>
        <option value="revoke">revoke (stub — Day 6)</option>
        <option value="commit">commit (stub — Day 6)</option>
      </select>
    </label>

    <label>
      Params (JSON):
      <textarea bind:value={paramsText} rows="4"></textarea>
    </label>

    <label>
      Timeout (s):
      <input type="number" bind:value={timeoutSecs} min="10" max="600" />
    </label>

    <button type="submit" disabled={pending}>{pending ? "Waiting for browser…" : "Run"}</button>
  </form>

  {#if resultText}
    <h2>Result</h2>
    <pre>{resultText}</pre>
  {/if}
  {#if errorText}
    <h2>Error</h2>
    <pre class="err">{errorText}</pre>
  {/if}
</main>

<style>
  .container { padding: 2rem; font-family: Inter, system-ui, sans-serif; max-width: 720px; margin: 0 auto; }
  nav { margin-bottom: 1rem; }
  nav a { color: #646cff; text-decoration: none; }
  nav a:hover { color: #535bf2; }
  label { display: block; margin: 0.75rem 0; }
  textarea, input, select { width: 100%; padding: 0.4rem; font-family: monospace; }
  pre { background: #111; color: #eee; padding: 0.75rem; border-radius: 6px; overflow: auto; }
  pre.err { background: #4a1010; color: #ffd7d7; }
  button { padding: 0.5rem 1rem; }
</style>
