// In-memory NEAR for e2e: v1.signer (Chain Signatures) with deterministic local test keys per (account, path), and a
// botled-registry stand-in implementing the calls runner-near and the sponsor relay make. The real registry logic is
// tested in near/botled-registry (unit) and near/sandbox-tests (neard sandbox).
import { keccak256, recoverMessageAddress, toBytes, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { Near } from "../loop.ts";
import { ENROLL_PATH } from "../chainsig.ts";
import { enrollDigest, nearAccountHash } from "../digests.ts";
import { parseSeat } from "../relay.ts";

export class MockMpc {
  key(account: string, path: string) {
    return privateKeyToAccount(keccak256(toBytes(`mock-mpc:${account},${path}`)));
  }
  async sign(account: string, path: string, digest: Hex) {
    const sig = await this.key(account, path).sign!({ hash: digest });
    const v = parseInt(sig.slice(130, 132), 16);
    return { big_r: { affine_point: `0${v === 27 ? 2 : 3}${sig.slice(2, 66)}` }, s: { scalar: sig.slice(66, 130) }, recovery_id: v - 27 };
  }
}

type RunnerRec = { base: Hex; epoch: number; budget: number; runs: number };

export class MockRegistry {
  readonly id: string;
  readonly mpc: MockMpc;
  readonly chainId: bigint;
  pool: Hex; // set once the local deployment exists
  readonly signers: { address: Hex; kind: 1 | 2; model?: string }[];
  readonly sponsors: string[];
  readonly runners = new Map<string, RunnerRec>();
  readonly receipts = new Set<string>();
  readonly seats = new Map<string, number>();
  readonly log: string[] = [];
  readonly runLog: any[] = [];
  constructor(o: { id: string; mpc: MockMpc; chainId: bigint; pool: Hex; signers: MockRegistry["signers"]; sponsors: string[] }) {
    this.id = o.id; this.mpc = o.mpc; this.chainId = o.chainId; this.pool = o.pool; this.signers = o.signers; this.sponsors = o.sponsors;
  }
  enrollSigner(): Hex { return this.mpc.key(this.id, ENROLL_PATH).address; }
  signupMessage(account: string, base: string) { return `botled signup ${account} ${base.toLowerCase()}`; }

  async handle(caller: string, method: string, a: any): Promise<any> {
    switch (method) {
      case "signup_message": return this.signupMessage(a.account, a.base);
      case "run_count": return this.runLog.length;
      case "get_runs": return this.runLog.slice(Number(a.from), Number(a.from) + Math.min(Number(a.limit), 200));
      case "ft_on_transfer": {
        const m = JSON.parse(a.msg);
        if (m.signup) {
          const who = await recoverMessageAddress({ message: this.signupMessage(a.sender_id, m.signup.base), signature: m.signup.sig });
          if (who.toLowerCase() !== m.signup.base.toLowerCase()) throw new Error("signup sig");
          this.runners.set(a.sender_id, { base: m.signup.base, epoch: 0, budget: Number(a.amount) - 10_000_000, runs: 0 });
        }
        return "0";
      }
      case "request_ticket": {
        const r = this.runners.get(caller);
        if (!r) throw new Error("unknown runner");
        r.epoch++;
        const t = {
          runner: r.base, nearAccount: nearAccountHash(caller), epoch: r.epoch, noShowsCovered: Number(a.no_shows_covered),
          validUntil: BigInt(Math.floor(Date.now() / 1000) + 7 * 86_400 + 10 * 86_400), sessionKey: a.session_key as Hex,
        };
        const digest = enrollDigest(this.chainId, this.pool, t);
        const mpc = await this.mpc.sign(this.id, ENROLL_PATH, digest);
        return { ...t, validUntil: Number(t.validUntil), digest, mpc };
      }
      case "record_run": {
        const rq = new Uint8Array(Buffer.from(a.request, "base64"));
        const rs = new Uint8Array(Buffer.from(a.response, "base64"));
        const s = this.signers[a.signer_id];
        if (!s) throw new Error("signer");
        const seat = parseSeat(rq);
        if (s.kind === 2 && s.model !== seat.model) throw new Error("tee key is for another model");
        const { sha256hex } = await import("../request.ts");
        const core = `${sha256hex(rq)}:${sha256hex(rs)}`;
        const text = s.kind === 2 ? `${seat.model}:${core}` : core;
        if ((await recoverMessageAddress({ message: text, signature: a.signature })).toLowerCase() !== s.address.toLowerCase()) throw new Error("receipt sig");
        if (this.receipts.has(core)) throw new Error("receipt already billed");
        const account = [...this.runners].find(([, r]) => r.base.toLowerCase() === seat.runner)?.[0];
        if (!account) throw new Error("unknown runner");
        const key = `${seat.runner}:${seat.round}:${seat.inputHash}`;
        const n = this.seats.get(key) ?? 0;
        if (n >= 1) throw new Error("seat already billed (max_runs_per_seat)");
        if (!this.sponsors.includes(caller) && caller !== account) throw new Error("caller");
        this.receipts.add(core);
        this.seats.set(key, n + 1);
        this.runners.get(account)!.runs++;
        this.log.push(`botled:run ${account} by ${caller} model ${seat.model}`);
        this.runLog.push({
          index: this.runLog.length, runner: seat.runner, account, round: seat.round, case: seat.inputHash,
          request_sha256: sha256hex(rq), response_sha256: sha256hex(rs), signer_id: a.signer_id, model: seat.model,
          caller, sponsored: this.sponsors.includes(caller), charged: "0", at: Math.floor(Date.now() / 1000),
        });
        return { runner: account };
      }
    }
    throw new Error(`mock registry: ${method}`);
  }
}

export class MockNearAccount implements Near {
  readonly accountId: string;
  private reg: MockRegistry;
  private mpc: MockMpc;
  private mpcId: string;
  constructor(accountId: string, reg: MockRegistry, mpc: MockMpc, mpcId = "v1.signer") {
    this.accountId = accountId; this.reg = reg; this.mpc = mpc; this.mpcId = mpcId;
  }
  baseAddress(path: string): Hex { return this.mpc.key(this.accountId, path).address; }
  async view<T>(contract: string, method: string, args: object): Promise<T> {
    if (contract !== this.reg.id) throw new Error("view " + contract);
    return this.reg.handle(this.accountId, method, args);
  }
  async call<T>(contract: string, method: string, args: any): Promise<T> {
    if (contract === this.mpcId && method === "sign") {
      return (await this.mpc.sign(this.accountId, args.request.path, `0x${args.request.payload_v2.Ecdsa}`)) as T;
    }
    if (method === "ft_transfer_call") { // USDC stand-in -> registry.ft_on_transfer
      return this.reg.handle(contract, "ft_on_transfer", { sender_id: this.accountId, amount: args.amount, msg: args.msg });
    }
    if (contract !== this.reg.id) throw new Error("call " + contract);
    return this.reg.handle(this.accountId, method, args);
  }
}
