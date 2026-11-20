// NEAR TESTNET end-to-end of the real Chain Signatures paths (free faucet accounts, no real money):
//   1. creates two faucet accounts (registry + runner) via helper.testnet.near.org (keys in runner-near/.testnet/, 0600)
//   2. deploys near/target/near/botled_registry/botled_registry.wasm (near/build-wasm.sh) with mpc = v1.signer-prod.testnet;
//      USDC stand-in = the runner account itself (it calls ft_on_transfer directly; no token is moved)
//   3. runner signup: the signup message is signed by v1.signer-prod.testnet for the runner's derived Base address
//   4. runner.request_ticket -> registry -> v1.signer-prod.testnet.sign -> on_ticket
//   5. checks: ticket signature recovers to the address derived from the TESTNET MPC root for (registry, ENROLL_PATH),
//      i.e. what BotledNearConfig.enrollSigner would be set to; signup signature recovers to the runner's Base address.
//   node --experimental-strip-types tools/testnet-ticket.ts
import { ed25519 } from "@noble/curves/ed25519";
import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync } from "node:fs";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { hashMessage, recoverAddress, type Hex } from "viem";
import { NearRpc, base58Encode } from "../near.ts";
import { deriveBaseAddress, mpcToEvm, signArgs, TESTNET_ROOT, TESTNET_SIGNER, ENROLL_PATH, BASE_PATH, type MpcSignature } from "../chainsig.ts";

const RPC = process.env.NEAR_RPC ?? "https://rpc.testnet.near.org";
const dir = new URL("../.testnet/", import.meta.url).pathname;
const root = new URL("../../", import.meta.url).pathname;
mkdirSync(dir, { recursive: true });

function account(role: string): { id: string; secret: string } {
  const f = join(dir, `${role}.json`);
  if (existsSync(f)) return JSON.parse(readFileSync(f, "utf8"));
  const seed = ed25519.utils.randomPrivateKey();
  const pub = ed25519.getPublicKey(seed);
  const id = `botled-${role}-${Buffer.from(seed.slice(0, 4)).toString("hex")}.testnet`;
  const a = { id, secret: `ed25519:${base58Encode(new Uint8Array([...seed, ...pub]))}`, publicKey: `ed25519:${base58Encode(pub)}` };
  writeFileSync(f, JSON.stringify(a));
  chmodSync(f, 0o600);
  return a;
}

async function ensureFunded(a: { id: string; secret: string }) {
  const probe = new NearRpc({ rpc: RPC, accountId: a.id });
  try {
    await probe.rpcCall("query", { request_type: "view_account", finality: "final", account_id: a.id });
    return;
  } catch {}
  const pub = JSON.parse(readFileSync(join(dir, `${a.id.split("-")[1]}.json`), "utf8")).publicKey;
  const r = await fetch("https://helper.testnet.near.org/account", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ newAccountId: a.id, newAccountPublicKey: pub }),
  });
  if (!r.ok) throw new Error(`faucet ${r.status}: ${await r.text()}`);
  for (let i = 0; i < 30; i++) {
    try { await probe.rpcCall("query", { request_type: "view_account", finality: "final", account_id: a.id }); return; } catch {}
    await new Promise((ok) => setTimeout(ok, 2000));
  }
  throw new Error("account did not appear");
}

const regA = account("reg"), runA = account("run");
await ensureFunded(regA);
await ensureFunded(runA);
const reg = new NearRpc({ rpc: RPC, accountId: regA.id, secretKey: regA.secret, mpcRoot: TESTNET_ROOT });
const run = new NearRpc({ rpc: RPC, accountId: runA.id, secretKey: runA.secret, mpcRoot: TESTNET_ROOT });
const bal = async (id: string) => (await reg.rpcCall("query", { request_type: "view_account", finality: "final", account_id: id })).amount;
console.log("accounts", regA.id, runA.id, "balances (yocto)", await bal(regA.id), await bal(runA.id));

// deploy (once)
const code = (await reg.rpcCall("query", { request_type: "view_account", finality: "final", account_id: regA.id })).code_hash;
if (code === "11111111111111111111111111111111") {
  const wasm = readFileSync(join(root, "near/target/near/botled_registry/botled_registry.wasm"));
  const settings = execFileSync("cargo", ["run", "-q", "-p", "botled-logic", "--example", "settings_json", "--",
    runA.id, regA.id, regA.id, regA.id, regA.id, "0x3333333333333333333333333333333333333333", "84532",
    "0xb98a789cdc4817275f5155593ba73ef2a957e779"], { cwd: join(root, "near"), encoding: "utf8" }).trim();
  await reg.deploy(new Uint8Array(wasm), "new", { owner: regA.id, timelock_secs: 86_400, mpc: TESTNET_SIGNER, settings: JSON.parse(settings), mpc_root: null }, 100);
  console.log("deployed registry wasm", wasm.length, "bytes");
}

// signup: runner's Base identity = its Chain Signatures address on testnet
const base = deriveBaseAddress(runA.id, BASE_PATH, TESTNET_ROOT);
const existing = await reg.view<any>(regA.id, "get_runner", { account: runA.id });
if (!existing) {
  const msg = await reg.view<string>(regA.id, "signup_message", { account: runA.id, base });
  const sig = mpcToEvm(await run.call<MpcSignature>(TESTNET_SIGNER, "sign", signArgs(hashMessage(msg), BASE_PATH), { deposit: 1n, gasTgas: 50 }));
  const who = await recoverAddress({ hash: hashMessage(msg), signature: sig });
  if (who.toLowerCase() !== base.toLowerCase()) throw new Error(`MPC signup signature recovers to ${who}, expected ${base}`);
  console.log("v1.signer-prod.testnet signed signup for derived base", base, "OK");
  // USDC stand-in: the runner account is `settings.usdc`, so it may call the NEP-141 receiver directly
  await run.call(regA.id, "ft_on_transfer", { sender_id: runA.id, amount: "20000000", msg: JSON.stringify({ signup: { base, sig } }) }, { gasTgas: 50 });
}
console.log("runner", await reg.view(regA.id, "get_runner", { account: runA.id }));

// ticket through the REAL MPC
const session = "0x5e55100000000000000000000000000000000001";
const t = await run.call<any>(regA.id, "request_ticket", { no_shows_covered: 0, session_key: session }, { deposit: 1n, gasTgas: 150 });
const signer = await recoverAddress({ hash: t.digest as Hex, signature: mpcToEvm(t.mpc) });
const expected = deriveBaseAddress(regA.id, ENROLL_PATH, TESTNET_ROOT);
console.log(JSON.stringify({ ticket: { ...t, mpc: "(MPC signature)" }, recovered: signer, enrollSigner: expected }, null, 1));
if (signer.toLowerCase() !== expected.toLowerCase()) throw new Error("ticket signer != derived enroll signer");
console.log("OK: real v1.signer-prod.testnet ticket recovers to the derived enrollSigner");
