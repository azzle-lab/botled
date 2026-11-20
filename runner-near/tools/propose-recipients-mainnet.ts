// MAINNET: (1) USDC storage for azzle.near paid by the registry, (2) propose Change::Recipients, (3) read back.
//   node --experimental-strip-types tools/propose-recipients-mainnet.ts [--send]
// Apply after the timelock (anyone may call):  ... tools/propose-recipients-mainnet.ts --apply <id>
import { readFileSync } from "fs";
import { NearRpc } from "../near.ts";
const RPC = process.env.NEAR_RPC ?? "https://rpc.mainnet.near.org";
const key = JSON.parse(readFileSync("/home/box/secrets/botled-near-registry.json", "utf8"));
const REG = key.account_id as string;
const USDC = "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1";
const AZZLE = "azzle.near";
const TREASURY = "ea850d6932e9e6cdc1b535e9ebfff8a31e88ef9b1ae97c3cd24767b217dab230";
const near = new NearRpc({ rpc: RPC, accountId: REG, secretKey: key.private_key });
const hashes: string[] = [];
const orig = near.rpcCall.bind(near);
(near as any).rpcCall = async (m: string, p: any) => { const o = await orig(m, p); if (m === "send_tx" && o?.transaction?.hash) hashes.push(o.transaction.hash); return o; };
const out: any = {};
const ai = process.argv.indexOf("--apply");
if (ai > 0) {
  const id = Number(process.argv[ai + 1]);
  await near.call(REG, "apply", { id }, { gasTgas: 30 });
  console.log("applied", id, hashes.at(-1));
  console.log(JSON.stringify((await near.view<any>(REG, "get_settings", {})), ["profit_to", "dev_to", "penalty_to"]));
  process.exit(0);
}
const acct = await near.rpcCall("query", { request_type: "view_account", finality: "final", account_id: AZZLE });
console.log("azzle.near exists, code_hash", acct.code_hash);
const s: any = await near.view(REG, "get_settings", {});
if (s.penalty_to !== TREASURY) throw new Error("penalty_to changed unexpectedly");
console.log("current", s.profit_to, s.dev_to, s.penalty_to, "pending", JSON.stringify(await near.view(REG, "get_pending", {})));
if (!process.argv.includes("--send")) process.exit(0);
const bal = await near.view(USDC, "storage_balance_of", { account_id: AZZLE });
if (!bal) {
  const b: any = await near.view(USDC, "storage_balance_bounds", {});
  await near.call(USDC, "storage_deposit", { account_id: AZZLE, registration_only: true }, { deposit: BigInt(b.min), gasTgas: 30 });
  out.storage_tx = hashes.at(-1);
} else out.storage_tx = "already registered";
console.log("usdc storage azzle.near", out.storage_tx, JSON.stringify(await near.view(USDC, "storage_balance_of", { account_id: AZZLE })));
const pending: any[] = await near.view(REG, "get_pending", {});
const dup = pending.findIndex((p) => p && p.change?.Recipients?.profit_to === AZZLE);
if (dup >= 0) { console.log("proposal already pending id", dup); process.exit(0); }
const id = await near.call<number>(REG, "propose", { change: { Recipients: { profit_to: AZZLE, dev_to: AZZLE, penalty_to: TREASURY } } }, { gasTgas: 30 });
console.log("proposal id", id, "tx", hashes.at(-1));
console.log("pending", JSON.stringify(await near.view(REG, "get_pending", {})));
