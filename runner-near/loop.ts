// Self-run juror for Botled v5/NEAR. Identity = one NEAR account; its Base address is derived (path "base-1") and
// signs through v1.signer. The runner holds no Base ETH: enroll / commitFor / reveal are relayed by anyone.
//   ticket   : request_ticket(no_shows_covered, session_key) -> MPC-signed Enroll ticket -> pool.enroll (relayed)
//   seat     : lane = (pool.seat - 1) % 2 (VRF order, enforced by the cage); request = HEAD(lane)‖juror‖USER‖TAIL(lane)
//   inference: sponsor relay (default, counted vote) or own NEAR AI key (liveness only: no no-show, no reward)
//   commit   : EIP-712 Commit signed by the ticket's session key (no MPC call per commit), relayed via commitFor
//   reveal   : after the commit window, permissionless
// Sends nothing on a real chain unless BOTLED_SEND=1 (e2e.ts drives it against local anvil + mocks).
import {
  createPublicClient, encodeFunctionData, hashMessage, hexToBytes, http, keccak256, toHex,
  type Hex, type LocalAccount, type PublicClient,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import { existsSync, readFileSync, writeFileSync, chmodSync } from "node:fs";
import { BASE_PATH, deriveBaseAddress, mpcToEvm, signArgs, MAINNET_SIGNER, type MpcSignature } from "./chainsig.ts";
import { buildRequest } from "./request.ts";
import { chat, ruling } from "./nearai.ts";
import { LANE_LIST, laneOfSeat, type LaneCfg } from "./lanes.ts";
import { cageAbi, poolAbi } from "./abi.ts";
import { commitDigest, commitment } from "./digests.ts";
import { requestSponsored, type SponsoredReceipt } from "./relay.ts";

/** Minimal NEAR access the loop needs (near-api-js Account, a wallet, or a NEAR Intents agent can implement it). */
export interface Near {
  accountId: string;
  view<T>(contract: string, method: string, args: object): Promise<T>;
  call<T>(contract: string, method: string, args: object, opts?: { deposit?: bigint; gasTgas?: number }): Promise<T>;
  /** Base address controlled via Chain Signatures; default = mainnet v1.signer derivation */
  baseAddress?(path: string): Hex;
}

/** Whoever pays Base gas for relayed txs (Botled keeper or any friendly relayer). */
export interface Relay {
  send(to: Hex, data: Hex): Promise<Hex>;
}

export type RunnerConfig = {
  registry: string;
  usdc: string;
  mpc: string;
  cage: Hex;
  pool: Hex;
  chainId: bigint;
  sponsorUrl?: string; // counted votes; comma-separated list = failover across independent relays
  nearAiKey?: string; // own-key liveness fallback
  nearAiUrl?: string;
  lanes: LaneCfg[];
  systemPrompt: string;
  schema: string;
  statePath: string; // session key + pending reveals (local, chmod 600)
  send: boolean;
};

export function configFromEnv(): RunnerConfig {
  const vec = new URL("../test/near-vectors/", import.meta.url);
  return {
    registry: process.env.BOTLED_NEAR_REGISTRY ?? "b0c3f8cbde21c8814baccfd84afce62f70ab33b57fe3717b01828ee41f06c625" /* mainnet registry */,
    usdc: process.env.NEAR_USDC ?? "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1",
    mpc: process.env.NEAR_MPC ?? MAINNET_SIGNER,
    cage: process.env.BOTLED_CAGE as Hex,
    pool: process.env.BOTLED_POOL as Hex,
    chainId: BigInt(process.env.BASE_CHAIN_ID ?? 8453),
    sponsorUrl: process.env.SPONSOR_URL,
    nearAiKey: process.env.NEAR_AI_API_KEY,
    nearAiUrl: process.env.NEAR_AI_URL,
    lanes: LANE_LIST,
    systemPrompt: readFileSync(new URL("system_prompt.txt", vec), "utf8"),
    schema: readFileSync(new URL("schema.compact.json", vec), "utf8"),
    statePath: process.env.BOTLED_STATE ?? ".botled-runner.json",
    send: process.env.BOTLED_SEND === "1",
  };
}

export function baseClient(rpc = process.env.BASE_RPC ?? "https://mainnet.base.org") {
  return createPublicClient({ chain: base, transport: http(rpc) });
}

type Pending = {
  arbitration: Hex; taskId: string; round: number; outcome: number; workerBps: number; salt: Hex;
  receipt: SponsoredReceipt; counted: boolean;
};
type State = { sessionKey?: Hex; pending: Record<string, Pending> };

export class Runner {
  readonly near: Near;
  readonly relay: Relay;
  readonly client: PublicClient;
  readonly cfg: RunnerConfig;
  readonly me: Hex;
  private state: State;

  constructor(near: Near, relay: Relay, client: PublicClient, cfg: RunnerConfig) {
    this.near = near;
    this.relay = relay;
    this.client = client;
    this.cfg = cfg;
    this.me = near.baseAddress ? near.baseAddress(BASE_PATH) : deriveBaseAddress(near.accountId);
    this.state = existsSync(cfg.statePath) ? JSON.parse(readFileSync(cfg.statePath, "utf8")) : { pending: {} };
  }

  private save() {
    writeFileSync(this.cfg.statePath, JSON.stringify(this.state, null, 1));
    chmodSync(this.cfg.statePath, 0o600);
  }

  private session(): LocalAccount | undefined {
    return this.state.sessionKey ? privateKeyToAccount(this.state.sessionKey) : undefined;
  }

  /** EIP-191 / EIP-712 digest -> signature from the runner's MPC-derived Base key */
  async mpcSign(digest: Hex, path = BASE_PATH): Promise<Hex> {
    const sig = await this.near.call<MpcSignature>(this.cfg.mpc, "sign", signArgs(digest, path), { deposit: 1n, gasTgas: 50 });
    return mpcToEvm(sig);
  }

  /** 1. signup: prove the Base address, pay $20 USDC (5 profit / 5 dev / 10 budget) in one ft_transfer_call */
  async signup(amount = "20000000") {
    const msg = await this.near.view<string>(this.cfg.registry, "signup_message", { account: this.near.accountId, base: this.me });
    const sig = await this.mpcSign(hashMessage(msg));
    const ftMsg = JSON.stringify({ signup: { base: this.me, sig } });
    if (!this.cfg.send) return console.log("[dry] ft_transfer_call", amount, ftMsg);
    await this.near.call(this.cfg.usdc, "ft_transfer_call", { receiver_id: this.cfg.registry, amount, msg: ftMsg }, { deposit: 1n, gasTgas: 100 });
  }

  /** 2. keep a valid Base ticket; every new ticket carries a fresh session key (rotates the commit key). */
  async ensureTicket(force = false): Promise<boolean> {
    const r = await this.client.readContract({ address: this.cfg.pool, abi: poolAbi, functionName: "runners", args: [this.me] });
    const [, , noShows, covered, , validUntil, , sessionKey] = r;
    const now = (await this.client.getBlock()).timestamp;
    const haveKey = this.session()?.address.toLowerCase() === sessionKey.toLowerCase();
    if (!force && noShows <= covered && validUntil > now + 86_400n && haveKey) return false;
    if (!this.cfg.send) { console.log("[dry] request_ticket", noShows); return false; }
    const fresh = generatePrivateKey();
    const t = await this.near.call<any>(
      this.cfg.registry, "request_ticket",
      { no_shows_covered: noShows, session_key: privateKeyToAccount(fresh).address }, { deposit: 1n, gasTgas: 100 },
    );
    await this.relay.send(this.cfg.pool, encodeFunctionData({
      abi: poolAbi, functionName: "enroll",
      args: [this.me, t.nearAccount, t.epoch, t.noShowsCovered, BigInt(t.validUntil), t.sessionKey, mpcToEvm(t.mpc)],
    }));
    this.state.sessionKey = fresh;
    this.save();
    return true;
  }

  /** 3. serve a seat: request -> receipt -> commit. Returns the pending reveal (persisted). */
  async serveSeat(arbitration: Hex, taskId: bigint, docs: { scope: string; poster: string; worker: string }): Promise<Pending | undefined> {
    const { cage, pool } = this.cfg;
    const c = await this.client.readContract({ address: cage, abi: cageAbi, functionName: "getCase", args: [arbitration, taskId] });
    const id = `${arbitration}:${taskId}:${c.round}`;
    if (this.state.pending[id]) return this.state.pending[id];
    const drawId = await this.client.readContract({ address: cage, abi: cageAbi, functionName: "drawId", args: [arbitration, taskId, c.round] });
    const seat = await this.client.readContract({ address: pool, abi: poolAbi, functionName: "seat", args: [cage, drawId, this.me] });
    if (seat === 0) return undefined;
    const laneCount = await this.client.readContract({ address: cage, abi: cageAbi, functionName: "laneCount" });
    const lane = this.cfg.lanes[laneOfSeat(seat, laneCount)];
    const request = buildRequest(lane, this.cfg.systemPrompt, this.cfg.schema, this.me, c.round, c.inputHash, docs);
    if (!this.cfg.send) { console.log("[dry] seat", seat, "lane", lane.model, request.length, "bytes"); return undefined; }

    let receipt: SponsoredReceipt;
    let counted = true;
    try {
      // several independent relays (each its own BotledNearConfig sponsor key): first that serves the seat wins.
      // A relay that already billed this seat but withholds the co-signature blocks the others (max_runs_per_seat);
      // that shows up as WITHHELD against its NEAR account in tools/audit.ts.
      const urls = (this.cfg.sponsorUrl ?? "").split(",").map((u) => u.trim()).filter(Boolean);
      if (!urls.length) throw new Error("no sponsor relay configured");
      let last: unknown;
      receipt = undefined as unknown as SponsoredReceipt;
      for (const u of urls) {
        try { receipt = await requestSponsored(u, arbitration, taskId, request); last = undefined; break; } catch (e) { last = e; }
      }
      if (last) throw last;
    } catch (e) {
      // liveness fallback: own NEAR AI key; the reveal avoids the no-show penalty but is not tallied or rewarded
      if (!this.cfg.nearAiKey) throw e;
      console.warn("sponsor relay unavailable, revealing liveness-only:", String(e));
      const rc = await chat(this.cfg.nearAiKey, request, { kind: lane.receiptKind, baseUrl: this.cfg.nearAiUrl });
      try {
        await this.near.call(this.cfg.registry, "record_run", {
          request: Buffer.from(rc.request).toString("base64"),
          response: Buffer.from(rc.response).toString("base64"),
          signer_id: lane.signerId,
          signature: rc.signature,
        });
      } catch (err) {
        // e.g. a relay billed the seat and withheld it: still reveal (no no-show); the audit attributes the gap
        console.warn("record_run (own key) failed, revealing liveness anyway:", String(err));
      }
      receipt = { request: toHex(rc.request), response: toHex(rc.response), signerId: lane.signerId, signature: rc.signature, sponsorId: 0, sponsorSig: "0x" };
      counted = false;
    }
    const { outcome, workerBps } = ruling(hexToBytes(receipt.response));
    const salt = keccak256(toHex(crypto.getRandomValues(new Uint8Array(32))));
    const h = commitment(cage, arbitration, taskId, c.round, this.me, c.inputHash, outcome, workerBps, salt);
    const digest = commitDigest(this.cfg.chainId, cage, arbitration, taskId, c.round, h);
    const sk = this.session();
    const sig = sk ? await sk.sign!({ hash: digest }) : await this.mpcSign(digest);
    await this.relay.send(cage, encodeFunctionData({ abi: cageAbi, functionName: "commitFor", args: [arbitration, taskId, this.me, h, sig] }));
    const p: Pending = { arbitration, taskId: taskId.toString(), round: c.round, outcome, workerBps, salt, receipt, counted };
    this.state.pending[id] = p;
    this.save();
    return p;
  }

  /** 4. reveal everything whose commit window has closed */
  async revealDue(): Promise<number> {
    let n = 0;
    const now = (await this.client.getBlock()).timestamp;
    for (const [id, p] of Object.entries(this.state.pending)) {
      const taskId = BigInt(p.taskId);
      const [commitEnd, revealEnd] = await this.client.readContract({ address: this.cfg.cage, abi: cageAbi, functionName: "windows", args: [p.arbitration, taskId] });
      if (now <= commitEnd) continue;
      if (now <= revealEnd) {
        const rc = p.receipt;
        await this.relay.send(this.cfg.cage, encodeFunctionData({
          abi: cageAbi, functionName: "reveal", args: [p.arbitration, taskId, this.me, p.outcome, p.workerBps, p.salt, rc],
        }));
        n++;
      }
      delete this.state.pending[id];
    }
    this.save();
    return n;
  }
}

// main loop (outline): watch DrawFulfilled(cage) for this.me -> serveSeat; revealDue every block; ensureTicket hourly;
// top up via ft_transfer_call {"topup":{}} when get_runner().budget < 2 USDC; exit = request_exit (2-day delay) +
// finish_exit + collect. e2e.ts runs exactly this sequence against local anvil + mocked NEAR / NEAR AI.
