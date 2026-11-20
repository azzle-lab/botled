/**
 * Botled node library — shared by the runner node, the cage operator CLI and setup.
 * Supports both cage generations:
 *   v4 (BotledArbitrator, one module per cage, functions take taskId, draw id = taskId<<8|round)
 *   v5 (BotledCageV5, micro + standard, functions take (arbitration, taskId), draw id = (m+1)<<248|taskId<<8|round)
 * No key is ever logged. Keys are read from a JSON file {"private_key": "0x..."} (mode 600) or an env var.
 */
import {
  createPublicClient, createWalletClient, fallback, http, parseAbi, keccak256, toHex, hexToString, stringToHex,
  encodeAbiParameters, padHex, hexToBigInt, type Address, type Hex, type PublicClient, type Chain,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { base } from "viem/chains";
import { readFileSync, existsSync, appendFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const HERE = dirname(fileURLToPath(import.meta.url));
export const env = (k: string, d?: string) => (process.env[k] !== undefined && process.env[k] !== "" ? process.env[k] : d);

// ------------------------------------------------------------------ deployments
export type Deployments = {
  chainId: number; azl: Address; config: Address; panelOwner: Address; evidence: Address;
  modules: Record<"micro" | "standard", { arbitration: Address; vault: Address; minimumBondAZL: number }>;
  v4: { pool: Address; factory: Address; deployBlock: number };
  v5: { pool: Address | null; factory: Address | null; deployBlock: number | null };
};
export function deployments(): Deployments {
  const f = env("DEPLOYMENTS", join(HERE, "deployments", "base.json"))!;
  const d = JSON.parse(readFileSync(f, "utf8")) as Deployments;
  if (env("V5_POOL")) d.v5.pool = env("V5_POOL") as Address;
  if (env("V5_FACTORY")) d.v5.factory = env("V5_FACTORY") as Address;
  if (env("V5_FROM_BLOCK")) d.v5.deployBlock = Number(env("V5_FROM_BLOCK"));
  return d;
}

// ------------------------------------------------------------------ chain clients
export const rpcs = () => env("RPC_URLS", env("RPC_URL", "https://mainnet.base.org"))!.split(",").map((s) => s.trim()).filter(Boolean);
export function clients() {
  const transport = fallback(rpcs().map((u) => http(u, { retryCount: 2, retryDelay: 1500, timeout: 20_000 })));
  const chain: Chain = base;
  const pub = createPublicClient({ chain, transport }) as PublicClient;
  return { pub, transport, chain };
}
export const redactRpc = (u: string) => u.replace(/\/\/([^/]*@)/, "//").replace(/([?&](key|apikey|api_key)=)[^&]+/i, "$1***");

export function loadAccount(fileVar: string, pkVar: string): PrivateKeyAccount | undefined {
  const f = env(fileVar);
  let pk = env(pkVar);
  if (f) {
    if (!existsSync(f)) throw new Error(`${fileVar}: ${f} does not exist`);
    const j = JSON.parse(readFileSync(f, "utf8"));
    pk = j.private_key ?? j.privateKey ?? j.key;
  }
  if (!pk) return undefined;
  return privateKeyToAccount((pk.startsWith("0x") ? pk : `0x${pk}`) as Hex);
}

export function surplusKey(): string | undefined {
  if (env("SURPLUS_API_KEY")) return env("SURPLUS_API_KEY");
  const f = env("SURPLUS_KEY_FILE");
  if (f && existsSync(f)) { const j = JSON.parse(readFileSync(f, "utf8")); return j.key ?? j.api_key ?? j.apiKey; }
  return undefined;
}

// ------------------------------------------------------------------ logging
export function makeLogger(file?: string) {
  if (file) mkdirSync(dirname(file), { recursive: true });
  return (event: string, data: Record<string, unknown> = {}) => {
    const line = JSON.stringify({ t: new Date().toISOString(), event, ...data }, (_, v) => (typeof v === "bigint" ? v.toString() : v));
    console.log(line);
    if (file) appendFileSync(file, line + "\n");
  };
}

// ------------------------------------------------------------------ ABIs
export const ERC20 = parseAbi([
  "function balanceOf(address) view returns (uint256)", "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)", "function transfer(address,uint256) returns (bool)",
]);
export const POOL = parseAbi([
  "function bondToken() view returns (address)",
  "function runnerReserve() view returns (uint256)",
  "function exitCooldown() view returns (uint64)",
  "function runners(address) view returns (bool listed, uint32 activeCases, uint64 exitReadyAt, uint256 bond)",
  "function runnerEligible(address) view returns (bool)",
  "function runnerCount() view returns (uint256)",
  "function registerRunner(uint256 amount)",
  "function bondRunner(uint256 amount)",
  "function scheduleRunnerExit()",
  "function withdrawRunner(uint256 amount)",
  "function isDrawn(address cage, uint256 drawId, address runner) view returns (bool)",
  "function drawInfo(address cage, uint256 drawId) view returns (uint64 requestedAt, uint64 fulfilledAt, uint256 count, bool settled)",
  "function drawnRunners(address cage, uint256 drawId) view returns (address[])",
  "function vrfPrice(uint8 n) view returns (uint256)",
  "function rewardFund() view returns (uint256)",
  "event DrawRequested(address indexed cage, uint256 indexed drawId, uint256 requestId, uint256 pricePaid)",
  "event DrawFulfilled(address indexed cage, bytes32 indexed key, address[] runners)",
]);
export const FACTORY = parseAbi([
  "function cageCount() view returns (uint256)", "function cages(uint256) view returns (address)",
  "function isCage(address) view returns (bool)",
  "function deployCage(uint32 constitutionId, bytes32 salt) returns (address)",
  "function predictCage(address deployer, bytes32 salt) view returns (address)",
  "event CageDeployed(address indexed cage, address indexed operator, uint32 constitutionId)",
]);
export const CAGE_V4 = parseAbi([
  "function cases(uint256) view returns (uint8 phase, uint8 round, bool hasResult, uint32 paramsId, uint64 deadline, uint64 hardStop, bytes32 inputHash, bytes32 result, address poster, address worker)",
  "function windows(uint256) view returns (uint256 commitEnd, uint256 revealEnd)",
  "function arbitration() view returns (address)",
  "function scopeRegistry() view returns (address)",
  "function commitments(uint256, uint8, address) view returns (bytes32)",
  "function votes(uint256, uint8, address) view returns (bytes32)",
  "function rounds(uint256, uint8) view returns (uint8 revealed, uint8 leaderCount, bytes32 leaderVote, address appellant, uint128 bond, bytes32 appealedResult)",
  "function openCase(uint256 taskId) payable", "function retryDraw(uint256 taskId) payable",
  "function commit(uint256 taskId, bytes32 commitment)",
  "function reveal(uint256 taskId, uint8 outcome, uint16 workerBps, uint8 lane, bytes32 transcriptHash, bytes32 salt)",
  "function closeRound(uint256 taskId)", "function finalize(uint256 taskId)", "function syncAzzleTimeout(uint256 taskId)",
]);
export const CAGE_V5 = parseAbi([
  "struct Case { uint8 phase; uint8 round; bool hasResult; uint32 paramsId; uint64 deadline; uint64 hardStop; bytes32 inputHash; bytes32 result; address poster; address worker; }",
  "struct Round { uint8 revealed; uint8 leaderCount; bytes32 leaderVote; address appellant; uint128 bond; bytes32 appealedResult; }",
  "function VERSION() view returns (uint8)",
  "function operator() view returns (address)",
  "function micro() view returns (address)", "function standard() view returns (address)",
  "function microScope() view returns (address)", "function standardScope() view returns (address)",
  "function getCase(address arbitration, uint256 taskId) view returns (Case)",
  "function getRound(address arbitration, uint256 taskId, uint8 r) view returns (Round)",
  "function windows(address arbitration, uint256 taskId) view returns (uint256 commitEnd, uint256 revealEnd)",
  "function commitmentOf(address arbitration, uint256 taskId, uint8 r, address runner) view returns (bytes32)",
  "function voteOf(address arbitration, uint256 taskId, uint8 r, address runner) view returns (bytes32)",
  "function decodeDrawId(uint256 id) view returns (address arbitration, uint256 taskId, uint8 r)",
  "function seatStatus() view returns (bool seated, bool microEligible, bool standardEligible, uint256 microBond, uint256 standardBond)",
  "function openCase(address arbitration, uint256 taskId) payable", "function retryDraw(address arbitration, uint256 taskId) payable",
  "function commit(address arbitration, uint256 taskId, bytes32 commitment)",
  "function reveal(address arbitration, uint256 taskId, uint8 outcome, uint16 workerBps, uint8 lane, bytes32 transcriptHash, bytes32 salt)",
  "function closeRound(address arbitration, uint256 taskId)", "function finalize(address arbitration, uint256 taskId)",
  "function syncAzzleTimeout(address arbitration, uint256 taskId)",
  "function seat(uint256 microTarget, uint256 standardTarget) payable", "function unseat()", "function exit()",
  "function scheduleExit()", "function claimPfand()", "function topUpBond(uint8 m, uint256 target)",
  "function withdrawBond(uint8 m, uint256 amount)",
]);
export const AZZLE = parseAbi([
  "function disputes(uint256) view returns (uint256 taskId, address opener, address arbitrator, bytes32 posterEvidence, bytes32 workerEvidence, uint64 evidenceDeadline, uint64 rulingDeadline, uint8 status, uint8 outcome, uint256 slashed)",
  "function rulingWindow() view returns (uint64)",
  "function timeout(uint256 taskId)",
  "function authorized(address) view returns (bool)",
  "event DisputeOpened(uint256 indexed taskId, address indexed opener, address indexed arbitrator, uint64 evidenceDeadline)",
  "event ArbitratorAssigned(uint256 indexed taskId, address indexed arbitrator)",
]);
export const VAULT = parseAbi([
  "function bonds(address) view returns (uint256)", "function isEligible(address) view returns (bool)",
  "function withdrawReadyAt(address) view returns (uint64)", "function activeAssignments(address) view returns (uint256)",
  "function minimumBond() view returns (uint256)", "function reservedSlash(address) view returns (uint256)",
]);
export const PANEL_OWNER = parseAbi([
  "function pfand() view returns (uint256)", "function isSeated(address) view returns (bool)",
  "function ownsModules() view returns (bool)", "function claimable(address) view returns (uint256)",
]);
export const EVID = parseAbi([
  "function publishedAt(bytes32) view returns (uint256)",
  "function publish(bytes document) returns (bytes32)",
  "event Published(bytes32 indexed hash, address indexed publisher, bytes document)",
]);
export const SCOPE = parseAbi(["function scopeOf(uint256) view returns (string)"]);

// ------------------------------------------------------------------ constitution (mirrors BotledConfig genesis, id 0)
const CDIR = env("CONSTITUTION_DIR", join(HERE, "constitution"))!;
const cfile = (n: string) => readFileSync(join(CDIR, n), "utf8");
export const LANES = [
  { model: "claude-opus-5", provider: "anthropic" },
  { model: "gemini-4-argon", provider: "google" },
] as const;
const b32 = (s: string) => padHex(stringToHex(s), { dir: "right", size: 32 });
export function constitutionHash(): Hex {
  const h = (n: string) => keccak256(stringToHex(cfile(n)));
  return keccak256(encodeAbiParameters(
    [{ type: "bytes32" }, { type: "bytes32" }, { type: "bytes32" }, { type: "bytes32" },
     { type: "tuple[]", components: [{ name: "model", type: "bytes32" }, { name: "provider", type: "bytes32" }] }],
    [h("prompt_template.md"), h("rubric.md"), h("ruling.schema.json"), h("decoding.json"),
     LANES.map((l) => ({ model: b32(l.model), provider: b32(l.provider) }))],
  ));
}

const ZERO32 = padHex("0x0", { size: 32 });
export type CaseInput = { version: 4 | 5; chainId: bigint; arbitration: Address; taskId: bigint; scope: string;
  poster: Address; worker: Address; posterEvidence: Hex; workerEvidence: Hex };

/** Mirrors BotledArbitrator._inputHash (v4) / BotledCageV5._inputHash (v5): only the DOMAIN differs. */
export function inputHash(c: CaseInput): Hex {
  const domain = keccak256(stringToHex(c.version === 5 ? "BOTLED.v5" : "BOTLED.v4"));
  return keccak256(encodeAbiParameters(
    [{ type: "bytes32" }, { type: "uint256" }, { type: "address" }, { type: "uint256" }, { type: "bytes32" },
     { type: "bytes32" }, { type: "address" }, { type: "address" }, { type: "bytes32" }, { type: "bytes32" }],
    [domain, c.chainId, c.arbitration, c.taskId, constitutionHash(), c.scope ? keccak256(stringToHex(c.scope)) : ZERO32,
     c.poster, c.worker, c.posterEvidence, c.workerEvidence],
  ));
}

/** v4: keccak(cage, taskId, r, runner, inputHash, o, bps, lane, transcript, salt); v5 adds `arbitration` after cage. */
export function commitment(version: 4 | 5, cage: Address, arbitration: Address, taskId: bigint, round: number, runner: Address,
  inHash: Hex, outcome: number, workerBps: number, lane: number, transcriptHash: Hex, salt: Hex): Hex {
  const tail = [{ type: "uint256" }, { type: "uint8" }, { type: "address" }, { type: "bytes32" },
    { type: "uint8" }, { type: "uint16" }, { type: "uint8" }, { type: "bytes32" }, { type: "bytes32" }] as const;
  const vals = [taskId, round, runner, inHash, outcome, workerBps, lane, transcriptHash, salt] as const;
  if (version === 4) return keccak256(encodeAbiParameters([{ type: "address" }, ...tail], [cage, ...vals]));
  return keccak256(encodeAbiParameters([{ type: "address" }, { type: "address" }, ...tail], [cage, arbitration, ...vals]));
}

export function decodeDrawId(version: 4 | 5, id: bigint): { m: number; taskId: bigint; round: number } {
  const round = Number(id & 0xffn);
  if (version === 4) return { m: -1, taskId: id >> 8n, round };
  return { m: Number(id >> 248n) - 1, taskId: (id >> 8n) & ((1n << 240n) - 1n), round };
}
export const drawKey = (cage: Address, drawId: bigint) =>
  keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [cage, drawId]));

/** Deterministic lane spread so honest runners reach `minProviders` without coordination (LANE pins it). */
export function chooseLane(runner: Address, taskId: bigint, round: number): number {
  if (env("LANE") !== undefined) return Number(env("LANE"));
  const h = keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }, { type: "uint8" }], [runner, taskId, round]));
  return Number(hexToBigInt(h) % BigInt(LANES.length));
}

// ------------------------------------------------------------------ prompt + Surplus
export const SURPLUS_BASE = env("SURPLUS_BASE", "https://api.surplusintelligence.ai")!;
export function buildMessages(scope: string, posterEv: string, workerEv: string) {
  const body = cfile("prompt_template.md").replace(/^<!--.*?-->\s*/s, "");
  const [sys, user] = body.split(/\nUSER:\n/);
  return [
    { role: "system", content: sys.replace(/^SYSTEM:\n/, "").trim() },
    { role: "user", content: user.replace("{{SCOPE}}", scope).replace("{{POSTER_EVIDENCE}}", posterEv)
      .replace("{{WORKER_EVIDENCE}}", workerEv).trim() },
  ];
}
function surplusRequest(lane: number, messages: { role: string; content: string }[]) {
  return { model: LANES[lane].model, provider: [LANES[lane].provider], messages,
    ...JSON.parse(cfile("decoding.json")), response_format: { type: "json_schema", json_schema: JSON.parse(cfile("ruling.schema.json")) } };
}
const OUTCOME: Record<string, number> = { NONE: 0, POSTER_WINS: 1, WORKER_WINS: 2, SPLIT: 3, MUTUAL: 4 };
export function parseRuling(raw: string): { outcome: number; workerBps: number } | null {
  let j: any;
  const fenced = raw.match(/^\s*```(?:json)?\s*(\{.*\})\s*```\s*$/s);
  try { j = JSON.parse(fenced ? fenced[1] : raw); } catch { return null; }
  if (!j || typeof j !== "object" || Object.keys(j).sort().join(",") !== "outcome,reason,workerBps") return null;
  const o = OUTCOME[j.outcome], b = j.workerBps;
  if (o === undefined || !Number.isInteger(b)) return null;
  const ok = (o === 0 && b === 0) || (o === 1 && b === 0) || (o === 2 && b === 10000)
    || (o === 3 && b >= 1000 && b <= 9000 && b % 500 === 0) || (o === 4 && (b === 0 || b === 5000));
  return ok ? { outcome: o, workerBps: b } : null;
}
export async function decide(apiKey: string, lane0: number, messages: ReturnType<typeof buildMessages>, log: (e: string, d?: any) => void) {
  const order = [lane0, ...LANES.map((_, i) => i).filter((i) => i !== lane0)];
  for (const lane of order) {
    for (let attempt = 0; attempt < 2; attempt++) {
      const body = surplusRequest(lane, messages);
      try {
        const r = await fetch(`${SURPLUS_BASE}/v1/chat/completions`, { method: "POST",
          headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" }, body: JSON.stringify(body) });
        const telemetry: Record<string, string> = {};
        r.headers.forEach((v, k) => { if (k.startsWith("x-si-") || k === "x-request-id") telemetry[k] = v; });
        if (!r.ok) throw new Error(`surplus http ${r.status}: ${(await r.text()).slice(0, 200)}`);
        const content = ((await r.json()) as any).choices?.[0]?.message?.content ?? "";
        const ruling = parseRuling(content);
        if (ruling) return { lane, ...ruling, transcriptHash: keccak256(stringToHex(JSON.stringify({ body, content, telemetry }))), content, telemetry };
        log("surplus.unparseable", { lane, attempt });
      } catch (e) { log("surplus.error", { lane, attempt, err: (e as Error).message }); }
    }
  }
  return { lane: lane0, outcome: 0, workerBps: 0, transcriptHash: keccak256(stringToHex("abstain")), content: "", telemetry: {} };
}
/** Free, read-only key check: GET /v1/payments/balance (credit in microdollars). */
export async function surplusBalance(apiKey: string): Promise<{ ok: boolean; status: number; creditUsd?: number; error?: string }> {
  try {
    const r = await fetch(`${SURPLUS_BASE}/v1/payments/balance`, { headers: { Authorization: `Bearer ${apiKey}` } });
    if (!r.ok) return { ok: false, status: r.status, error: (await r.text()).slice(0, 200) };
    const j: any = await r.json();
    const micro = Number(j.credit_balance_usdc ?? j.balance_usdc ?? 0);
    return { ok: true, status: r.status, creditUsd: micro / 1e6 };
  } catch (e) { return { ok: false, status: 0, error: (e as Error).message }; }
}

// ------------------------------------------------------------------ evidence
/** Sources: "onchain:<BotledEvidence>" | "https://host/{hash}" | "dir:/path" (files <hash>.txt). Always re-hashed. */
export async function fetchEvidence(pub: PublicClient, sources: string[], hash: Hex): Promise<string> {
  const errors: string[] = [];
  for (const src of sources) {
    try {
      let body: string;
      if (src.startsWith("onchain:")) {
        const addr = src.slice(8) as Address;
        const blk = await pub.readContract({ address: addr, abi: EVID, functionName: "publishedAt", args: [hash] });
        if (blk === 0n) throw new Error("not published");
        const logs = await pub.getLogs({ address: addr, event: EVID[2], args: { hash }, fromBlock: blk, toBlock: blk });
        if (!logs.length) throw new Error("log missing");
        body = hexToString(logs[0].args.document as Hex);
      } else if (src.startsWith("dir:")) {
        body = readFileSync(join(src.slice(4), `${hash}.txt`), "utf8");
      } else {
        const r = await fetch(src.replace("{hash}", hash));
        if (!r.ok) throw new Error(`http ${r.status}`);
        body = await r.text();
      }
      if (keccak256(toHex(body)) !== hash) throw new Error("hash mismatch");
      return body;
    } catch (e) { errors.push(`${src.slice(0, 60)}: ${(e as Error).message}`); }
  }
  throw new Error(`evidence ${hash} unavailable (${errors.join("; ")})`);
}

// ------------------------------------------------------------------ tx helper (simulate first: no gas burned on reverts)
export function sender(pub: PublicClient, transport: any, log: (e: string, d?: any) => void) {
  return async (account: PrivateKeyAccount, address: Address, abi: any, functionName: string, args: unknown[], value = 0n, tag = "") => {
    const wallet = createWalletClient({ chain: base, transport, account });
    const { request } = await pub.simulateContract({ account, address, abi, functionName, args, value } as any);
    const b = (await pub.getBlock()).baseFeePerGas ?? 10_000_000n;
    const tip = BigInt(env("PRIORITY_FEE_WEI", "1000000")!);
    const hash = await wallet.writeContract({ ...(request as any), maxFeePerGas: b * 2n + tip, maxPriorityFeePerGas: tip });
    const rcpt = await pub.waitForTransactionReceipt({ hash, timeout: 180_000 });
    log("tx", { fn: functionName, from: account.address, to: address, tag, hash, status: rcpt.status, gasUsed: rcpt.gasUsed });
    if (rcpt.status !== "success") throw new Error(`${functionName} reverted ${hash}`);
    return hash;
  };
}
export const fmt = (wei: bigint, dec = 18) => {
  const s = (Number(wei) / 10 ** dec);
  return s.toLocaleString("en-US", { maximumFractionDigits: 6 });
};
