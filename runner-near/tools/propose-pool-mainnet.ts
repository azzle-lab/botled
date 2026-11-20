// MAINNET: propose Change::Pool {chain 8453, BotledRunnerPoolNear} from the registry owner; --apply <id> after the timelock.
import { readFileSync } from "fs";
import { NearRpc } from "../near.ts";
const key = JSON.parse(readFileSync("/home/box/secrets/botled-near-registry.json", "utf8"));
const REG = key.account_id as string;
const POOL = "0x4fE84CAe74039df848BEe0c7E7Dd9A4eAfaFf7EF";
const near = new NearRpc({ rpc: process.env.NEAR_RPC ?? "https://rpc.mainnet.near.org", accountId: REG, secretKey: key.private_key });
const hashes: string[] = [];
const orig = near.rpcCall.bind(near);
(near as any).rpcCall = async (m: string, p: any) => { const o = await orig(m, p); if (m === "send_tx" && o?.transaction?.hash) hashes.push(o.transaction.hash); return o; };
const poolBytes = [...Buffer.from(POOL.slice(2), "hex")];
const show = async () => { const s: any = await near.view(REG, "get_settings", {}); console.log("pool domain", s.pool.chain_id, "0x" + Buffer.from(s.pool.pool).toString("hex")); };
const ai = process.argv.indexOf("--apply");
if (ai > 0) { const id = Number(process.argv[ai + 1]); await near.call(REG, "apply", { id }, { gasTgas: 30 }); console.log("applied", id, hashes.at(-1)); await show(); process.exit(0); }
const pending: any[] = await near.view(REG, "get_pending", {});
const dup = pending.findIndex((p) => p?.change?.Pool && Buffer.from(p.change.Pool.pool).toString("hex") === POOL.slice(2).toLowerCase());
if (dup >= 0) { console.log("already pending id", dup); process.exit(0); }
if (!process.argv.includes("--send")) { await show(); console.log("pending", JSON.stringify(pending)); process.exit(0); }
const id = await near.call<number>(REG, "propose", { change: { Pool: { chain_id: 8453, pool: poolBytes } } }, { gasTgas: 30 });
console.log("proposal id", id, "tx", hashes.at(-1));
console.log("pending", JSON.stringify(await near.view(REG, "get_pending", {})));
