// Live verification of NEAR AI's attestation for every signing key Botled pins on-chain.
//
//   node --experimental-strip-types tools/verify-attestation.ts [--pins attestation-pins.json] [--out dir]
//
// For each pinned key (gateway + provider-TEE, ecdsa + ed25519) it fetches a FRESH report with a random 32-byte nonce
// (free endpoint, no API key) and then:
//   1. runs tools/attest (Rust, dcap-qvl): Intel TDX DCAP quote verification against Intel's SGX root CA, TCB status,
//      report_data = key || nonce, MRTD/RTMRs = tcb_info, RTMR3 event-log replay, compose-hash = sha256(app_compose),
//      and the compose-manager quote (same TD, report_data = sha256(action log) || nonce);
//   2. for model reports, NVIDIA GPU evidence: POSTs nvidia_payload to NVIDIA NRAS, verifies the overall EAT JWT and
//      every per-GPU JWT (ES384) against NVIDIA's JWKS, checks each x5c chain, the per-GPU digests, the overall
//      result and that eat_nonce is OUR nonce;
//   3. compares the attested keys with the pins (= what BotledNearConfig holds).
// Exit code 0 only if all checks pass. Prints one JSON summary.
import { createPublicKey, verify as cverify, createHash, randomBytes, X509Certificate } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const opt = (k: string, d: string) => (argv.includes(k) ? argv[argv.indexOf(k) + 1] : d);
const pinsPath = resolve(opt("--pins", join(here, "..", "attestation-pins.json")));
const outDir = resolve(opt("--out", "/tmp/botled-attest"));
const bin = resolve(opt("--bin", join(here, "..", "..", "tools", "attest", "target", "release", "botled-attest")));
const API = "https://cloud-api.near.ai/v1/attestation/report";
const NRAS = "https://nras.attestation.nvidia.com/v3/attest/gpu";
const JWKS = "https://nras.attestation.nvidia.com/.well-known/jwks.json";
mkdirSync(outDir, { recursive: true });

const pins = JSON.parse(readFileSync(pinsPath, "utf8"));
const b64u = (s: string) => Buffer.from(s, "base64url");

let jwksCache: any[] | undefined;
async function jwks(): Promise<any[]> {
  if (!jwksCache) jwksCache = (await (await fetch(JWKS)).json()).keys;
  return jwksCache!;
}

/** Verifies an NRAS JWT: ES384 signature under the JWKS key with matching kid, that key's x5c chain, exp. */
async function verifyJwt(jwt: string): Promise<{ claims: any; root: string }> {
  const [h, p, s] = jwt.split(".");
  const header = JSON.parse(b64u(h).toString());
  if (header.alg !== "ES384") throw new Error(`unexpected alg ${header.alg}`);
  const k = (await jwks()).find((x) => x.kid === header.kid);
  if (!k) throw new Error(`kid ${header.kid} not in NVIDIA JWKS`);
  const certs = (k.x5c as string[]).map((c) => new X509Certificate(Buffer.from(c, "base64")));
  for (let i = 0; i + 1 < certs.length; i++) {
    if (!certs[i].verify(certs[i + 1].publicKey)) throw new Error("x5c chain broken");
  }
  const root = certs[certs.length - 1];
  // The JWKS chain tops out at an NVIDIA CA; its fingerprint is pinned (trust-on-first-use) in attestation-pins.json.
  const leafKey = createPublicKey({ key: { kty: k.kty, crv: k.crv, x: k.x, y: k.y }, format: "jwk" });
  if (!leafKey.equals(certs[0].publicKey)) throw new Error("JWK != x5c leaf key");
  const ok = cverify("sha384", Buffer.from(`${h}.${p}`), { key: leafKey, dsaEncoding: "ieee-p1363" }, b64u(s));
  if (!ok) throw new Error("JWT signature invalid");
  const claims = JSON.parse(b64u(p).toString());
  if (claims.exp && claims.exp * 1000 < Date.now()) throw new Error("JWT expired");
  return { claims, root: `${root.issuer.replace(/\n/g, ", ")} sha256=${root.fingerprint256}` };
}

async function nvidia(payload: any, nonce: string) {
  const p = typeof payload === "string" ? JSON.parse(payload) : payload;
  if (p.nonce !== nonce) throw new Error("nvidia_payload nonce != our nonce");
  const r = await fetch(NRAS, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(p) });
  if (!r.ok) throw new Error(`NRAS HTTP ${r.status}`);
  const res = await r.json();
  const overall = await verifyJwt(res[0][1]);
  const c = overall.claims;
  if (c["x-nvidia-overall-att-result"] !== true) throw new Error("NVIDIA overall attestation result false");
  if (c.eat_nonce !== nonce) throw new Error("eat_nonce != our nonce");
  const gpus = Object.keys(c.submods);
  for (const g of gpus) {
    const jwt: string = res[1][g];
    const d = createHash("sha256").update(jwt).digest("hex");
    if (c.submods[g][1][1] !== d) throw new Error(`${g} digest mismatch`);
    const gc = (await verifyJwt(jwt)).claims;
    if (gc["x-nvidia-gpu-attestation-report-nonce-match"] === false || gc.measres !== "success")
      throw new Error(`${g}: nonce-match=${gc["x-nvidia-gpu-attestation-report-nonce-match"]} measres=${gc.measres}`);
  }
  return { arch: p.arch, gpus: gpus.length, overall: true, eat_nonce_ok: true, nvidia_chain: overall.root };
}

async function one(target: string, algo: "ecdsa" | "ed25519", expect: string) {
  const nonce = randomBytes(32).toString("hex");
  const q = new URLSearchParams({ signing_algo: algo, nonce });
  if (target !== "gateway") q.set("model", target);
  const res = await fetch(`${API}?${q}`);
  if (!res.ok) throw new Error(`report HTTP ${res.status}`);
  const body = await res.text();
  const file = join(outDir, `${target.replace(/\W+/g, "_")}.${algo}.json`);
  writeFileSync(file, body);
  const args = [file, "--model", target, "--nonce", nonce, algo === "ecdsa" ? "--expect-ecdsa" : "--expect-ed25519", expect];
  let tdx: any;
  try {
    tdx = JSON.parse(execFileSync(bin, args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
  } catch (e: any) {
    throw new Error(`TDX check failed: ${(e.stderr || e.message).toString().trim()}`);
  }
  const out: any = {
    target, algo, nonce, key: tdx.attested_key, matches_pin: tdx.matches_configured, tcb: tdx.tcb_status,
    compose_hash: tdx.compose_hash, mrtd: tdx.mrtd,
  };
  if (tdx.compose_manager) {
    out.compose_manager = {
      tcb: tdx.compose_manager.tcb_status,
      model_file: tdx.compose_manager.last_compose_up?.file,
      file_sha256: tdx.compose_manager.last_compose_up?.file_sha256,
      commit: tdx.compose_manager.last_compose_up?.commit,
      variant_services_in_same_td: tdx.compose_manager.variant_services_in_same_td,
    };
  }
  if (target !== "gateway") {
    const m = JSON.parse(body).model_attestations.find((x: any) => x.model_name === target);
    out.nvidia = await nvidia(m.nvidia_payload, nonce);
  }
  if (!tdx.matches_configured) throw Object.assign(new Error("attested key != pinned key"), { out });
  return out;
}

const jobs: [string, "ecdsa" | "ed25519", string][] = [];
for (const a of ["ecdsa", "ed25519"] as const) if (pins.gateway?.[a]) jobs.push(["gateway", a, pins.gateway[a]]);
for (const [model, keys] of Object.entries<any>(pins.models ?? {}))
  for (const a of ["ecdsa", "ed25519"] as const) if (keys[a]) jobs.push([model, a, keys[a]]);

const results: any[] = [];
let fail = 0;
for (const [t, a, k] of jobs) {
  try {
    results.push({ ok: true, ...(await one(t, a, k)) });
  } catch (e: any) {
    fail++;
    results.push({ ok: false, target: t, algo: a, error: e.message, ...(e.out ?? {}) });
  }
}
const roots = new Set(results.map((r) => r.nvidia?.nvidia_chain).filter(Boolean));
if (pins.nvidiaRootSha256) for (const r of roots) if (!String(r).includes(pins.nvidiaRootSha256)) { fail++; results.push({ ok: false, error: `NVIDIA chain top ${r} != pinned` }); }
console.log(JSON.stringify({ ok: fail === 0, checked: jobs.length, failed: fail, results }, null, 2));
process.exit(fail ? 1 : 0);
