// Gets one REAL NEAR AI receipt for a lane, in the exact canonical Botled request layout, and stores it as a test vector.
// Usage: NEAR_AI_API_KEY=... node --experimental-strip-types tools/fetch-real-receipt.ts <kimi|deepseek>
// The key is read from the environment and never printed or written.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { buildRequest, sha256hex } from "../request.ts";
import { LANES, VECTOR_CASE } from "../lanes.ts";

const which = process.argv[2] as keyof typeof LANES;
const lane = LANES[which];
if (!lane) throw new Error("lane: kimi | deepseek");
const key = process.env.NEAR_AI_API_KEY;
if (!key) throw new Error("NEAR_AI_API_KEY missing");
const API = "https://cloud-api.near.ai/v1";
const root = new URL("../../test/near-vectors/", import.meta.url);
const sys = readFileSync(new URL("system_prompt.txt", root), "utf8");
const schema = readFileSync(new URL("schema.compact.json", root), "utf8");
const request = buildRequest(lane, sys, schema, VECTOR_CASE.runner, VECTOR_CASE.round, VECTOR_CASE.inputHash, VECTOR_CASE.docs);

const res = await fetch(`${API}/chat/completions`, {
  method: "POST",
  headers: { authorization: `Bearer ${key}`, "content-type": "application/json", "accept-encoding": "identity", "x-no-aliasing": "true" },
  body: Buffer.from(request),
});
const response = new Uint8Array(await res.arrayBuffer());
if (!res.ok) {
  console.error("chat failed", res.status, new TextDecoder().decode(response).slice(0, 600));
  process.exit(1);
}
const body = JSON.parse(new TextDecoder().decode(response));
console.log("chat ok", body.id, body.model, JSON.stringify(body.usage));
console.log("content:", body.choices?.[0]?.message?.content?.slice(0, 300));

const out: any = { lane: which, model: lane.model, maxTokens: lane.maxTokens, chatId: body.id, usage: body.usage,
  requestSha256: sha256hex(request), responseSha256: sha256hex(response), signatures: {} };
for (const algo of ["ecdsa", "ed25519"]) {
  const r = await fetch(`${API}/signature/${encodeURIComponent(body.id)}?model=${encodeURIComponent(lane.model)}&signing_algo=${algo}`, {
    headers: { authorization: `Bearer ${key}` },
  });
  const t = await r.text();
  if (!r.ok) { console.log(`signature ${algo}: HTTP ${r.status} ${t.slice(0, 200)}`); continue; }
  const s = JSON.parse(t);
  out.signatures[algo] = s;
  console.log(`signature ${algo}:`, JSON.stringify({ ...s, signature: String(s.signature).slice(0, 18) + "…" }));
}
const want = `${out.requestSha256}:${out.responseSha256}`;
for (const [algo, s] of Object.entries<any>(out.signatures)) {
  console.log(`${algo} text matches local hashes:`, s.text === want || String(s.text).endsWith(":" + want) ? "yes" : `NO (${s.text})`);
}
const dir = new URL("real/", root);
mkdirSync(dir, { recursive: true });
writeFileSync(new URL(`${which}.request.json`, dir), request);
writeFileSync(new URL(`${which}.response.json`, dir), response);
writeFileSync(new URL(`${which}.receipt.json`, dir), JSON.stringify(out, null, 2));
console.log("saved", which);
