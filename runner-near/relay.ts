// Botled sponsor relay: the ONLY path whose receipts count as votes.
//   * pays NEAR AI with Botled's key and bills the runner's NEAR budget (botled-registry.record_run, before co-signing)
//   * exactly ONE NEAR AI request per juror seat (runner, round, case): a repeat returns the cached receipt, never a
//     new sample -> a runner cannot resample until it likes the answer
//   * co-signs BotledNearConfig.sponsorDigest(runner, round, inputHash, sha256(request), sha256(response)); co-signing
//     two different runs for one seat is a public fraud proof (reportEquivocation retires the key at once)
// Trust: the relay can censor (refuse/delay a seat). Mitigations: the runner's own-key path still reveals (liveness:
// no no-show penalty, no reward), several sponsor keys may be configured, refusals are visible (record_run log vs.
// liveness-only reveals). See DESIGN.md "Sponsor relay".
import { createServer, type Server } from "node:http";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { toHex, type Hex, type LocalAccount, type PublicClient } from "viem";
import { chat, expectedText } from "./nearai.ts";
import { sponsorDigest } from "./digests.ts";
import { LANE_LIST, laneOfSeat, type LaneCfg } from "./lanes.ts";
import { cageAbi, poolAbi } from "./abi.ts";
import { sha256hex } from "./request.ts";
import type { Near } from "./loop.ts";

export type SponsoredReceipt = {
  request: Hex;
  response: Hex;
  signerId: number;
  signature: Hex;
  sponsorId: number;
  sponsorSig: Hex;
};

export type RelayConfig = {
  nearAiKey: string;
  nearAiUrl?: string;
  near: Near; // the relay's NEAR account (listed in registry settings.sponsors)
  registry: string;
  sponsor: LocalAccount; // ECDSA key registered as BotledNearConfig signer kind 3
  sponsorId: number;
  base: PublicClient;
  chainId: bigint;
  nearConfig: Hex;
  cage: Hex;
  pool: Hex;
  lanes?: LaneCfg[];
  storePath?: string; // persisted seat -> receipt map (survives restarts: still one run per seat)
  store?: SeatStore; // shared store for multi-instance hosting (serverless): replaces storePath + in-memory dedupe
};

/** Shared seat store. claim() must be atomic across instances (e.g. Redis SET NX): it is what keeps a seat at ONE
 *  NEAR AI run when several relay instances receive the same seat concurrently (two co-signed runs = fraud proof). */
export interface SeatStore {
  get(key: string): Promise<SponsoredReceipt | undefined>;
  claim(key: string, ttlSec: number): Promise<boolean>;
  put(key: string, rc: SponsoredReceipt): Promise<void>;
  release(key: string): Promise<void>;
  list(): Promise<[string, SponsoredReceipt][]>;
}

export class SeatBusy extends Error {
  status: number;
  constructor() { super("seat is being served right now; retry in a few seconds (same request returns the same receipt)"); this.status = 409; }
}

const JUROR = /botled juror (0x[0-9a-f]{40}) round (\d+) case (0x[0-9a-f]{64})\\n/g;

export function parseSeat(request: Uint8Array): { runner: Hex; round: number; inputHash: Hex; model: string; maxTokens: number } {
  const text = new TextDecoder().decode(request);
  const lines = [...text.matchAll(JUROR)];
  if (lines.length !== 1) throw new Error("request must carry exactly one juror line");
  const m = /^\{"model":"([^"]+)"/.exec(text);
  const mt = /"max_tokens":(\d+),/.exec(text);
  if (!m || !mt) throw new Error("not a canonical Botled request");
  return { runner: lines[0][1] as Hex, round: Number(lines[0][2]), inputHash: lines[0][3] as Hex, model: m[1], maxTokens: Number(mt[1]) };
}

export class SponsorRelay {
  readonly cfg: RelayConfig;
  private seats = new Map<string, SponsoredReceipt>();
  private inflight = new Map<string, Promise<SponsoredReceipt>>();
  requestsIssued = 0;

  constructor(cfg: RelayConfig) {
    this.cfg = cfg;
    if (cfg.storePath && existsSync(cfg.storePath)) {
      for (const [k, v] of Object.entries(JSON.parse(readFileSync(cfg.storePath, "utf8")))) this.seats.set(k, v as SponsoredReceipt);
    }
  }

  private persist() {
    if (this.cfg.storePath) writeFileSync(this.cfg.storePath, JSON.stringify(Object.fromEntries(this.seats)));
  }

  /** Idempotent per seat: the first call runs NEAR AI once; every later call returns the same receipt. */
  async run(arbitration: Hex, taskId: bigint, request: Uint8Array): Promise<SponsoredReceipt> {
    const s = parseSeat(request);
    const key = `${s.runner}:${s.round}:${s.inputHash}`;
    const st = this.cfg.store;
    if (st) {
      const done = await st.get(key);
      if (done) {
        if (done.request !== toHex(request)) throw new Error("seat already served with a different request (no resampling)");
        return done;
      }
      if (!(await st.claim(key, 600))) throw new SeatBusy();
      let rc: SponsoredReceipt;
      try {
        rc = await this.serve(arbitration, taskId, request, s);
      } catch (e) {
        await st.release(key); // nothing was co-signed: the seat may be tried again
        throw e;
      }
      await st.put(key, rc); // persisted BEFORE the receipt leaves the relay; the claim is never released after signing
      return rc;
    }
    const done = this.seats.get(key);
    if (done) {
      if (done.request !== toHex(request)) throw new Error("seat already served with a different request (no resampling)");
      return done;
    }
    const pending = this.inflight.get(key);
    if (pending) return pending;
    const p = this.serve(arbitration, taskId, request, s).finally(() => this.inflight.delete(key));
    this.inflight.set(key, p);
    const rc = await p;
    this.seats.set(key, rc);
    this.persist();
    return rc;
  }

  private async serve(arbitration: Hex, taskId: bigint, request: Uint8Array, s: ReturnType<typeof parseSeat>): Promise<SponsoredReceipt> {
    const { base, cage, pool } = this.cfg;
    const lanes = this.cfg.lanes ?? LANE_LIST;
    // the seat must be real and the lane must be the one the cage enforces for it
    const c = await base.readContract({ address: cage, abi: cageAbi, functionName: "getCase", args: [arbitration, taskId] });
    if (c.round !== s.round || c.inputHash.toLowerCase() !== s.inputHash) throw new Error("juror line does not match the open case");
    const drawId = await base.readContract({ address: cage, abi: cageAbi, functionName: "drawId", args: [arbitration, taskId, c.round] });
    const seat = await base.readContract({ address: pool, abi: poolAbi, functionName: "seat", args: [cage, drawId, s.runner] });
    const lane = lanes[laneOfSeat(seat, lanes.length)];
    if (s.model !== lane.model || s.maxTokens !== lane.maxTokens) throw new Error(`seat ${seat} is lane ${lane.model}`);

    this.requestsIssued++;
    const rc = await chat(this.cfg.nearAiKey, request, { kind: lane.receiptKind, baseUrl: this.cfg.nearAiUrl });
    if (rc.text !== expectedText(lane.receiptKind, lane.model, request, rc.response)) throw new Error("receipt text");
    // bill first (public audit trail of every sponsored run), then co-sign
    await this.cfg.near.call(this.cfg.registry, "record_run", {
      request: Buffer.from(rc.request).toString("base64"),
      response: Buffer.from(rc.response).toString("base64"),
      signer_id: lane.signerId,
      signature: rc.signature,
    });
    const digest = sponsorDigest(
      this.cfg.chainId, this.cfg.nearConfig, s.runner, s.round, s.inputHash,
      `0x${sha256hex(rc.request)}`, `0x${sha256hex(rc.response)}`,
    );
    const sponsorSig = await this.cfg.sponsor.sign!({ hash: digest });
    return { request: toHex(rc.request), response: toHex(rc.response), signerId: lane.signerId, signature: rc.signature, sponsorId: this.cfg.sponsorId, sponsorSig };
  }

  /** POST /run {arbitration, taskId, request: base64} -> SponsoredReceipt */
  listen(port: number): Promise<Server> {
    const srv = createServer(async (req, res) => {
      try {
        if (req.method === "GET" && req.url === "/health") {
          return void res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ sponsorId: this.cfg.sponsorId, sponsor: this.cfg.sponsor.address, seats: this.seats.size, issued: this.requestsIssued }));
        }
        if (req.method === "GET" && req.url === "/seats") {
          // public: what this relay served (hashes only) -> cross-check with NEAR get_runs and Base reveals
          const out = [...this.seats].map(([k, v]) => {
            const [runner, round, inputHash] = k.split(":");
            return { runner, round: Number(round), inputHash, requestSha256: `0x${sha256hex(Buffer.from(v.request.slice(2), "hex"))}`, responseSha256: `0x${sha256hex(Buffer.from(v.response.slice(2), "hex"))}`, sponsorId: v.sponsorId };
          });
          return void res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(out));
        }
        if (req.method !== "POST" || req.url !== "/run") throw Object.assign(new Error("not found"), { status: 404 });
        const chunks: Buffer[] = [];
        for await (const ch of req) chunks.push(ch as Buffer);
        const b = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        const out = await this.run(b.arbitration, BigInt(b.taskId), new Uint8Array(Buffer.from(b.request, "base64")));
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(out));
      } catch (e: any) {
        res.writeHead(e.status ?? 400, { "content-type": "application/json" }).end(JSON.stringify({ error: String(e.message ?? e) }));
      }
    });
    return new Promise((ok) => srv.listen(port, "127.0.0.1", () => ok(srv)));
  }
}

/** Runner side: ask the relay to run + co-sign this seat's request. */
export async function requestSponsored(url: string, arbitration: Hex, taskId: bigint, request: Uint8Array): Promise<SponsoredReceipt> {
  const res = await fetch(`${url}/run`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ arbitration, taskId: taskId.toString(), request: Buffer.from(request).toString("base64") }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`relay ${res.status}: ${body.error}`);
  return body as SponsoredReceipt;
}
