/**
 * Cage operator CLI: create | fund | join | leave | withdraw
 * create deploys a v5 cage. fund approves the shortfall of 1,000 + 10,000 AZL.
 * join calls seat and sends the pfand. leave calls exit. withdraw pulls both bonds after the cooldown.
 * v5 factory must be set (deployments or V5_FACTORY). Nothing here is sent unless BOTLED_SEND=1.
 */
import { keccak256, toHex, type Address, type Hex } from "viem";
import { randomBytes } from "node:crypto";
import {
  CAGE_V5, ERC20, FACTORY, PANEL_OWNER, VAULT, clients, deployments, env, loadAccount, makeLogger, sender,
} from "./botled-node-lib.ts";

const { pub, transport } = clients();
const log = makeLogger();
const send = sender(pub, transport, log);
const dep = deployments();

function account() {
  const a = loadAccount("CAGE_KEY_FILE", "CAGE_PK");
  if (!a) throw new Error("set CAGE_KEY_FILE or CAGE_PK");
  return a;
}

function assertSend() {
  if (env("BOTLED_SEND") !== "1") throw new Error("BOTLED_SEND is not 1");
  const host = new URL(env("RPC_URLS", env("RPC_URL", "https://mainnet.base.org"))!.split(",")[0].trim()).hostname;
  if (host !== "127.0.0.1" && host !== "localhost" && env("MAINNET_OK") !== "1") {
    throw new Error("refusing mainnet sends without MAINNET_OK=1");
  }
}

function factory(): Address {
  if (!dep.v5.factory) throw new Error("v5 factory is not deployed");
  return dep.v5.factory;
}

function cageAddr(): Address {
  const c = env("CAGE");
  if (!c) throw new Error("set CAGE");
  return c as Address;
}

const UNIT = 10n ** 18n;

export async function create() {
  assertSend();
  const me = account();
  const salt = (env("SALT") as Hex | undefined) ?? keccak256(toHex(randomBytes(32)));
  const predicted = await pub.readContract({
    address: factory(), abi: FACTORY, functionName: "predictCage", args: [me.address, salt],
  });
  await send(me, factory(), FACTORY, "deployCage", [0, salt]);
  log("cage.created", { cage: predicted, operator: me.address, salt });
  console.log(predicted);
  return predicted;
}

export async function fund() {
  assertSend();
  const me = account();
  const cage = cageAddr();
  const need = 11_000n * UNIT;
  const bal = await pub.readContract({ address: dep.azl, abi: ERC20, functionName: "balanceOf", args: [me.address] });
  if (bal < need) throw new Error("need 11000 AZL");
  const allowance = await pub.readContract({ address: dep.azl, abi: ERC20, functionName: "allowance", args: [me.address, cage] });
  if (allowance < need) await send(me, dep.azl, ERC20, "approve", [cage, need]);
  log("cage.funded", { cage, allowance: need });
}

export async function join() {
  assertSend();
  const me = account();
  const cage = cageAddr();
  const op = await pub.readContract({ address: cage, abi: CAGE_V5, functionName: "operator" });
  if (op.toLowerCase() !== me.address.toLowerCase()) throw new Error("not the operator");
  const pfand = await pub.readContract({ address: dep.panelOwner, abi: PANEL_OWNER, functionName: "pfand" });
  const eth = await pub.getBalance({ address: me.address });
  if (eth < pfand) throw new Error("ETH below pfand");
  await send(me, cage, CAGE_V5, "seat", [1_000n * UNIT, 10_000n * UNIT], pfand);
  log("cage.seated", { cage, pfand });
}

export async function leave() {
  assertSend();
  const me = account();
  const cage = cageAddr();
  await send(me, cage, CAGE_V5, "exit", []);
  log("cage.exit", { cage });
}

export async function withdraw() {
  assertSend();
  const me = account();
  const cage = cageAddr();
  for (const m of [0, 1] as const) {
    const vault = m === 0 ? dep.modules.micro.vault : dep.modules.standard.vault;
    const bond = await pub.readContract({ address: vault, abi: VAULT, functionName: "bonds", args: [cage] });
    if (bond === 0n) continue;
    await send(me, cage, CAGE_V5, "withdrawBond", [m, 0]);
  }
  log("cage.withdrawn", { cage });
}

const cmd = process.argv[2];
const invoked = process.argv[1]?.replace(/\\/g, "/").endsWith("cage-cli.ts");
if (invoked) {
  const run = cmd === "create" ? create : cmd === "fund" ? fund : cmd === "join" ? join : cmd === "leave" ? leave : cmd === "withdraw" ? withdraw : null;
  if (!run) { console.error("usage: cage-cli.ts create|fund|join|leave|withdraw"); process.exit(1); }
  run().catch((err) => { console.error(String(err).slice(0, 500)); process.exit(1); });
}
