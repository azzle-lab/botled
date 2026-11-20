import { encodeTx, signTx, parseSecret, base58Encode, parseOutcome } from "./near.ts";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { derivePublicKey, addressOf, deriveBaseAddress, nearSecpKey, MAINNET_ROOT, mpcToEvm, ENROLL_PATH, base58Decode } from "./chainsig.ts";
import { buildRequest, escape, sha256hex } from "./request.ts";
import { ruling, expectedText } from "./nearai.ts";
import { LANES, VECTOR_CASE, laneOfSeat } from "./lanes.ts";
import { enrollDigest, nearAccountHash, sponsorDigest } from "./digests.ts";
import { parseSeat } from "./relay.ts";

// 1. Chain Signatures: v1.signer.derived_public_key({predecessor:"alice.near", path:"base-1", domain_id:0})
const want = nearSecpKey("secp256k1:4A7pNQBPPvvW1NZZXqSa4XJzgzmMNyvaqAzHMkNQ4rED853s3awLaVT7vMmBDq58vkUnZBjoay38x2wknvjLXAXN");
const got = derivePublicKey(MAINNET_ROOT, "alice.near", "base-1");
assert.deepEqual(got, want);
assert.equal(addressOf(got), "0x2460d5036abb5d4352eb3f098e9b97f2547c2473"); // same as botled-logic chainsig test
console.log("ok chain-sig derivation alice.near/base-1 ->", deriveBaseAddress("alice.near"));
console.log("   registry.botled.near enrollSigner would be", deriveBaseAddress("registry.botled.near", ENROLL_PATH));

// 2. request bytes == Solidity (test/near/BotledV5Near.t.sol::testRequestVector), both production lanes
const sys = readFileSync(new URL("../test/near-vectors/system_prompt.txt", import.meta.url), "utf8");
const schema = readFileSync(new URL("../test/near-vectors/schema.compact.json", import.meta.url), "utf8");
const V = VECTOR_CASE;
for (const [lane, len, sha] of [
  [LANES.kimi, 2561, "67e0b21aed2cee111052982e72e15bc95c66968d72b2d1096332c779eeb8715f"],
  [LANES.deepseek, 2579, "f88f96f5058e92396722386df5deca3991056c483b15301c05ec2e48103dd640"],
] as const) {
  const req = buildRequest(lane, sys, schema, V.runner, V.round, V.inputHash, V.docs);
  assert.equal(req.length, len);
  assert.equal(sha256hex(req), sha);
  const seat = parseSeat(req);
  assert.deepEqual([seat.runner, seat.round, seat.inputHash, seat.model, seat.maxTokens], [V.runner, 1, V.inputHash, lane.model, lane.maxTokens]);
  console.log(`ok request bytes match Solidity vector: ${lane.model} max_tokens ${lane.maxTokens} (${len} B)`);
}
assert.deepEqual([1, 2, 3, 4].map((s) => laneOfSeat(s)), [0, 1, 0, 1]);
console.log("ok seat -> lane (kimi, deepseek, kimi, ...)");

// 2b. digests == Solidity / Rust vectors
assert.equal(
  enrollDigest(8453n, "0x3381cD18e2Fb4dB236BF0525938AB6E43Db0440f", {
    runner: V.runner, nearAccount: nearAccountHash("runner.botled.near"), epoch: 7, noShowsCovered: 2, validUntil: 1_800_000_000n,
    sessionKey: "0x3333333333333333333333333333333333333333",
  }),
  "0xd7c5202aabe0341239ada4030c90c8f5b3668447490ed2cb528f551a153aa8c1",
);
console.log("ok enroll digest (with session key) == pool.enrollDigest == botled_logic::ticket::enroll_digest");
assert.equal(
  sponsorDigest(8453n, "0x13aa49bAc059d709dd0a18D6bb63290076a702D7", V.runner, 1, V.inputHash, `0x${"00".repeat(31)}aa`, `0x${"00".repeat(31)}bb`),
  "0x1e3b46b006fbf28d5c77a961e54291be9f9bf43ace82bfdb91ea791abce704ad",
);
console.log("ok sponsor digest == BotledNearConfig.sponsorDigest == botled_logic::ticket::sponsor_digest");

// 3. escaper edge cases (JsonText.escape rules)
assert.equal(escape('a"b\\c\n\t\r\b\f\x01\x7f/é\u2028'), 'a\\"b\\\\c\\n\\t\\r\\b\\f\\u0001\x7f/é\u2028');
console.log("ok escaper");

// 4. MPC signature -> EVM 65 bytes
const evm = mpcToEvm({ big_r: { affine_point: "03" + "ab".repeat(32) }, s: { scalar: "cd".repeat(32) }, recovery_id: 1 });
assert.equal(evm, `0x${"ab".repeat(32)}${"cd".repeat(32)}1c`);
console.log("ok mpc -> evm signature");

// 5. ruling extraction
const resp = new TextEncoder().encode(JSON.stringify({ choices: [{ message: { content: '{"outcome":"SPLIT","workerBps":6500,"reason":"x"}' } }] }));
assert.deepEqual(ruling(resp), { outcome: 3, workerBps: 6500 });
console.log("ok ruling");

// 6. signed texts: gateway vs provider_tee
const a = new TextEncoder().encode("a"), b = new TextEncoder().encode("b");
assert.equal(expectedText(1, LANES.kimi.model, a, b), `${sha256hex(a)}:${sha256hex(b)}`);
assert.equal(expectedText(2, LANES.deepseek.model, a, b), `${LANES.deepseek.model}:${sha256hex(a)}:${sha256hex(b)}`);
console.log("ok receipt texts");

// 7. NEAR transaction encoding/signing == near-api-js 7.5.3 (vector generated with its createTransaction/encodeTransaction,
//    public test seed 0x01..0x20; NOT a real key)
{
  const k = parseSecret("ed25519:2Ana1pUpv2ZbMVkwF5FXapYeBEjdxDatLn7nvJkhgTSdZd8hbDHTd21as7EAsg7ypityqfsw2pMQKJcVDVcAEsd");
  const tx = {
    signerId: "runner.testnet", publicKey: k.publicKey, nonce: 7n, receiverId: "v1.signer-prod.testnet",
    blockHash: base58Decode("244ZQ9cgj3CQ6bWBdytfrJMuMQ1jdXLFGnr4HhvtCTnM"),
    actions: [{ methodName: "sign", args: new TextEncoder().encode('{"a":1}'), gas: 50n * 10n ** 12n, deposit: 1n }],
  };
  assert.equal(Buffer.from(encodeTx(tx)).toString("hex"), "0e00000072756e6e65722e746573746e65740079b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad04966407000000000000001600000076312e7369676e65722d70726f642e746573746e65740fa473fd26901df296be6adc4cc4df34d040efa2435224b6986910e630c2fef60100000002040000007369676e070000007b2261223a317d00203d88792d000001000000000000000000000000000000");
  assert.equal(Buffer.from(signTx(tx, k.seed).signed).toString("hex"), "0e00000072756e6e65722e746573746e65740079b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad04966407000000000000001600000076312e7369676e65722d70726f642e746573746e65740fa473fd26901df296be6adc4cc4df34d040efa2435224b6986910e630c2fef60100000002040000007369676e070000007b2261223a317d00203d88792d0000010000000000000000000000000000000018100c0d12c791200273889ca135b767cbca8229f92597b3c3f4cbae88816494f8daf924d10a396b35fbb25927f821331e0640fe100fd995c38e5066fd697b08");
  assert.equal(base58Encode(base58Decode("244ZQ9cgj3CQ6bWBdytfrJMuMQ1jdXLFGnr4HhvtCTnM")), "244ZQ9cgj3CQ6bWBdytfrJMuMQ1jdXLFGnr4HhvtCTnM");
  assert.deepEqual(parseOutcome({ status: { SuccessValue: Buffer.from('{"x":1}').toString("base64") }, receipts_outcome: [] }), { x: 1 });
  assert.throws(() => parseOutcome({ status: { SuccessValue: "" }, receipts_outcome: [{ outcome: { status: { Failure: {} } } }] }));
  console.log("ok NEAR tx borsh + ed25519 signature == near-api-js");
}
