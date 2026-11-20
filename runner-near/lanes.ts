import type { Lane } from "./request.ts";

/// Production lanes (BotledNearConfig template 0). The cage fixes each seat's lane: lane = (seat - 1) % 2, seat from
/// BotledRunnerPoolNear.seat (1-based VRF draw order). max_tokens is sized for reasoning models: NEAR AI counts
/// reasoning_content in completion tokens; the JSON ruling itself is < 200 tokens.
///   receiptKind 1 = NEAR AI gateway key (kimi-k3), 2 = the model's own TEE key, provider_tee text (DeepSeek).
///   signerId = BotledNearConfig signer slot used on Base and in botled-registry (per-lane key, from config).
export type LaneCfg = Lane & { receiptKind: 1 | 2; signerId: number };

export const LANES = {
  kimi: { model: "moonshotai/kimi-k3", maxTokens: 6000, receiptKind: 1, signerId: Number(process.env.BOTLED_KIMI_SIGNER ?? 0) },
  deepseek: {
    model: "deepseek-ai/DeepSeek-V4.1-Flash-1017",
    maxTokens: 8000,
    receiptKind: 2,
    signerId: Number(process.env.BOTLED_DEEPSEEK_SIGNER ?? 2),
  },
} satisfies Record<string, LaneCfg>;
export const LANE_LIST: LaneCfg[] = [LANES.kimi, LANES.deepseek];

export const laneOfSeat = (seat: number, laneCount = LANE_LIST.length) => {
  if (seat < 1) throw new Error("not drawn");
  return (seat - 1) % laneCount;
};

/// Fixed case used for the real-receipt test vectors (test/near-vectors/real, mirrored in Solidity + Rust tests).
export const VECTOR_CASE = {
  runner: "0x1111111111111111111111111111111111111111" as `0x${string}`,
  round: 1,
  inputHash: `0x${"22".repeat(32)}` as `0x${string}`,
  docs: {
    scope: "Build /refund.",
    poster: "Poster: delivery misses the /refund endpoint that the scope requires.",
    worker: "Worker: commit 9f2c implements /refund; see tests/refund.spec.ts (41/41 green).\nDeadline met.",
  },
};
