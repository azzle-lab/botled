// End-to-end: runner-near loop + sponsor relay against a LOCAL anvil chain (chain id 31337) with the real contracts
// (script/DeployLocalNear.s.sol) and mocked NEAR (Chain Signatures + registry) and NEAR AI. All keys are public test
// keys (anvil defaults + keccak labels). Nothing leaves 127.0.0.1.
//   npm run e2e
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { mkdirSync, readFileSync, rmSync } from "node:fs";
import assert from "node:assert/strict";
import {
  createPublicClient, createTestClient, createWalletClient, decodeEventLog, http, keccak256, parseAbi, toBytes, toHex,
  type Hex, type TransactionReceipt,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";
import { MockMpc, MockNearAccount, MockRegistry } from "./mock/near.ts";
import { MockNearAi } from "./mock/nearai.ts";
import { SponsorRelay } from "./relay.ts";
import { Runner, type RunnerConfig } from "./loop.ts";
import { LANES, type LaneCfg } from "./lanes.ts";
import { cageAbi, poolAbi } from "./abi.ts";
import { audit } from "./audit.ts";
import { buildRequest } from "./request.ts";

const RPC_PORT = 8546, AI_PORT = 8547, RELAY_PORT = 8548, RELAY_B_PORT = 8549;
const rpc = `http://127.0.0.1:${RPC_PORT}`;
const root = new URL("..", import.meta.url).pathname;
const dir = new URL("e2e/", import.meta.url).pathname;
const label = (s: string) => privateKeyToAccount(keccak256(toBytes(`botled-e2e:${s}`)));
// anvil's well-known dev keys (public)
const DEPLOYER_PK = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const KEEPER_PK = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";

const POSTER_DOC = "Poster: delivery misses the /refund endpoint that the scope requires.";
const WORKER_DOC = "Worker: commit 9f2c implements /refund; see tests/refund.spec.ts (41/41 green).\nDeadline met.";
const docs = { scope: "", poster: POSTER_DOC, worker: WORKER_DOC };

async function waitRpc() {
  for (let i = 0; i < 100; i++) {
    try {
      const r = await fetch(rpc, { method: "POST", headers: { "content-type": "application/json" }, body: '{"jsonrpc":"2.0","id":1,"method":"eth_chainId"}' });
      if (r.ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("anvil did not start");
}

const step = (s: string) => console.log(`\n== ${s}`);
let anvil: ChildProcess | undefined;
const servers: { close(): void }[] = [];

async function main() {
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  const gateway = label("gateway"), tee = label("deepseek-tee"), sponsor = label("sponsor"), sponsorB = label("sponsor-b");
  const mpc = new MockMpc();
  const registry = new MockRegistry({
    id: "registry.botled.test", mpc, chainId: 31337n, pool: "0x0000000000000000000000000000000000000000",
    signers: [{ address: gateway.address, kind: 1 }, { address: tee.address, kind: 2, model: LANES.deepseek.model }],
    sponsors: ["relay.botled.test", "relay-b.botled.test"],
  });

  step("anvil + DeployLocalNear.s.sol (local chain 31337 only)");
  anvil = spawn("anvil", ["--port", String(RPC_PORT), "--silent", "--code-size-limit", "24576"], { stdio: "ignore" });
  await waitRpc();
  execFileSync("forge", ["script", "script/DeployLocalNear.s.sol", "--rpc-url", rpc, "--broadcast", "-q"], {
    cwd: root, stdio: ["ignore", "ignore", "inherit"],
    env: {
      ...process.env, E2E_DEPLOYER_PK: DEPLOYER_PK, E2E_GATEWAY: gateway.address, E2E_TEE: tee.address,
      E2E_SPONSOR: sponsor.address, E2E_SPONSOR_B: sponsorB.address, E2E_ENROLL: registry.enrollSigner(),
    },
  });
  const d = JSON.parse(readFileSync(`${dir}deployment.json`, "utf8")) as Record<string, Hex>;
  registry.pool = d.pool;
  console.log("deployed", d);

  const client = createPublicClient({ chain: foundry, transport: http(rpc) });
  const test = createTestClient({ chain: foundry, mode: "anvil", transport: http(rpc) });
  const deployer = createWalletClient({ chain: foundry, transport: http(rpc), account: privateKeyToAccount(DEPLOYER_PK) });
  const keeperW = createWalletClient({ chain: foundry, transport: http(rpc), account: privateKeyToAccount(KEEPER_PK) });
  const receipts: TransactionReceipt[] = [];
  const mined = async (h: Hex) => {
    const r = await client.waitForTransactionReceipt({ hash: h });
    if (r.status !== "success") throw new Error(`tx reverted ${h}`);
    receipts.push(r);
    return r;
  };
  const keeper = { send: async (to: Hex, data: Hex) => (await mined(await keeperW.sendTransaction({ to, data }))).transactionHash };
  const warp = async (secs: bigint) => { await test.increaseTime({ seconds: Number(secs) }); await test.mine({ blocks: 1 }); };
  const now = async () => (await client.getBlock()).timestamp;

  step("mock NEAR AI (gateway key for kimi, own TEE key for DeepSeek) + sponsor relay");
  const ai = new MockNearAi({ gateway, tee: { [LANES.deepseek.model]: tee }, decide: () => ({ outcome: "WORKER_WINS", workerBps: 10000 }) });
  servers.push(await ai.listen(AI_PORT));
  const lanes: LaneCfg[] = [{ ...LANES.kimi, signerId: 0 }, { ...LANES.deepseek, signerId: 1 }]; // local signer slots
  const relay = new SponsorRelay({
    nearAiKey: "mock", nearAiUrl: `http://127.0.0.1:${AI_PORT}/v1`, near: new MockNearAccount("relay.botled.test", registry, mpc),
    registry: registry.id, sponsor, sponsorId: 2, base: client as any, chainId: 31337n, nearConfig: d.nearConfig,
    cage: d.cage, pool: d.pool, lanes, storePath: `${dir}relay-seats.json`,
  });
  servers.push(await relay.listen(RELAY_PORT));
  // second, independent relay (own NEAR account + own BotledNearConfig sponsor key, signer id 3)
  const relayB = new SponsorRelay({
    nearAiKey: "mock", nearAiUrl: `http://127.0.0.1:${AI_PORT}/v1`, near: new MockNearAccount("relay-b.botled.test", registry, mpc),
    registry: registry.id, sponsor: sponsorB, sponsorId: 3, base: client as any, chainId: 31337n, nearConfig: d.nearConfig,
    cage: d.cage, pool: d.pool, lanes, storePath: `${dir}relay-b-seats.json`,
  });
  servers.push(await relayB.listen(RELAY_B_PORT));

  step("4 runners: signup on NEAR (Chain Signatures proof) -> ticket with session key -> pool.enroll (relayed)");
  const sys = readFileSync(`${root}test/near-vectors/system_prompt.txt`, "utf8");
  const schema = readFileSync(`${root}test/near-vectors/schema.compact.json`, "utf8");
  const runners: Runner[] = [];
  for (let i = 0; i < 4; i++) {
    const cfg: RunnerConfig = {
      registry: registry.id, usdc: "usdc.test", mpc: "v1.signer", cage: d.cage, pool: d.pool, chainId: 31337n,
      sponsorUrl: `http://127.0.0.1:${RELAY_PORT}`, nearAiKey: "mock-own-key", nearAiUrl: `http://127.0.0.1:${AI_PORT}/v1`,
      lanes, systemPrompt: sys, schema, statePath: `${dir}runner-${i}.json`, send: true,
    };
    const r = new Runner(new MockNearAccount(`runner${i}.test`, registry, mpc), keeper, client as any, cfg);
    await r.signup();
    assert.equal(await r.ensureTicket(), true);
    const info = await client.readContract({ address: d.pool, abi: poolAbi, functionName: "runners", args: [r.me] });
    assert.equal(info[0], true, "listed");
    assert.notEqual(info[7], "0x0000000000000000000000000000000000000000", "session key on Base");
    runners.push(r);
  }
  console.log("enrolled", runners.map((r) => r.me));
  assert.equal(await runners[0].ensureTicket(), false, "fresh ticket is kept");

  step("dispute on Azzle micro module -> openCase -> VRF -> bindEvidence");
  const regAbi = parseAbi(["function open(address m, uint256 id, bytes32 ev)", "function worker() view returns (address)"]);
  const modAbi = parseAbi([
    "function submitEvidence(uint256 taskId, bytes32 evidenceHash)",
    "function disputes(uint256) view returns (uint256 taskId,address opener,address arbitrator,bytes32 posterEvidence,bytes32 workerEvidence,uint64 evidenceDeadline,uint64 rulingDeadline,uint8 status,uint8 outcome,uint256 slashed)",
  ]);
  const taskId = 1n;
  await mined(await deployer.writeContract({ address: d.registry, abi: regAbi, functionName: "open", args: [d.micro, taskId, keccak256(toBytes(POSTER_DOC))] }));
  const worker = await client.readContract({ address: d.registry, abi: regAbi, functionName: "worker" });
  await test.impersonateAccount({ address: worker });
  await test.setBalance({ address: worker, value: 10n ** 18n });
  const workerW = createWalletClient({ chain: foundry, transport: http(rpc), account: worker });
  await mined(await workerW.writeContract({ address: d.micro, abi: modAbi, functionName: "submitEvidence", args: [taskId, keccak256(toBytes(WORKER_DOC))] }));
  const dsp = await client.readContract({ address: d.micro, abi: modAbi, functionName: "disputes", args: [taskId] });
  await warp(dsp[5] - (await now()) + 1n);
  const open = await mined(await keeperW.writeContract({ address: d.cage, abi: cageAbi, functionName: "openCase", args: [d.micro, taskId] }));
  const reqLog = open.logs.map((l) => { try { return decodeEventLog({ abi: poolAbi, ...l }); } catch { return undefined; } })
    .find((e) => e?.eventName === "DrawRequested");
  const requestId = (reqLog!.args as any).requestId as bigint;
  const vrfAbi = parseAbi(["function fulfill(uint256 id, uint256 word)"]);
  await mined(await deployer.writeContract({ address: d.vrf, abi: vrfAbi, functionName: "fulfill", args: [requestId, 0xb0771edn] }));
  await mined(await keeperW.writeContract({ address: d.cage, abi: cageAbi, functionName: "bindEvidence", args: [d.micro, taskId, "0x", toHex(POSTER_DOC), toHex(WORKER_DOC)] }));
  const drawId = await client.readContract({ address: d.cage, abi: cageAbi, functionName: "drawId", args: [d.micro, taskId, 1] });
  const drawn = await client.readContract({ address: d.pool, abi: poolAbi, functionName: "drawnRunners", args: [d.cage, drawId] });
  console.log("drawn (seat order):", drawn);
  assert.equal(drawn.length, 3);

  step("seats: 1 kimi via relay A, 2 deepseek via relay B (A down -> failover), 3 kimi own key (no relay -> liveness)");
  const byAddr = new Map(runners.map((r) => [r.me.toLowerCase(), r]));
  const seated = drawn.map((a) => byAddr.get(a.toLowerCase())!);
  (seated[1].cfg as RunnerConfig).sponsorUrl = `http://127.0.0.1:9,http://127.0.0.1:${RELAY_B_PORT}`; // A unreachable -> B
  (seated[2].cfg as RunnerConfig).sponsorUrl = "http://127.0.0.1:9"; // relay unreachable for this runner
  for (const r of seated) {
    const p = await r.serveSeat(d.micro, taskId, docs);
    assert.ok(p, "seat served");
  }
  const notDrawn = runners.find((r) => !drawn.map((x) => x.toLowerCase()).includes(r.me.toLowerCase()))!;
  assert.equal(await notDrawn.serveSeat(d.micro, taskId, docs), undefined, "undrawn runner does nothing");
  assert.deepEqual(ai.calls.map((c) => c.model), [LANES.kimi.model, LANES.deepseek.model, LANES.kimi.model], "lane per seat");
  assert.equal(relay.requestsIssued + relayB.requestsIssued, 2);
  assert.equal(relayB.requestsIssued, 1, "seat 2 served by relay B");

  step("no resampling: the relay re-serves the same receipt, and refuses a different request for a served seat");
  const c = await client.readContract({ address: d.cage, abi: cageAbi, functionName: "getCase", args: [d.micro, taskId] });
  const req0 = buildRequest(lanes[0], sys, schema, seated[0].me, c.round, c.inputHash, docs);
  const again = await relay.run(d.micro, taskId, req0);
  assert.equal(relay.requestsIssued, 1, "no new NEAR AI request");
  assert.equal(ai.calls.length, 3);
  await assert.rejects(relay.run(d.micro, taskId, buildRequest(lanes[0], sys, schema, seated[0].me, c.round, c.inputHash, { ...docs, scope: "x" })), /different request/);
  await assert.rejects(relay.run(d.micro, taskId, buildRequest(lanes[1], sys, schema, seated[2].me, c.round, c.inputHash, docs)), /is lane/, "seat 3 is kimi: wrong-lane request refused");
  // cross-relay resampling: relay A cannot re-run seat 2 (already billed by B on NEAR: max_runs_per_seat = 1)
  const req1 = buildRequest(lanes[1], sys, schema, seated[1].me, c.round, c.inputHash, docs);
  await assert.rejects(relay.run(d.micro, taskId, req1), /max_runs_per_seat/);
  assert.equal(relay.requestsIssued, 2, "A paid NEAR AI for the attempt but could not bill or co-sign it");
  const seatsB = await (await fetch(`http://127.0.0.1:${RELAY_B_PORT}/seats`)).json();
  assert.equal(seatsB.length, 1);
  assert.equal(seatsB[0].runner, seated[1].me.toLowerCase());
  assert.ok(again.sponsorSig.length === 132);

  step("reveal after the commit window (permissionless, keeper pays gas)");
  const [commitEnd] = await client.readContract({ address: d.cage, abi: cageAbi, functionName: "windows", args: [d.micro, taskId] });
  await warp(commitEnd - (await now()) + 1n);
  for (const r of seated) assert.equal(await r.revealDue(), 1);
  const revealed = receipts.flatMap((rc) => rc.logs).map((l) => { try { return decodeEventLog({ abi: cageAbi, ...l }); } catch { return undefined; } })
    .filter((e) => e?.eventName === "Revealed").map((e) => e!.args as any);
  console.log("revealed:", revealed.map((e) => ({ runner: e.runner, lane: e.lane, counted: e.counted, signerId: e.signerId })));
  assert.deepEqual(revealed.map((e) => [e.lane, e.counted, e.sponsorId]), [[0, true, 2], [1, true, 3], [0, false, 0]]);

  step("closeRound (all revealed) -> appeal window -> finalize -> Azzle ruling");
  await keeper.send(d.cage, (await import("viem")).encodeFunctionData({ abi: cageAbi, functionName: "closeRound", args: [d.micro, taskId] }));
  const cs = await client.readContract({ address: d.cage, abi: cageAbi, functionName: "getCase", args: [d.micro, taskId] });
  assert.equal(cs.hasResult, true, "2 counted votes on 2 lanes = majority of 3");
  await warp(cs.deadline - (await now()) + 1n);
  const fin = await mined(await keeperW.writeContract({ address: d.cage, abi: cageAbi, functionName: "finalize", args: [d.micro, taskId] }));
  const ruled = fin.logs.map((l) => { try { return decodeEventLog({ abi: cageAbi, ...l }); } catch { return undefined; } }).find((e) => e?.eventName === "CageRuled");
  assert.ok(ruled, "CageRuled");
  assert.equal((ruled!.args as any).outcome, 2, "WORKER_WINS");
  const after = await client.readContract({ address: d.micro, abi: modAbi, functionName: "disputes", args: [taskId] });
  assert.equal(after[7], 3, "Azzle dispute SETTLED");
  assert.equal(after[8], 2, "Azzle outcome WORKER_WINS");
  const rw = await Promise.all(seated.map((r) => client.readContract({ address: d.pool, abi: poolAbi, functionName: "rewards", args: [r.me] })));
  console.log("AZL rewards:", rw.map((x) => Number(x) / 1e18));
  assert.ok(rw[0] > 0n && rw[1] > 0n && rw[2] === 0n, "only counted votes earn");
  assert.equal(registry.log.length, 3, "every NEAR AI run billed on NEAR");

  step("relay audit: NEAR get_runs vs Base reveals");
  const auditNear = new MockNearAccount("auditor.test", registry, mpc);
  const rep = await audit({ base: client as any, cage: d.cage, pool: d.pool, near: auditNear, registry: registry.id });
  console.log(JSON.stringify({ relays: rep.relays, reveals: rep.reveals, findings: rep.findings.map((f) => f.kind) }));
  assert.equal(rep.ok, true);
  assert.deepEqual(rep.relays, { "relay.botled.test": { billed: 1, delivered: 1, withheld: 0 }, "relay-b.botled.test": { billed: 1, delivered: 1, withheld: 0 } });
  assert.deepEqual(rep.findings.map((f) => f.kind), ["LIVENESS"]);
  // a relay that billed a seat and then withheld the co-signature is attributed
  registry.runLog.push({ ...registry.runLog[2], index: registry.runLog.length, caller: "relay.botled.test", sponsored: true, response_sha256: "ee".repeat(32) });
  registry.runLog.splice(2, 1);
  const rep2 = await audit({ base: client as any, cage: d.cage, pool: d.pool, near: auditNear, registry: registry.id });
  assert.equal(rep2.ok, false);
  assert.deepEqual(rep2.findings.map((f) => [f.kind, f.relay]), [["WITHHELD", "relay.botled.test"]]);
  const gas = receipts.map((r) => r.gasUsed);
  console.log(`\nE2E OK  (${receipts.length} txs on local anvil; ${ai.calls.length} NEAR AI calls; ${registry.log.length} record_run)`);
  void gas;
}

main()
  .catch((e) => { console.error(e); process.exitCode = 1; })
  .finally(() => { servers.forEach((s) => s.close()); anvil?.kill(); });
