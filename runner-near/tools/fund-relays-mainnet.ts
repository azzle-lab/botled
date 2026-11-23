// One-shot: fund the sponsor relays' NEAR implicit accounts from the registry's free balance (plan 2026-11-20).
// Refuses unless registry keeps storage cost + 0.5 NEAR afterwards. Sends each transfer once; prints tx hashes only.
import { readFileSync } from "node:fs";
import { NearRpc } from "../near.ts";
const RPC = "https://rpc.mainnet.near.org";
const reg = JSON.parse(readFileSync("/home/box/secrets/botled-near-registry.json", "utf8"));
const TARGETS = ["2a193115b8be6016e1b4f04286b2776d6a0d2ab69cc86821051a73e7011f5a91", "4a9aec079963e6c20c307e4af90b41bd02b78868a146434d8d8930e2931c4d60"];
const AMOUNT = 3n * 10n ** 23n; // 0.3 NEAR
const view = async (id: string) => {
  const r = await (await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "query", params: { request_type: "view_account", finality: "final", account_id: id } }) })).json();
  return r.result as { amount: string; locked: string; storage_usage: number } | undefined;
};
const a = await view(reg.account_id);
if (!a) throw new Error("registry not found");
const storage = BigInt(a.storage_usage) * 10n ** 19n;
const todo = (await Promise.all(TARGETS.map(view))).filter((x) => !x).length;
const after = BigInt(a.amount) - AMOUNT * BigInt(todo);
if (after < storage + 5n * 10n ** 23n) throw new Error("would breach storage + 0.5 NEAR reserve");
const near = new NearRpc({ rpc: RPC, accountId: reg.account_id, secretKey: reg.private_key });
for (const t of TARGETS) {
  if (await view(t)) { console.log(t.slice(0, 8), "already exists, skipped"); continue; }
  const out: any = await near.send(t, [{ transfer: AMOUNT }]);
  console.log(t.slice(0, 8), "transfer sent", String(JSON.stringify(out ?? null)).slice(0, 80));
}
for (const t of [reg.account_id, ...TARGETS]) { const v = await view(t); console.log(t.slice(0, 8), v ? Number(BigInt(v.amount) / 10n ** 18n) / 1e6 : "missing"); }
