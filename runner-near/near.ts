// Production NEAR client for runner-near / the sponsor relay: plain JSON-RPC + ed25519 transaction signing.
// No SDK dependency: the transaction is Borsh-encoded here (cross-checked against near-api-js in selftest.ts) and
// signed with @noble/curves. Implements the `Near` interface the loop and relay use (mock/near.ts is the test double).
//
//   const near = NearRpc.fromEnv();          // NEAR_RPC, NEAR_ACCOUNT_ID, NEAR_PRIVATE_KEY or ~/.near-credentials
//   await near.view("registry.botled.near", "get_settings", {});
//   await near.call("v1.signer", "sign", signArgs(digest, "base-1"), { deposit: 1n, gasTgas: 50 });
//
// Keys: the private key is read once into memory and never logged. Use a FunctionCall access key restricted to the
// registry where possible (the v1.signer call needs a deposit, so the runner's sign path needs a full-access key or
// a dedicated account).
import { ed25519 } from "@noble/curves/ed25519";
import { sha256 } from "@noble/hashes/sha256";
import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Hex } from "viem";
import { base58Decode, deriveBaseAddress, MAINNET_ROOT } from "./chainsig.ts";
import type { Near } from "./loop.ts";

const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
export function base58Encode(b: Uint8Array): string {
  let n = 0n;
  for (const x of b) n = (n << 8n) | BigInt(x);
  let s = "";
  while (n > 0n) { s = B58[Number(n % 58n)] + s; n /= 58n; }
  for (const x of b) { if (x !== 0) break; s = "1" + s; }
  return s;
}

// ---------------------------------------------------------------- Borsh (just what a FunctionCall tx needs)
class W {
  private b: number[] = [];
  u8(x: number) { this.b.push(x & 0xff); return this; }
  u32(x: number) { for (let i = 0; i < 4; i++) this.b.push((x >>> (8 * i)) & 0xff); return this; }
  u64(x: bigint) { for (let i = 0n; i < 8n; i++) this.b.push(Number((x >> (8n * i)) & 0xffn)); return this; }
  u128(x: bigint) { for (let i = 0n; i < 16n; i++) this.b.push(Number((x >> (8n * i)) & 0xffn)); return this; }
  fixed(x: Uint8Array) { for (const y of x) this.b.push(y); return this; }
  bytes(x: Uint8Array) { return this.u32(x.length).fixed(x); }
  str(s: string) { return this.bytes(new TextEncoder().encode(s)); }
  out() { return new Uint8Array(this.b); }
}

export type FunctionCall = { methodName: string; args: Uint8Array; gas: bigint; deposit: bigint };
export type DeployContract = { code: Uint8Array };
export type Action = FunctionCall | DeployContract;
export type Tx = { signerId: string; publicKey: Uint8Array; nonce: bigint; receiverId: string; blockHash: Uint8Array; actions: Action[] };

/** Borsh(Transaction V0): Action enum 1 = DeployContract, 2 = FunctionCall; PublicKey/Signature key type 0 = ED25519. */
export function encodeTx(t: Tx): Uint8Array {
  const w = new W().str(t.signerId).u8(0).fixed(t.publicKey).u64(t.nonce).str(t.receiverId).fixed(t.blockHash).u32(t.actions.length);
  for (const a of t.actions) {
    if ("code" in a) w.u8(1).bytes(a.code);
    else w.u8(2).str(a.methodName).bytes(a.args).u64(a.gas).u128(a.deposit);
  }
  return w.out();
}

export function signTx(t: Tx, secret32: Uint8Array): { signed: Uint8Array; hash: Uint8Array } {
  const body = encodeTx(t);
  const hash = sha256(body);
  const sig = ed25519.sign(hash, secret32);
  return { signed: new Uint8Array([...body, 0, ...sig]), hash };
}

/** "ed25519:<base58 of 64-byte secret||public>" (near-cli format) -> 32-byte seed */
export function parseSecret(s: string): { seed: Uint8Array; publicKey: Uint8Array } {
  if (!s.startsWith("ed25519:")) throw new Error("only ed25519 NEAR keys are supported");
  const raw = base58Decode(s.slice(8));
  const seed = raw.slice(0, 32);
  const publicKey = ed25519.getPublicKey(seed);
  if (raw.length === 64 && !raw.slice(32).every((x, i) => x === publicKey[i])) throw new Error("key pair mismatch");
  return { seed, publicKey };
}

export class NearRpcError extends Error {
  readonly data?: unknown;
  constructor(msg: string, data?: unknown) { super(msg); this.data = data; }
}

export class NearRpc implements Near {
  readonly accountId: string;
  readonly rpc: string;
  readonly mpcRoot: string;
  #seed?: Uint8Array;
  #pub?: Uint8Array;
  #id = 0;

  constructor(o: { rpc: string; accountId: string; secretKey?: string; mpcRoot?: string }) {
    this.rpc = o.rpc;
    this.accountId = o.accountId;
    this.mpcRoot = o.mpcRoot ?? MAINNET_ROOT;
    if (o.secretKey) {
      const k = parseSecret(o.secretKey);
      this.#seed = k.seed;
      this.#pub = k.publicKey;
    }
  }

  /** NEAR_RPC (default mainnet), NEAR_ACCOUNT_ID, NEAR_PRIVATE_KEY or ~/.near-credentials/<NEAR_NETWORK>/<account>.json */
  static fromEnv(env = process.env): NearRpc {
    const network = env.NEAR_NETWORK ?? "mainnet";
    const rpc = env.NEAR_RPC ?? (network === "testnet" ? "https://rpc.testnet.near.org" : "https://rpc.mainnet.near.org");
    const accountId = env.NEAR_ACCOUNT_ID;
    if (!accountId) throw new Error("set NEAR_ACCOUNT_ID");
    let secretKey = env.NEAR_PRIVATE_KEY;
    const f = join(homedir(), ".near-credentials", network, `${accountId}.json`);
    if (!secretKey && existsSync(f)) secretKey = JSON.parse(readFileSync(f, "utf8")).private_key;
    return new NearRpc({ rpc, accountId, secretKey, mpcRoot: env.NEAR_MPC_ROOT });
  }

  get publicKey(): string | undefined {
    return this.#pub ? `ed25519:${base58Encode(this.#pub)}` : undefined;
  }

  baseAddress(path: string): Hex {
    return deriveBaseAddress(this.accountId, path, this.mpcRoot);
  }

  async rpcCall<T = any>(method: string, params: unknown): Promise<T> {
    for (let attempt = 0; ; attempt++) {
      const res = await fetch(this.rpc, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: ++this.#id, method, params }),
      });
      if (res.status === 429 || res.status >= 500) {
        if (attempt < 4) { await new Promise((r) => setTimeout(r, 500 * 2 ** attempt)); continue; }
      }
      const j: any = await res.json();
      if (j.error) throw new NearRpcError(`${method}: ${j.error.cause?.name ?? j.error.name}: ${JSON.stringify(j.error.data ?? j.error.message)}`, j.error);
      return j.result as T;
    }
  }

  async view<T>(contract: string, method: string, args: object): Promise<T> {
    const r = await this.rpcCall("query", {
      request_type: "call_function", finality: "final", account_id: contract, method_name: method,
      args_base64: Buffer.from(JSON.stringify(args)).toString("base64"),
    });
    if (r.error) throw new NearRpcError(`view ${contract}.${method}: ${r.error}`);
    return JSON.parse(Buffer.from(r.result).toString("utf8")) as T;
  }

  /** Signs and sends one FunctionCall; waits until all receipts executed (EXECUTED_OPTIMISTIC); returns the JSON result. */
  async call<T>(contract: string, method: string, args: object, opts: { deposit?: bigint; gasTgas?: number } = {}): Promise<T> {
    const fc: FunctionCall = {
      methodName: method, args: new TextEncoder().encode(JSON.stringify(args)),
      gas: BigInt(opts.gasTgas ?? 100) * 10n ** 12n, deposit: opts.deposit ?? 0n,
    };
    return this.send<T>(contract, [fc]);
  }

  /** Deploys `code` to this account and calls the init method in the same transaction. */
  async deploy<T>(code: Uint8Array, init: string, args: object, gasTgas = 100): Promise<T> {
    return this.send<T>(this.accountId, [
      { code },
      { methodName: init, args: new TextEncoder().encode(JSON.stringify(args)), gas: BigInt(gasTgas) * 10n ** 12n, deposit: 0n },
    ]);
  }

  async send<T>(receiverId: string, actions: Action[]): Promise<T> {
    if (!this.#seed || !this.#pub) throw new Error("NearRpc: no signing key (read-only client)");
    const pk = `ed25519:${base58Encode(this.#pub)}`;
    const ak = await this.rpcCall("query", { request_type: "view_access_key", finality: "final", account_id: this.accountId, public_key: pk });
    if (ak.permission !== "FullAccess") {
      const p = ak.permission?.FunctionCall;
      const bad = actions.some((a) => "code" in a || a.deposit > 0n || (p.method_names.length && !p.method_names.includes(a.methodName)));
      if (!p || p.receiver_id !== receiverId || bad) throw new Error(`access key cannot send this transaction to ${receiverId}`);
    }
    const tx: Tx = {
      signerId: this.accountId, publicKey: this.#pub, nonce: BigInt(ak.nonce) + 1n, receiverId,
      blockHash: base58Decode(ak.block_hash), actions,
    };
    const { signed } = signTx(tx, this.#seed);
    const out = await this.rpcCall("send_tx", { signed_tx_base64: Buffer.from(signed).toString("base64"), wait_until: "EXECUTED_OPTIMISTIC" });
    return parseOutcome<T>(out);
  }
}

export function parseOutcome<T>(out: any): T {
  const st = out.status ?? out.final_execution_status_detail;
  if (st?.Failure) throw new NearRpcError(`tx failed: ${JSON.stringify(st.Failure)}`, st.Failure);
  for (const r of out.receipts_outcome ?? []) {
    const f = r.outcome?.status?.Failure;
    if (f) throw new NearRpcError(`receipt failed: ${JSON.stringify(f)}`, f);
  }
  const v = st?.SuccessValue;
  if (v === undefined) throw new NearRpcError(`unexpected outcome ${JSON.stringify(st)}`);
  if (v === "") return undefined as T;
  const s = Buffer.from(v, "base64").toString("utf8");
  try { return JSON.parse(s) as T; } catch { return s as unknown as T; }
}
