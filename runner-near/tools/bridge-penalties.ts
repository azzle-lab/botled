// Keeper: no-show penalties (USDC owed to settings.penalty_to on the NEAR registry) -> Base BotledRewardSwapper.
//   node --experimental-strip-types tools/bridge-penalties.ts            DRY (default): dry 1Click quote, local checks
//   BOTLED_SEND=1 NEAR_ACCOUNT_ID=.. NEAR_PRIVATE_KEY=.. node ... tools/bridge-penalties.ts   real quote + bridge_penalties
// env: REGISTRY (NEAR account), NEAR_RPC, or OFFLINE_SETTINGS=<json file> + OFFLINE_OWED=<usdc units> for a dry run
//      before the registry exists. The registry re-checks everything on-chain (botled_logic::oneclick::bind); the
//      keeper holds no funds and cannot change recipient, assets, refund target or size.
import { ed25519 } from "@noble/curves/ed25519";
import { sha256 } from "@noble/hashes/sha256";
import { readFileSync } from "node:fs";
import { NearRpc, base58Encode } from "../near.ts";
import { base58Decode } from "../chainsig.ts";

const ONE_CLICK = process.env.ONE_CLICK_URL ?? "https://1click.chaindefuser.com";
const send = process.env.BOTLED_SEND === "1";

type Bridge = { manager_key: string; origin_asset: string; destination_asset: string; recipient: string; max_slippage_bps: number; min_amount: number | string };
let settings: { penalty_to: string; reward_bridge: Bridge | null };
let owed: bigint;
let near: NearRpc | undefined;
const registry = process.env.REGISTRY;
if (process.env.OFFLINE_SETTINGS) {
  settings = JSON.parse(readFileSync(process.env.OFFLINE_SETTINGS, "utf8"));
  owed = BigInt(process.env.OFFLINE_OWED ?? "0");
} else {
  if (!registry) throw new Error("set REGISTRY");
  near = send ? NearRpc.fromEnv() : new NearRpc({ rpc: process.env.NEAR_RPC ?? "https://rpc.mainnet.near.org", accountId: "keeper.readonly" });
  settings = await near.view(registry, "get_settings", {});
  owed = BigInt(await near.view<string>(registry, "owed_to", { account: settings.penalty_to }));
}
const b = settings.reward_bridge;
if (!b) throw new Error("registry has no reward_bridge configured");
console.log(`owed penalties ${Number(owed) / 1e6} USDC (min batch ${Number(b.min_amount) / 1e6})`);
if (owed < BigInt(b.min_amount)) { console.log("below min batch: nothing to do"); process.exit(0); }

// ask 1Click for half the on-chain cap: its minAmountOut is taken after fees, the cap is measured against amountIn
const slip = Math.max(1, Math.floor(b.max_slippage_bps / 2));
const deadline = new Date(Date.now() + 30 * 60_000).toISOString();
const req = {
  dry: !send, swapType: "EXACT_INPUT", slippageTolerance: slip, originAsset: b.origin_asset, depositType: "ORIGIN_CHAIN",
  destinationAsset: b.destination_asset, amount: owed.toString(), refundTo: settings.penalty_to, refundType: "ORIGIN_CHAIN",
  recipient: b.recipient, recipientType: "DESTINATION_CHAIN", deadline,
};
const res = await fetch(`${ONE_CLICK}/v0/quote`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(req) });
const q: any = await res.json();
if (!res.ok) throw new Error(`1Click ${res.status}: ${q.message}`);

// local mirror of the on-chain binding (fail fast; the registry enforces the same rules)
const amountIn = BigInt(q.quote.amountIn), minOut = BigInt(q.quote.minAmountOut);
const checks = {
  amountIn_eq_owed: amountIn === owed,
  slippage_within_cap: minOut * 10_000n >= amountIn * BigInt(10_000 - b.max_slippage_bps),
  recipient: q.quoteRequest.recipient.toLowerCase() === b.recipient.toLowerCase(),
  refundTo: q.quoteRequest.refundTo === settings.penalty_to,
  assets: q.quoteRequest.originAsset === b.origin_asset && q.quoteRequest.destinationAsset === b.destination_asset,
};
console.log(JSON.stringify({ mode: send ? "SEND" : "DRY", amountIn: q.quote.amountIn, amountOut: q.quote.amountOut, minAmountOut: q.quote.minAmountOut, fees: { withdraw: q.quote.withdrawFee, refund: q.quote.refundFee }, checks }, null, 1));
if (!Object.values(checks).every(Boolean)) throw new Error("quote violates the bridge bounds");
if (!send) { console.log("DRY: would call bridge_penalties with the signed dry:false quote"); process.exit(0); }

// signed payload: canonical sorted JSON of quote + request + timestamp (format of 1Click-signed quotes, see
// near/botled-logic/testdata/oneclick-live-quote.json). Verified locally against the pinned key before sending.
const sorted = (o: any) => Object.fromEntries(Object.entries(o).sort(([x], [y]) => (x < y ? -1 : 1)));
const payload = JSON.stringify(sorted({ ...q.quoteRequest, ...q.quote, timestamp: q.timestamp }));
const msg = new TextEncoder().encode(base58Encode(sha256(new TextEncoder().encode(payload))));
if (!ed25519.verify(base58Decode(q.signature.slice(8)), msg, base58Decode(b.manager_key))) {
  throw new Error("could not reconstruct the exact signed payload; not sending (1Click payload format changed?)");
}
const out = await near!.call(registry!, "bridge_penalties", { payload, signature: q.signature }, { gasTgas: 100 });
console.log("bridge_penalties ->", out, "deposit", q.quote.depositAddress);
