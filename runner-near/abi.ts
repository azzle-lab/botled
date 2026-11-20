import { parseAbi } from "viem";

export const poolAbi = parseAbi([
  "function runners(address) view returns (bool listed, uint32 activeCases, uint32 noShows, uint32 noShowsCovered, uint32 epoch, uint64 validUntil, bytes32 nearAccount, address sessionKey)",
  "function enroll(address runner, bytes32 nearAccount, uint32 epoch, uint32 noShowsCovered, uint64 validUntil, address sessionKey, bytes sig)",
  "function enrollDigest(address runner, bytes32 nearAccount, uint32 epoch, uint32 noShowsCovered, uint64 validUntil, address sessionKey) view returns (bytes32)",
  "function seat(address cage, uint256 drawId, address runner) view returns (uint8)",
  "function drawnRunners(address cage, uint256 drawId) view returns (address[])",
  "function rewards(address) view returns (uint256)",
  "event DrawRequested(address indexed cage, uint256 indexed drawId, uint256 requestId, uint256 pricePaid)",
  "event DrawFulfilled(address indexed cage, bytes32 indexed key, address[] runners)",
]);

export const caseTuple =
  "(uint8 phase,uint8 round,bool hasResult,uint32 paramsId,uint64 deadline,uint64 hardStop,bytes32 inputHash,bytes32 result,address poster,address worker)";
export const receiptTuple = "(bytes request,bytes response,uint32 signerId,bytes signature,uint32 sponsorId,bytes sponsorSig)";

export const cageAbi = parseAbi([
  `function getCase(address,uint256) view returns (${caseTuple})`,
  "function evidence(bytes32) view returns (bytes32 posterEv, bytes32 workerEv, bytes32 scopeHash, bytes32 userHash, uint32 userLen, uint64 boundAt)",
  "function caseKey(address,uint256) pure returns (bytes32)",
  "function drawId(address,uint256,uint8) view returns (uint256)",
  "function laneCount() view returns (uint8)",
  "function openCase(address,uint256) payable",
  "function bindEvidence(address,uint256,bytes,bytes,bytes)",
  "function commitFor(address,uint256,address,bytes32,bytes)",
  `function reveal(address,uint256,address,uint8,uint16,bytes32,${receiptTuple})`,
  "function closeRound(address,uint256)",
  "function finalize(address,uint256)",
  "function windows(address,uint256) view returns (uint256 commitEnd, uint256 revealEnd)",
  "event Revealed(address indexed arbitration, uint256 indexed taskId, uint8 round, address indexed runner, uint8 outcome, uint16 workerBps, uint8 lane, bytes32 requestHash, bytes32 responseHash, uint32 signerId, uint32 sponsorId, bool counted)",
  "event CaseOpened(address indexed arbitration, uint256 indexed taskId, uint32 constitutionId, uint32 paramsId, bytes32 inputHash, uint64 hardStop)",
  "event RoundStarted(address indexed arbitration, uint256 indexed taskId, uint8 round, uint8 jurors, address appellant, uint256 bond, bool drawRequested)",
  "event CageRuled(address indexed arbitration, uint256 indexed taskId, uint8 outcome, uint16 workerBps, uint8 round)",
]);

export const verifierAbi = parseAbi([
  "function commitDigest(address,address,uint256,uint8,bytes32) view returns (bytes32)",
]);
export const nearConfigAbi = parseAbi([
  "function sponsorDigest(address runner, uint8 round, bytes32 inputHash, bytes32 requestSha256, bytes32 responseSha256) view returns (bytes32)",
]);
