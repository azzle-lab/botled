// NEAR AI Cloud: exact-bytes chat call + receipt fetch.
// Gateway keys sign `${sha256(request)}:${sha256(response)}`; a model's own TEE key (provider_tee) signs
// `${model}:${sha256(request)}:${sha256(response)}`. Use the canonical model id with x-no-aliasing, stream:false and
// Accept-Encoding: identity so the bytes we hash are the bytes it hashed.
import { sha256hex } from "./request.ts";

export const NEAR_AI = process.env.NEAR_AI_URL ?? "https://cloud-api.near.ai/v1";

export type Receipt = {
  request: Uint8Array;
  response: Uint8Array;
  chatId: string;
  text: string;
  signature: `0x${string}`;
  signingAddress: string;
  algo: "ecdsa" | "ed25519";
};

export function expectedText(kind: 1 | 2, model: string, request: Uint8Array, response: Uint8Array): string {
  const core = `${sha256hex(request)}:${sha256hex(response)}`;
  return kind === 2 ? `${model}:${core}` : core;
}

export async function chat(
  apiKey: string,
  request: Uint8Array,
  opts: { kind?: 1 | 2; algo?: "ecdsa" | "ed25519"; baseUrl?: string } = {},
): Promise<Receipt> {
  const { kind = 1, algo = "ecdsa", baseUrl = NEAR_AI } = opts;
  const res = await fetch(`${baseUrl}/chat/completions`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
      "accept-encoding": "identity",
      "x-no-aliasing": "true",
    },
    body: Buffer.from(request),
  });
  if (!res.ok) throw new Error(`NEAR AI ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const response = new Uint8Array(await res.arrayBuffer());
  const { id, model } = JSON.parse(new TextDecoder().decode(response));
  const sigRes = await fetch(
    `${baseUrl}/signature/${encodeURIComponent(id)}?model=${encodeURIComponent(model)}&signing_algo=${algo}`,
    { headers: { authorization: `Bearer ${apiKey}` } },
  );
  if (!sigRes.ok) throw new Error(`signature ${sigRes.status}`);
  const s = (await sigRes.json()) as { text: string; signature: string; signing_address: string };
  const want = expectedText(kind, model, request, response);
  if (s.text !== want) throw new Error(`receipt text mismatch: got ${s.text}, want ${want} (gateway re-encoded bytes?)`);
  const sig = (s.signature.startsWith("0x") ? s.signature : `0x${s.signature}`) as `0x${string}`;
  return { request, response, chatId: id, text: s.text, signature: sig, signingAddress: s.signing_address, algo };
}

/** RulingParser equivalent: choices[0].message.content -> {outcome, workerBps} */
export const OUTCOMES = { POSTER_WINS: 1, WORKER_WINS: 2, SPLIT: 3, MUTUAL: 4 } as const;
export function ruling(response: Uint8Array): { outcome: number; workerBps: number } {
  const content = JSON.parse(new TextDecoder().decode(response)).choices[0].message.content;
  const r = JSON.parse(content);
  const outcome = OUTCOMES[r.outcome as keyof typeof OUTCOMES];
  if (!outcome || !Number.isInteger(r.workerBps) || r.workerBps < 0 || r.workerBps > 10_000) throw new Error("ruling");
  return { outcome, workerBps: r.workerBps };
}
