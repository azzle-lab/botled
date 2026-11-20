// Canonical NEAR AI chat request: HEAD(lane) ‖ juror line ‖ USER(case) ‖ TAIL(lane).
// Byte-identical to test/near/NearFixtures.sol + BotledNearVerifier (vector checked in selftest.ts).
import { sha256 } from "@noble/hashes/sha2";
import { bytesToHex } from "@noble/hashes/utils";

const enc = new TextEncoder();

/** JsonText.escape: equals JSON.stringify's string body for valid UTF-8 */
export function escape(s: string): string {
  return JSON.stringify(s).slice(1, -1);
}

export function head(model: string, systemPrompt: string): string {
  return `{"model":"${model}","messages":[{"role":"system","content":"${escape(systemPrompt)}"},{"role":"user","content":"`;
}

export function tail(maxTokens: number, schemaCompact: string): string {
  return `"}],"temperature":0,"seed":0,"max_tokens":${maxTokens},"n":1,"stream":false,"response_format":{"type":"json_schema","json_schema":${schemaCompact}}}`;
}

/** escaped form already: ends with the two characters \ n */
export function jurorLine(runner: `0x${string}`, round: number, inputHash: `0x${string}`): string {
  return `botled juror ${runner.toLowerCase()} round ${round} case ${inputHash.toLowerCase()}\\n`;
}

export function userText(scope: string, poster: string, worker: string): string {
  return `<task_scope>\n${scope}\n</task_scope>\n<poster_evidence>\n${poster}\n</poster_evidence>\n<worker_evidence>\n${worker}\n</worker_evidence>\nReturn the JSON ruling now.`;
}

export type Lane = { model: string; maxTokens: number };

export function buildRequest(
  lane: Lane,
  systemPrompt: string,
  schemaCompact: string,
  runner: `0x${string}`,
  round: number,
  inputHash: `0x${string}`,
  docs: { scope: string; poster: string; worker: string },
): Uint8Array {
  return enc.encode(
    head(lane.model, systemPrompt) +
      jurorLine(runner, round, inputHash) +
      escape(userText(docs.scope, docs.poster, docs.worker)) +
      tail(lane.maxTokens, schemaCompact),
  );
}

export const sha256hex = (b: Uint8Array) => bytesToHex(sha256(b));
