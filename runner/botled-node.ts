/**
 * Botled runner node. Needs RPC_URL, a runner key, a Surplus key, and an optional LANE.
 * It finds its own VRF draws from pool logs (v4 and v5). It does not read a hand-kept task list.
 * Writes require BOTLED_SEND=1. The live v4 cage is never written unless ALLOW_V4_CAGE=1.
 * Keys are not logged.
 */
import { keccak256, toHex, type Address, type Hex } from "viem";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  AZZLE, CAGE_V4, CAGE_V5, FACTORY, HERE, POOL, SCOPE,
  buildMessages, chooseLane, clients, commitment, decide, decodeDrawId, deployments, env, fetchEvidence, inputHash,
  loadAccount, makeLogger, sender, surplusKey, type CaseInput, type Deployments,
} from "./botled-node-lib.ts";

const LIVE_V4_CAGE = "0xe16bF0267C36dA27a037F8340BdE2909B117EFb2".toLowerCase();
const ZERO = ("0x" + "0".repeat(64)) as Hex;
const PHASE = ["NONE", "JURY", "APPEAL", "RULED"];

export type DrawWork = {
  version: 4 | 5;
  pool: Address;
  cage: Address;
  drawId: bigint;
  arbitration: Address;
  taskId: bigint;
  round: number;
};

type CaseView = {
  phase: number; round: number; hasResult: boolean; deadline: bigint; inputHash: Hex;
  poster: Address; worker: Address;
};

const { pub, transport } = clients();
const STATE_DIR = env("STATE_DIR", join(HERE, "state"))!;
const log = makeLogger(env("LOG_FILE", join(STATE_DIR, "node.log")));
const send = sender(pub, transport, log);
mkdirSync(STATE_DIR, { recursive: true });
const DRAW_REQUESTED = POOL.find((item) => item.type === "event" && item.name === "DrawRequested")!;

function field<T>(row: any, index: number, name: string): T {
  if (row && typeof row === "object" && name in row) return row[name] as T;
  return row[index] as T;
}

function assertWritable(to: Address) {
  if (to.toLowerCase() === LIVE_V4_CAGE && env("ALLOW_V4_CAGE") !== "1") {
    throw new Error("refusing to send to the live v4 cage");
  }
  if (env("BOTLED_SEND") !== "1") throw new Error("BOTLED_SEND is not 1");
  const host = new URL(rpcsHost()).hostname;
  if (host !== "127.0.0.1" && host !== "localhost" && env("MAINNET_OK") !== "1") {
    throw new Error("refusing mainnet sends without MAINNET_OK=1");
  }
}

function rpcsHost() {
  return env("RPC_URLS", env("RPC_URL", "https://mainnet.base.org"))!.split(",")[0].trim();
}

async function cagesOf(factory: Address): Promise<Address[]> {
  const n = await pub.readContract({ address: factory, abi: FACTORY, functionName: "cageCount" });
  const out: Address[] = [];
  for (let i = 0n; i < n; i++) out.push(await pub.readContract({ address: factory, abi: FACTORY, functionName: "cages", args: [i] }));
  return out;
}

export async function discoverDraws(me: Address, dep: Deployments = deployments()): Promise<DrawWork[]> {
  const jobs: DrawWork[] = [];
  const seen = new Set<string>();
  const pools: { version: 4 | 5; pool: Address; from: bigint; cages: Set<string> }[] = [];
  const v4cages = new Set((await cagesOf(dep.v4.factory)).map((a) => a.toLowerCase()));
  pools.push({ version: 4, pool: dep.v4.pool, from: BigInt(dep.v4.deployBlock), cages: v4cages });
  if (dep.v5.pool && dep.v5.factory && dep.v5.deployBlock) {
    const v5cages = new Set((await cagesOf(dep.v5.factory)).map((a) => a.toLowerCase()));
    pools.push({ version: 5, pool: dep.v5.pool, from: BigInt(dep.v5.deployBlock), cages: v5cages });
  }
  const latest = await pub.getBlockNumber();
  const lookback = BigInt(env("SCAN_LOOKBACK", "20000")!);
  for (const lane of pools) {
    const start = env("SCAN_FROM") ? BigInt(env("SCAN_FROM")!) : (latest > lookback ? latest - lookback : 0n);
    const from0 = start > lane.from ? start : lane.from;
    for (let from = from0; from <= latest; from += 2_000n) {
      const to = from + 1_999n > latest ? latest : from + 1_999n;
      let logs: Awaited<ReturnType<typeof pub.getLogs>> = [];
      for (let attempt = 0; attempt < 4; attempt++) {
        try {
          logs = await pub.getLogs({ address: lane.pool, event: DRAW_REQUESTED as any, fromBlock: from, toBlock: to });
          break;
        } catch (err) {
          if (attempt === 3) throw err;
          await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)));
        }
      }
      for (const row of logs) {
        const cage = row.args.cage as Address;
        const drawId = row.args.drawId as bigint;
        if (!lane.cages.has(cage.toLowerCase())) continue;
        const key = `${cage.toLowerCase()}:${drawId}`;
        if (seen.has(key)) continue;
        seen.add(key);
        if (!(await pub.readContract({ address: lane.pool, abi: POOL, functionName: "isDrawn", args: [cage, drawId, me] }))) continue;
        const info = await pub.readContract({ address: lane.pool, abi: POOL, functionName: "drawInfo", args: [cage, drawId] });
        if (info[3]) continue;
        const local = decodeDrawId(lane.version, drawId);
        const arbitration = lane.version === 5
          ? (local.m === 0 ? dep.modules.micro.arbitration : dep.modules.standard.arbitration)
          : await pub.readContract({ address: cage, abi: CAGE_V4, functionName: "arbitration" });
        const taskId = local.taskId;
        const round = local.round;
        jobs.push({ version: lane.version, pool: lane.pool, cage, drawId, arbitration, taskId, round });
      }
    }
  }
  return jobs;
}

async function readCase(work: DrawWork): Promise<CaseView> {
  if (work.version === 4) {
    const c = await pub.readContract({ address: work.cage, abi: CAGE_V4, functionName: "cases", args: [work.taskId] });
    return {
      phase: Number(field(c, 0, "phase")), round: Number(field(c, 1, "round")), hasResult: Boolean(field(c, 2, "hasResult")),
      deadline: field(c, 4, "deadline"), inputHash: field(c, 6, "inputHash"), poster: field(c, 8, "poster"), worker: field(c, 9, "worker"),
    };
  }
  const c = await pub.readContract({ address: work.cage, abi: CAGE_V5, functionName: "getCase", args: [work.arbitration, work.taskId] });
  return { phase: c.phase, round: c.round, hasResult: c.hasResult, deadline: c.deadline, inputHash: c.inputHash, poster: c.poster, worker: c.worker };
}

function statePath(work: DrawWork, runner: Address) {
  return join(STATE_DIR, `${work.cage}-${work.arbitration}-${work.taskId}-${work.round}-${runner}.json`);
}

type Saved = { salt: Hex; outcome: number; workerBps: number; lane: number; transcriptHash: Hex; commitTx?: Hex; revealTx?: Hex };

function loadSaved(p: string): Saved | undefined {
  return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : undefined;
}
function saveSaved(p: string, s: Saved) {
  writeFileSync(p + ".tmp", JSON.stringify(s, null, 2), { mode: 0o600 });
  renameSync(p + ".tmp", p);
}

async function evidenceText(hash: Hex): Promise<string> {
  if (hash === ZERO) return "";
  const sources = [`onchain:${deployments().evidence}`, ...env("EVIDENCE", "")!.split(",").map((s) => s.trim()).filter(Boolean)];
  return fetchEvidence(pub, sources, hash);
}

async function act(work: DrawWork, me: Address, account: NonNullable<ReturnType<typeof loadAccount>>) {
  const now = (await pub.getBlock()).timestamp;
  const c = await readCase(work);
  const dispute = await pub.readContract({ address: work.arbitration, abi: AZZLE, functionName: "disputes", args: [work.taskId] });
  log("draw", { version: work.version, cage: work.cage, taskId: work.taskId, round: work.round, phase: PHASE[c.phase] ?? c.phase });
  if (c.phase !== 1 || c.round !== work.round) return;
  const windows = work.version === 4
    ? await pub.readContract({ address: work.cage, abi: CAGE_V4, functionName: "windows", args: [work.taskId] })
    : await pub.readContract({ address: work.cage, abi: CAGE_V5, functionName: "windows", args: [work.arbitration, work.taskId] });
  const [commitEnd, revealEnd] = windows;
  if (commitEnd === 0n) return;
  const committed = work.version === 4
    ? await pub.readContract({ address: work.cage, abi: CAGE_V4, functionName: "commitments", args: [work.taskId, work.round, me] })
    : await pub.readContract({ address: work.cage, abi: CAGE_V5, functionName: "commitmentOf", args: [work.arbitration, work.taskId, work.round, me] });
  const voted = work.version === 4
    ? await pub.readContract({ address: work.cage, abi: CAGE_V4, functionName: "votes", args: [work.taskId, work.round, me] })
    : await pub.readContract({ address: work.cage, abi: CAGE_V5, functionName: "voteOf", args: [work.arbitration, work.taskId, work.round, me] });
  if (voted !== ZERO) return;
  const path = statePath(work, me);
  if (committed === ZERO) {
    if (now > commitEnd) { log("missed-commit", { taskId: work.taskId, round: work.round }); return; }
    let saved = loadSaved(path);
    if (!saved) {
      const scope = await scopeOf(work);
      const input: CaseInput = {
        version: work.version, chainId: BigInt(deployments().chainId), arbitration: work.arbitration, taskId: work.taskId,
        scope, poster: c.poster, worker: c.worker, posterEvidence: dispute[3], workerEvidence: dispute[4],
      };
      if (inputHash(input) !== c.inputHash) throw new Error("inputHash mismatch");
      const posterEv = dispute[3] === ZERO ? "" : await evidenceText(dispute[3]);
      const workerEv = dispute[4] === ZERO ? "" : await evidenceText(dispute[4]);
      const lane = chooseLane(me, work.taskId, work.round);
      const mock = env("MOCK_VOTE");
      const ruling = mock
        ? { lane, outcome: Number(mock.split(":")[0]), workerBps: Number(mock.split(":")[1]), transcriptHash: keccak256(toHex(`mock:${me}:${work.taskId}`)) }
        : await decide(surplusKey()!, lane, buildMessages(scope || "(scope is inside the evidence)", posterEv, workerEv), log);
      saved = { salt: toHex(randomBytes(32)), outcome: ruling.outcome, workerBps: ruling.workerBps, lane: ruling.lane, transcriptHash: ruling.transcriptHash };
      saveSaved(path, saved);
      log("decided", { taskId: work.taskId, round: work.round, lane: saved.lane, outcome: saved.outcome, workerBps: saved.workerBps });
    }
    const hash = commitment(work.version, work.cage, work.arbitration, work.taskId, work.round, me, c.inputHash, saved.outcome, saved.workerBps, saved.lane, saved.transcriptHash, saved.salt);
    assertWritable(work.cage);
    const args = work.version === 4 ? [work.taskId, hash] : [work.arbitration, work.taskId, hash];
    const abi = work.version === 4 ? CAGE_V4 : CAGE_V5;
    saved.commitTx = await send(account, work.cage, abi, "commit", args);
    saveSaved(path, saved);
    return;
  }
  if (now <= commitEnd || now > revealEnd) return;
  const saved = loadSaved(path);
  if (!saved) { log("lost-salt", { taskId: work.taskId, round: work.round }); return; }
  assertWritable(work.cage);
  const args = work.version === 4
    ? [work.taskId, saved.outcome, saved.workerBps, saved.lane, saved.transcriptHash, saved.salt]
    : [work.arbitration, work.taskId, saved.outcome, saved.workerBps, saved.lane, saved.transcriptHash, saved.salt];
  saved.revealTx = await send(account, work.cage, work.version === 4 ? CAGE_V4 : CAGE_V5, "reveal", args);
  saveSaved(path, saved);
}

async function scopeOf(work: DrawWork): Promise<string> {
  try {
    const reg = work.version === 4
      ? await pub.readContract({ address: work.cage, abi: CAGE_V4, functionName: "scopeRegistry" })
      : (work.arbitration.toLowerCase() === deployments().modules.micro.arbitration.toLowerCase()
        ? await pub.readContract({ address: work.cage, abi: CAGE_V5, functionName: "microScope" })
        : await pub.readContract({ address: work.cage, abi: CAGE_V5, functionName: "standardScope" }));
    if (!reg || reg === "0x0000000000000000000000000000000000000000") return "";
    return await pub.readContract({ address: reg, abi: SCOPE, functionName: "scopeOf", args: [work.taskId] });
  } catch { return ""; }
}

async function keep(work: DrawWork, account: NonNullable<ReturnType<typeof loadAccount>>) {
  if (env("KEEPER") !== "1") return;
  const now = (await pub.getBlock()).timestamp;
  const c = await readCase(work);
  const info = await pub.readContract({ address: work.pool, abi: POOL, functionName: "drawInfo", args: [work.cage, work.drawId] });
  const abi = work.version === 4 ? CAGE_V4 : CAGE_V5;
  const args = work.version === 4 ? [work.taskId] : [work.arbitration, work.taskId];
  assertWritable(work.cage);
  if (c.phase === 1 && info[0] === 0n) {
    const price = await pub.readContract({ address: work.pool, abi: POOL, functionName: "vrfPrice", args: [3] });
    await send(account, work.cage, abi, "retryDraw", args, price);
    return;
  }
  if (c.phase === 1 && (info[1] === 0n ? now > c.deadline : now > (await readWindowsEnd(work)))) {
    await send(account, work.cage, abi, "closeRound", args);
    return;
  }
  if (c.phase === 2 && c.hasResult && now > c.deadline) await send(account, work.cage, abi, "finalize", args);
}

async function readWindowsEnd(work: DrawWork): Promise<bigint> {
  const w = work.version === 4
    ? await pub.readContract({ address: work.cage, abi: CAGE_V4, functionName: "windows", args: [work.taskId] })
    : await pub.readContract({ address: work.cage, abi: CAGE_V5, functionName: "windows", args: [work.arbitration, work.taskId] });
  return w[1];
}

export async function tickOnce(account: NonNullable<ReturnType<typeof loadAccount>>) {
  const draws = await discoverDraws(account.address);
  log("scan", { runner: account.address, draws: draws.length });
  for (const work of draws) {
    try {
      await act(work, account.address, account);
      await keep(work, account);
    } catch (err) {
      log("tick.error", { cage: work.cage, taskId: work.taskId, err: (err as Error).message.slice(0, 400) });
    }
  }
  writeFileSync(join(STATE_DIR, "heartbeat"), new Date().toISOString());
  return draws.length;
}

async function main() {
  const account = loadAccount("RUNNER_KEY_FILE", "RUNNER_PK");
  if (!account) throw new Error("set RUNNER_KEY_FILE or RUNNER_PK");
  if (!env("MOCK_VOTE") && !surplusKey()) throw new Error("set SURPLUS_API_KEY or SURPLUS_KEY_FILE");
  log("node.start", { runner: account.address, lane: env("LANE") ?? "auto", send: env("BOTLED_SEND") === "1", keeper: env("KEEPER") === "1" });
  for (;;) {
    await tickOnce(account);
    if (env("ONCE") === "1") return;
    await new Promise((r) => setTimeout(r, Number(env("POLL_MS", "30000"))));
  }
}

const invoked = process.argv[1]?.replace(/\\/g, "/").endsWith("botled-node.ts");
if (invoked) main().catch((err) => { log("node.crash", { err: String(err).slice(0, 500) }); process.exit(1); });
