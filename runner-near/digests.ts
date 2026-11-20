// Off-chain mirrors of the on-chain digests (vectors checked in selftest.ts against Solidity + Rust).
import { encodeAbiParameters, hashMessage, hashTypedData, keccak256, toBytes, type Hex } from "viem";

export const SPONSOR_TYPEHASH = keccak256(
  toBytes("SponsoredRun(address runner,uint8 round,bytes32 inputHash,bytes32 requestSha256,bytes32 responseSha256)"),
);

/** BotledNearConfig.sponsorDigest: EIP-191 over keccak(abi.encode(typehash, chainid, nearConfig, runner, round, ih, rq, rs)) */
export function sponsorDigest(chainId: bigint, nearConfig: Hex, runner: Hex, round: number, inputHash: Hex, rq: Hex, rs: Hex): Hex {
  const inner = keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "uint256" }, { type: "address" }, { type: "address" }, { type: "uint8" }, { type: "bytes32" }, { type: "bytes32" }, { type: "bytes32" }],
      [SPONSOR_TYPEHASH, chainId, nearConfig, runner, round, inputHash, rq, rs],
    ),
  );
  return hashMessage({ raw: inner });
}

/** BotledCageV5Near commitment (no lane: the cage derives it from the seat) */
export function commitment(cage: Hex, arbitration: Hex, taskId: bigint, round: number, runner: Hex, inputHash: Hex, outcome: number, workerBps: number, salt: Hex): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "address" }, { type: "uint256" }, { type: "uint8" }, { type: "address" }, { type: "bytes32" }, { type: "uint8" }, { type: "uint16" }, { type: "bytes32" }],
      [cage, arbitration, taskId, round, runner, inputHash, outcome, workerBps, salt],
    ),
  );
}

/** BotledRunnerPoolNear.enrollDigest (EIP-712, domain BotledRunnerPoolNear/1) */
export function enrollDigest(chainId: bigint, pool: Hex, t: { runner: Hex; nearAccount: Hex; epoch: number; noShowsCovered: number; validUntil: bigint; sessionKey: Hex }): Hex {
  return hashTypedData({
    domain: { name: "BotledRunnerPoolNear", version: "1", chainId, verifyingContract: pool },
    types: {
      Enroll: [
        { name: "runner", type: "address" },
        { name: "nearAccount", type: "bytes32" },
        { name: "epoch", type: "uint32" },
        { name: "noShowsCovered", type: "uint32" },
        { name: "validUntil", type: "uint64" },
        { name: "sessionKey", type: "address" },
      ],
    },
    primaryType: "Enroll",
    message: t,
  });
}

/** BotledNearVerifier.commitDigest (EIP-712, domain BotledCageV5Near/1, verifyingContract = cage) */
export function commitDigest(chainId: bigint, cage: Hex, arbitration: Hex, taskId: bigint, round: number, c: Hex): Hex {
  return hashTypedData({
    domain: { name: "BotledCageV5Near", version: "1", chainId, verifyingContract: cage },
    types: {
      Commit: [
        { name: "arbitration", type: "address" },
        { name: "taskId", type: "uint256" },
        { name: "round", type: "uint8" },
        { name: "commitment", type: "bytes32" },
      ],
    },
    primaryType: "Commit",
    message: { arbitration, taskId, round, commitment: c },
  });
}

export const nearAccountHash = (account: string): Hex => keccak256(toBytes(account));
