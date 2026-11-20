/**
 * Runner CLI: register | status | exit
 * register approves the pool's runnerReserve and calls registerRunner.
 * exit schedules the cooldown, or withdraws the full bond once it has elapsed.
 * Writes need BOTLED_SEND=1 and either a local RPC or MAINNET_OK=1.
 */
import { type Address } from "viem";
import {
  ERC20, POOL, clients, deployments, env, loadAccount, makeLogger, sender,
} from "./botled-node-lib.ts";
import { discoverDraws } from "./botled-node.ts";

const { pub, transport } = clients();
const log = makeLogger();
const send = sender(pub, transport, log);
const dep = deployments();

function pool(): Address {
  return (env("POOL") as Address | undefined) ?? dep.v5.pool ?? dep.v4.pool;
}

function account() {
  const a = loadAccount("RUNNER_KEY_FILE", "RUNNER_PK");
  if (!a) throw new Error("set RUNNER_KEY_FILE or RUNNER_PK");
  return a;
}

function assertSend() {
  if (env("BOTLED_SEND") !== "1") throw new Error("BOTLED_SEND is not 1");
  const host = new URL(env("RPC_URLS", env("RPC_URL", "https://mainnet.base.org"))!.split(",")[0].trim()).hostname;
  if (host !== "127.0.0.1" && host !== "localhost" && env("MAINNET_OK") !== "1") {
    throw new Error("refusing mainnet sends without MAINNET_OK=1");
  }
}

export async function register() {
  assertSend();
  const me = account();
  const p = pool();
  const token = await pub.readContract({ address: p, abi: POOL, functionName: "bondToken" });
  const reserve = await pub.readContract({ address: p, abi: POOL, functionName: "runnerReserve" });
  const row = await pub.readContract({ address: p, abi: POOL, functionName: "runners", args: [me.address] });
  if (row[0]) throw new Error("already listed");
  const bal = await pub.readContract({ address: token, abi: ERC20, functionName: "balanceOf", args: [me.address] });
  if (bal < reserve) throw new Error("AZL below runner reserve");
  const allowance = await pub.readContract({ address: token, abi: ERC20, functionName: "allowance", args: [me.address, p] });
  if (allowance < reserve) await send(me, token, ERC20, "approve", [p, reserve]);
  await send(me, p, POOL, "registerRunner", [reserve]);
  log("registered", { runner: me.address, pool: p, amount: reserve });
}

export async function status() {
  const me = account();
  const p = pool();
  const [row, eligible, eth, token] = await Promise.all([
    pub.readContract({ address: p, abi: POOL, functionName: "runners", args: [me.address] }),
    pub.readContract({ address: p, abi: POOL, functionName: "runnerEligible", args: [me.address] }),
    pub.getBalance({ address: me.address }),
    pub.readContract({ address: p, abi: POOL, functionName: "bondToken" }),
  ]);
  const azl = await pub.readContract({ address: token, abi: ERC20, functionName: "balanceOf", args: [me.address] });
  const draws = await discoverDraws(me.address).catch((err) => {
    log("scan.error", { err: (err as Error).message.slice(0, 300) });
    return [];
  });
  const out = {
    runner: me.address, pool: p, listed: row[0], activeCases: row[1], exitReadyAt: row[2], bond: row[3],
    eligible, eth, azl, openDraws: draws.map((d) => ({ version: d.version, cage: d.cage, taskId: d.taskId, round: d.round })),
  };
  console.log(JSON.stringify(out, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2));
  return out;
}

export async function exit() {
  assertSend();
  const me = account();
  const p = pool();
  const row = await pub.readContract({ address: p, abi: POOL, functionName: "runners", args: [me.address] });
  const now = (await pub.getBlock()).timestamp;
  if (!row[0]) throw new Error("not listed");
  if (row[2] === 0n || now < row[2]) {
    await send(me, p, POOL, "scheduleRunnerExit", []);
    log("exit.scheduled", { runner: me.address, pool: p });
    return;
  }
  await send(me, p, POOL, "withdrawRunner", [row[3]]);
  log("exit.withdrawn", { runner: me.address, pool: p, amount: row[3] });
}

const cmd = process.argv[2];
const invoked = process.argv[1]?.replace(/\\/g, "/").endsWith("runner-cli.ts");
if (invoked) {
  const run = cmd === "register" ? register : cmd === "status" ? status : cmd === "exit" ? exit : null;
  if (!run) { console.error("usage: runner-cli.ts register|status|exit"); process.exit(1); }
  run().catch((err) => { console.error(String(err).slice(0, 500)); process.exit(1); });
}
