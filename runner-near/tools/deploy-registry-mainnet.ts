// MAINNET: deploys near/target/near/botled_registry/botled_registry.wasm to the Botled registry implicit account and
// calls `new` (phase 1, 2026-11-20). Idempotent: refuses if the account already has code. Key read from
// /home/box/secrets/botled-near-registry.json and never printed. Usage:
//   node --experimental-strip-types tools/deploy-registry-mainnet.ts [--send]
import { readFileSync, writeFileSync } from "fs";
import { createHash } from "crypto";
import { join } from "path";
import { NearRpc } from "../near.ts";
import { MAINNET_ROOT, MAINNET_SIGNER, nearSecpKey } from "../chainsig.ts";

const root = join(import.meta.dirname, "../..");
const RPC = process.env.NEAR_RPC ?? "https://rpc.mainnet.near.org";
const key = JSON.parse(readFileSync("/home/box/secrets/botled-near-registry.json", "utf8"));
const REG = key.account_id as string;
const USDC = "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1"; // Circle native USDC on NEAR
const TREASURY = "ea850d6932e9e6cdc1b535e9ebfff8a31e88ef9b1ae97c3cd24767b217dab230"; // provisional recipient
const RELAY_A = "2a193115b8be6016e1b4f04286b2776d6a0d2ab69cc86821051a73e7011f5a91";
const RELAY_B = "4a9aec079963e6c20c307e4af90b41bd02b78868a146434d8d8930e2931c4d60";
const pins = JSON.parse(readFileSync(join(root, "runner-near/attestation-pins.json"), "utf8"));
const DS = "deepseek-ai/DeepSeek-V4.1-Flash-1017";
const bytes = (h: string) => [...Buffer.from(h.replace(/^0x/, ""), "hex")];

const settings = {
  params: { signup_fee: 20000000, profit_cut: 5000000, dev_cut: 5000000, no_show_penalty: 2000000, min_ticket_budget: 1000000,
    ticket_ttl_secs: 604800, exit_delay_secs: 172800, max_cost_per_run: 200000, max_runs_per_seat: 1 },
  usdc: USDC, profit_to: TREASURY, dev_to: TREASURY, penalty_to: TREASURY,
  lanes: [
    { model: "moonshotai/kimi-k3", input_per_mtok: 3300000, output_per_mtok: 16500000, receipt_kind: "Gateway" },
    { model: DS, input_per_mtok: 300000, output_per_mtok: 1200000, receipt_kind: "ProviderTee" },
  ],
  signers: [
    { scheme: "Ecdsa", kind: "Gateway", key: bytes(pins.gateway.ecdsa), model: null, active: true },
    { scheme: "Ed25519", kind: "Gateway", key: bytes(pins.gateway.ed25519), model: null, active: true },
    { scheme: "Ecdsa", kind: "ProviderTee", key: bytes(pins.models[DS].ecdsa), model: DS, active: true },
    { scheme: "Ed25519", kind: "ProviderTee", key: bytes(pins.models[DS].ed25519), model: DS, active: true },
  ],
  sponsors: [RELAY_A, RELAY_B],
  // Base pool not deployed yet (it is anchored to the factory, deployed together with it). Set via timelocked Change::Pool.
  pool: { chain_id: 8453, pool: new Array(20).fill(0) },
  reward_bridge: null,
};
const mpcRoot = Buffer.from(nearSecpKey(MAINNET_ROOT).slice(1)).toString("hex");
const initArgs = { owner: REG, timelock_secs: 86400, mpc: MAINNET_SIGNER, settings, mpc_root: mpcRoot };
writeFileSync(join(root, "deploy/near-registry-init-args.json"), JSON.stringify(initArgs, null, 1));

const wasm = readFileSync(join(root, "near/target/near/botled_registry/botled_registry.wasm"));
const sum = createHash("sha256").update(wasm).digest("hex");
const pinned = readFileSync(join(root, "near/wasm.sha256"), "utf8").split(/\s+/)[0];
if (sum !== pinned) throw new Error(`wasm sha256 ${sum} != pinned ${pinned}`);

const near = new NearRpc({ rpc: RPC, accountId: REG, secretKey: key.private_key });
const hashes: string[] = [];
const orig = near.rpcCall.bind(near);
(near as any).rpcCall = async (m: string, p: any) => { const o = await orig(m, p); if (m === "send_tx" && o?.transaction?.hash) hashes.push(o.transaction.hash); return o; };

const acct = await near.rpcCall("query", { request_type: "view_account", finality: "final", account_id: REG });
console.log("account", REG, "balance", acct.amount, "code_hash", acct.code_hash, "wasm sha256", sum, wasm.length, "bytes");
if (!process.argv.includes("--send")) { console.log("dry: init args -> deploy/near-registry-init-args.json"); process.exit(0); }
const out: any = { registry: REG, wasm_sha256: sum };
if (acct.code_hash === "11111111111111111111111111111111") {
  await near.deploy(new Uint8Array(wasm), "new", initArgs, 100);
  out.deploy_tx = hashes.at(-1);
  console.log("deployed+init tx", out.deploy_tx);
} else console.log("code already deployed; skipping deploy");
// USDC storage for the registry (receives ft_transfer_call) and the provisional treasury (receives collect)
for (const acc of [REG, TREASURY]) {
  const bal: any = await near.view(USDC, "storage_balance_of", { account_id: acc });
  if (bal) { console.log("usdc storage ok", acc); continue; }
  const b: any = await near.view(USDC, "storage_balance_bounds", {});
  await near.call(USDC, "storage_deposit", { account_id: acc, registration_only: true }, { deposit: BigInt(b.min), gasTgas: 30 });
  out[`usdc_storage_${acc === REG ? "registry" : "treasury"}_tx`] = hashes.at(-1);
  console.log("usdc storage_deposit", acc, hashes.at(-1));
}
writeFileSync(join(root, "deploy/near-registry-txs.json"), JSON.stringify(out, null, 1));
