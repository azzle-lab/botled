/**
 * One setup command: node setup.ts runner | node setup.ts cage
 * Checks balances, checks the Surplus key, registers or seats, starts the node, then reads the heartbeat.
 * Sends only when BOTLED_SEND=1 and the RPC is local, unless MAINNET_OK=1.
 */
import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { type Address } from "viem";
import {
  CAGE_V5, ERC20, HERE, PANEL_OWNER, POOL, clients, deployments, env, loadAccount, makeLogger, surplusBalance, surplusKey,
} from "./botled-node-lib.ts";
import { register, status } from "./runner-cli.ts";
import { create, fund, join } from "./cage-cli.ts";

const log = makeLogger();
const { pub } = clients();
const dep = deployments();
const STATE = env("STATE_DIR", join(HERE, "state"))!;

function assertHost() {
  const host = new URL(env("RPC_URLS", env("RPC_URL", "https://mainnet.base.org"))!.split(",")[0].trim()).hostname;
  if (host !== "127.0.0.1" && host !== "localhost" && env("MAINNET_OK") !== "1") {
    throw new Error("refusing mainnet setup without MAINNET_OK=1");
  }
}

async function checkSurplus() {
  if (env("MOCK_VOTE")) return { ok: true, status: 0, creditUsd: 0 };
  const key = surplusKey();
  if (!key) throw new Error("set SURPLUS_API_KEY or SURPLUS_KEY_FILE");
  const bal = await surplusBalance(key);
  if (!bal.ok) throw new Error(`surplus key rejected (${bal.status})`);
  log("surplus", { creditUsd: bal.creditUsd });
  return bal;
}

async function runnerSetup() {
  assertHost();
  process.env.BOTLED_SEND = "1";
  const me = loadAccount("RUNNER_KEY_FILE", "RUNNER_PK");
  if (!me) throw new Error("set RUNNER_KEY_FILE or RUNNER_PK");
  const pool = (env("POOL") as Address | undefined) ?? dep.v5.pool ?? dep.v4.pool;
  const [eth, token, reserve] = await Promise.all([
    pub.getBalance({ address: me.address }),
    pub.readContract({ address: pool, abi: POOL, functionName: "bondToken" }),
    pub.readContract({ address: pool, abi: POOL, functionName: "runnerReserve" }),
  ]);
  const azl = await pub.readContract({ address: token, abi: ERC20, functionName: "balanceOf", args: [me.address] });
  if (eth < 200_000_000_000_000n) throw new Error("need at least 0.0002 ETH for gas");
  if (azl < reserve) throw new Error("AZL below one runner reserve");
  await checkSurplus();
  const row = await pub.readContract({ address: pool, abi: POOL, functionName: "runners", args: [me.address] });
  if (!row[0]) await register();
  if (env("START") === "0") { await status(); return; }
  const child = spawn(process.execPath, ["--experimental-strip-types", join(HERE, "botled-node.ts")], {
    cwd: HERE, detached: true, stdio: "ignore", env: { ...process.env, BOTLED_SEND: "1" },
  });
  child.unref();
  const beat = join(STATE, "heartbeat");
  const start = Date.now();
  while (Date.now() - start < 60_000) {
    if (existsSync(beat) && Date.now() - new Date(readFileSync(beat, "utf8")).getTime() < 120_000) {
      log("healthy", { pid: child.pid, runner: me.address });
      return;
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error("heartbeat missing");
}

async function cageSetup() {
  assertHost();
  process.env.BOTLED_SEND = "1";
  const me = loadAccount("CAGE_KEY_FILE", "CAGE_PK");
  if (!me) throw new Error("set CAGE_KEY_FILE or CAGE_PK");
  if (!dep.v5.factory) throw new Error("v5 factory is not deployed");
  const pfand = await pub.readContract({ address: dep.panelOwner, abi: PANEL_OWNER, functionName: "pfand" });
  const eth = await pub.getBalance({ address: me.address });
  const azl = await pub.readContract({ address: dep.azl, abi: ERC20, functionName: "balanceOf", args: [me.address] });
  if (eth < pfand + 500_000_000_000_000n) throw new Error("ETH below pfand plus gas");
  if (azl < 11_000n * 10n ** 18n) throw new Error("need 11000 AZL");
  const owns = await pub.readContract({ address: dep.panelOwner, abi: PANEL_OWNER, functionName: "ownsModules" });
  if (!owns) throw new Error("panel owner does not own both modules");
  if (!env("CAGE")) {
    const cage = await create();
    process.env.CAGE = cage;
  }
  await fund();
  await join();
  const seat = await pub.readContract({ address: env("CAGE") as Address, abi: CAGE_V5, functionName: "seatStatus" });
  if (!seat[0]) throw new Error("cage is not seated");
  log("cage.healthy", { cage: env("CAGE"), operator: me.address });
}

const mode = process.argv[2];
const invoked = process.argv[1]?.replace(/\\/g, "/").endsWith("setup.ts");
if (invoked) {
  const run = mode === "runner" ? runnerSetup : mode === "cage" ? cageSetup : null;
  if (!run) { console.error("usage: setup.ts runner|cage"); process.exit(1); }
  run().catch((err) => { console.error(String(err).slice(0, 500)); process.exit(1); });
}
