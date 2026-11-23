// Vercel entry for sponsor relays A and B (one deployment, picked by hostname: relay-a.* / relay-b.*).
// Env per relay X in {A,B}: RELAY_X_SPONSOR_ID, RELAY_X_SPONSOR_PK, RELAY_X_NEAR_ACCOUNT, RELAY_X_NEAR_PK.
// Shared: NEAR_AI_API_KEY, UPSTASH_REDIS_REST_URL, UPSTASH_REDIS_REST_TOKEN, BOTLED_CAGE, BASE_RPC, NEAR_RPC.
import { privateKeyToAccount } from "viem/accounts";
import type { Hex } from "viem";
import { SponsorRelay, parseSeat } from "../relay.ts";
import { RedisSeatStore } from "../relay-redis.ts";
import { NearRpc } from "../near.ts";
import { baseClient } from "../loop.ts";
import { sha256hex } from "../request.ts";

const POOL = "0x4fE84CAe74039df848BEe0c7E7Dd9A4eAfaFf7EF" as Hex;
const NEAR_CONFIG = "0xAdb89C4fb606d346BA62F58C4B0e0F47c3e9F20a" as Hex;
const REGISTRY = "b0c3f8cbde21c8814baccfd84afce62f70ab33b57fe3717b01828ee41f06c625";
const relays = new Map<string, { relay: SponsorRelay; store: RedisSeatStore }>();

function relayFor(host: string) {
  const id = /^relay-([ab])\./.exec(host)?.[1]?.toUpperCase() ?? process.env.RELAY_DEFAULT;
  if (id !== "A" && id !== "B") throw Object.assign(new Error("unknown relay host"), { status: 404 });
  let r = relays.get(id);
  if (!r) {
    const e = process.env, p = `RELAY_${id}_`;
    const store = new RedisSeatStore(e.UPSTASH_REDIS_REST_URL!, e.UPSTASH_REDIS_REST_TOKEN!, `relay${id}`);
    const relay = new SponsorRelay({
      nearAiKey: e.NEAR_AI_API_KEY!,
      near: new NearRpc({ rpc: e.NEAR_RPC ?? "https://rpc.mainnet.near.org", accountId: e[p + "NEAR_ACCOUNT"]!, secretKey: e[p + "NEAR_PK"]! } as any),
      registry: REGISTRY,
      sponsor: privateKeyToAccount(e[p + "SPONSOR_PK"] as Hex),
      sponsorId: Number(e[p + "SPONSOR_ID"]),
      base: baseClient(e.BASE_RPC ?? "https://base-rpc.publicnode.com") as any,
      chainId: 8453n,
      nearConfig: NEAR_CONFIG,
      cage: e.BOTLED_CAGE as Hex,
      pool: POOL,
      store,
    });
    r = { relay, store };
    relays.set(id, r);
  }
  return r;
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "access-control-allow-origin": "*" } });

export async function handle(req: Request): Promise<Response> {
  try {
    const u = new URL(req.url);
    const { relay, store } = relayFor(req.headers.get("x-forwarded-host") ?? req.headers.get("host") ?? u.host);
    const path = u.pathname.replace(/\/+$/, "") || "/";
    if (req.method === "GET" && path === "/health") {
      const seats = await store.list();
      return json(200, { sponsorId: relay.cfg.sponsorId, sponsor: relay.cfg.sponsor.address, near: (relay.cfg.near as any).accountId, cage: relay.cfg.cage, seats: seats.length });
    }
    if (req.method === "GET" && path === "/seats") {
      const out = (await store.list()).map(([k, v]) => {
        const [runner, round, inputHash] = k.split(":");
        return { runner, round: Number(round), inputHash, requestSha256: `0x${sha256hex(Buffer.from(v.request.slice(2), "hex"))}`, responseSha256: `0x${sha256hex(Buffer.from(v.response.slice(2), "hex"))}`, sponsorId: v.sponsorId };
      });
      return json(200, out);
    }
    if (req.method !== "POST" || path !== "/run") return json(404, { error: "not found" });
    const b = await req.json();
    const request = new Uint8Array(Buffer.from(String(b.request), "base64"));
    parseSeat(request); // reject junk before touching chain/NEAR AI
    return json(200, await relay.run(b.arbitration, BigInt(b.taskId), request));
  } catch (e: any) {
    return json(e.status ?? 400, { error: String(e.message ?? e) });
  }
}
