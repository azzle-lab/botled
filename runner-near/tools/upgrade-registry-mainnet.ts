// MAINNET: plain DeployContract (no init) of the pinned registry wasm to the registry account, then read back.
//   node --experimental-strip-types tools/upgrade-registry-mainnet.ts [--send]
import { readFileSync, writeFileSync } from "fs";
import { createHash } from "crypto";
import { join } from "path";
import { NearRpc, base58Encode } from "../near.ts";
const root = join(import.meta.dirname, "../..");
const key = JSON.parse(readFileSync("/home/box/secrets/botled-near-registry.json", "utf8"));
const REG = key.account_id as string;
const near = new NearRpc({ rpc: process.env.NEAR_RPC ?? "https://rpc.mainnet.near.org", accountId: REG, secretKey: key.private_key });
const hashes: string[] = [];
const orig = near.rpcCall.bind(near);
(near as any).rpcCall = async (m: string, p: any) => { const o = await orig(m, p); if (m === "send_tx" && o?.transaction?.hash) hashes.push(o.transaction.hash); return o; };
const wasm = readFileSync(join(root, "near/target/near/botled_registry/botled_registry.wasm"));
const sha = createHash("sha256").update(wasm).digest();
const pinned = readFileSync(join(root, "near/wasm.sha256"), "utf8").split(/\s+/)[0];
if (sha.toString("hex") !== pinned) throw new Error("wasm != pinned sha256");
const codeHash = base58Encode(new Uint8Array(sha));
const state = async () => ({
  acct: await near.rpcCall("query", { request_type: "view_account", finality: "final", account_id: REG }),
  pending: JSON.stringify(await near.view(REG, "get_pending", {})),
  settings: JSON.stringify(await near.view(REG, "get_settings", {})),
  owner: await near.view(REG, "get_owner", {}),
  runs: await near.view(REG, "run_count", {}),
});
const before = await state();
console.log("before code_hash", before.acct.code_hash, "target", codeHash, "pending", before.pending);
if (!process.argv.includes("--send")) process.exit(0);
const out: any = {};
if (before.acct.code_hash !== codeHash) {
  await near.send(REG, [{ code: new Uint8Array(wasm) } as any]);
  out.upgrade_tx = hashes.at(-1);
  console.log("upgrade tx", out.upgrade_tx);
  await new Promise((r) => setTimeout(r, 4000));
}
const after = await state();
const checks = {
  code_hash: after.acct.code_hash === codeHash,
  pending_unchanged: after.pending === before.pending,
  settings_unchanged: after.settings === before.settings,
  owner_unchanged: after.owner === before.owner,
  azzle_base_matches_v1_signer: (await near.view<string>(REG, "chain_signature_base", { account: "azzle.near" })) === "0xae52c39e872fc4c647f65fe724cf4391bad248fe",
};
// dry check: the base signup now requires for azzle.near vs. a wrong one (signup panics unless base == this value)
const wrong = "0x3D5eb1F648F495fAEFaeBa0dE74A5c52b6602F5D".toLowerCase();
(checks as any).wrong_base_rejected = (await near.view<string>(REG, "chain_signature_base", { account: "azzle.near" })) !== wrong;
console.log("after code_hash", after.acct.code_hash, "balance", after.acct.amount, "storage", after.acct.storage_usage);
console.log("pending after", after.pending);
console.log("checks", JSON.stringify(checks));
out.code_hash = after.acct.code_hash; out.sha256 = pinned; out.checks = checks;
writeFileSync(join(root, "deploy/near-registry-upgrade-1.json"), JSON.stringify(out, null, 1));
if (Object.values(checks).some((v) => !v)) process.exit(1);
