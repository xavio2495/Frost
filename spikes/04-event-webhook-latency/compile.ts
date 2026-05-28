// Compile Emitter.sol with solc, write artifact JSON next to it.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import solc from "solc";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const source = fs.readFileSync(path.join(__dirname, "Emitter.sol"), "utf8");

const input = {
  language: "Solidity",
  sources: { "Emitter.sol": { content: source } },
  settings: { outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } } },
};

const output = JSON.parse((solc as any).compile(JSON.stringify(input)));
if (output.errors?.some((e: any) => e.severity === "error")) {
  console.error(output.errors);
  process.exit(1);
}
const c = output.contracts["Emitter.sol"].Emitter;
const artifact = { abi: c.abi, bytecode: "0x" + c.evm.bytecode.object };
fs.writeFileSync(path.join(__dirname, "Emitter.json"), JSON.stringify(artifact, null, 2));
console.log("Wrote Emitter.json (bytecode " + (c.evm.bytecode.object.length / 2) + " bytes)");
