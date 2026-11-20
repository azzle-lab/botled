/**
 * Fork end-to-end. Starts a local Anvil fork of Base, funds a fresh runner from an impersonated
 * AZL holder, registers it on the v4 pool, asks the live cage (impersonated, fork only) for a draw,
 * fulfills VRF, and checks the node finds that draw. No mainnet transaction.
 * The private key stays in this process and is not printed.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import { createPublicClient, decodeEventLog, http, encodeFunctionData, parseAbi, type Address, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

const PORT = 18545;
const RPC = `http://127.0.0.1:${PORT}`;
const bundled = join(homedir(), ".foundry", "bin", process.platform === "win32" ? "anvil.exe" : "anvil");
const ANVIL = process.env.ANVIL ?? (existsSync(bundled) ? bundled : "anvil");
const WHALE = "0x3D5eb1F648F495fAEFaeBa0dE74A5c52b6602F5D" as Address;
const AZL = "0x931517E9502F9d52CDF6F5AC7fca7925e2A1BBA3" as Address;
const POOL = "0xD2dEF94F5470C0B4AFa0E651427B9a1b100DB8b2" as Address;
const FACTORY = "0x8297A533bFAE66c1529ce75C425AC2F462DDe073" as Address;

const poolAbi = parseAbi([
  "function runnerReserve() view returns (uint256)",
  "function runnerCount() view returns (uint256)",
  "function vrfWrapper() view returns (address)",
  "function isDrawn(address,uint256,address) view returns (bool)",
  "function requestDraw(uint256,address,address,uint8,uint64) returns (bool)",
  "function rawFulfillRandomWords(uint256,uint256[])",
  "event DrawRequested(address indexed cage, uint256 indexed drawId, uint256 requestId, uint256 pricePaid)",
]);
const erc = parseAbi(["function balanceOf(address) view returns (uint256)", "function transfer(address,uint256) returns (bool)"]);
const factoryAbi = parseAbi(["function cageCount() view returns (uint256)", "function cages(uint256) view returns (address)"]);
const STUB = "0x608060405260043610610028575f3560e01c806313c34b7f1461002c5780639cfc058e14610068575b5f80fd5b348015610037575f80fd5b50610052600480360381019061004d91906100f2565b610098565b60405161005f9190610148565b60405180910390f35b610082600480360381019061007d91906101f9565b6100a3565b60405161008f9190610148565b60405180910390f35b5f6001905092915050565b5f6007905095945050505050565b5f80fd5b5f80fd5b5f63ffffffff82169050919050565b6100d1816100b9565b81146100db575f80fd5b50565b5f813590506100ec816100c8565b92915050565b5f8060408385031215610108576101076100b1565b5b5f610115858286016100de565b9250506020610126858286016100de565b9150509250929050565b5f819050919050565b61014281610130565b82525050565b5f60208201905061015b5f830184610139565b92915050565b5f61ffff82169050919050565b61017781610161565b8114610181575f80fd5b50565b5f813590506101928161016e565b92915050565b5f80fd5b5f80fd5b5f80fd5b5f8083601f8401126101b9576101b8610198565b5b8235905067ffffffffffffffff8111156101d6576101d561019c565b5b6020830191508360018202830111156101f2576101f16101a0565b5b9250929050565b5f805f805f60808688031215610212576102116100b1565b5b5f61021f888289016100de565b955050602061023088828901610184565b9450506040610241888289016100de565b935050606086013567ffffffffffffffff811115610262576102616100b5565b5b61026e888289016101a4565b9250925050929550929590935056fea2646970667358221220adb2c6b0c07b8f3f92257f93ee48375adeebe818daf368dc9bf2119b1f2cb4eb64736f6c63430008180033" as Hex;

function sleep(ms: number) { return new Promise((r) => setTimeout(r, ms)); }

async function rpc(method: string, params: unknown[]) {
  const res = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const body = await res.json() as { result?: Hex; error?: { message: string } };
  if (body.error) throw new Error(body.error.message);
  return body.result as Hex;
}

async function impersonatedTx(from: Address, to: Address, data: Hex) {
  await rpc("anvil_impersonateAccount", [from]);
  const hash = await rpc("eth_sendTransaction", [{ from, to, data }]);
  const pub = createPublicClient({ transport: http(RPC) });
  const rcpt = await pub.waitForTransactionReceipt({ hash });
  await rpc("anvil_stopImpersonatingAccount", [from]);
  if (rcpt.status !== "success") throw new Error("impersonated tx reverted");
  return rcpt;
}

async function main() {
  const anvil: ChildProcess = spawn(ANVIL, ["--fork-url", "https://mainnet.base.org", "--port", String(PORT), "--silent"], { stdio: "ignore" });
  let ready = false;
  for (let i = 0; i < 60; i++) {
    try { await rpc("eth_chainId", []); ready = true; break; } catch { await sleep(1000); }
  }
  if (!ready) { anvil.kill(); throw new Error("anvil did not start"); }
  const pub = createPublicClient({ transport: http(RPC) });
  const pk = generatePrivateKey();
  const fresh = privateKeyToAccount(pk);
  process.env.RPC_URL = RPC;
  process.env.BOTLED_SEND = "1";
  process.env.MOCK_VOTE = "2:10000";
  process.env.RUNNER_PK = pk;
  process.env.STATE_DIR = mkdtempSync(join(tmpdir(), "botled-e2e-"));
  process.env.ONCE = "1";
  process.env.KEEPER = "0";
  try {
    const reserve = await pub.readContract({ address: POOL, abi: poolAbi, functionName: "runnerReserve" });
    const whaleAzl = await pub.readContract({ address: AZL, abi: erc, functionName: "balanceOf", args: [WHALE] });
    if (whaleAzl < reserve) throw new Error("fork whale has less AZL than the reserve");
    await rpc("anvil_setBalance", [fresh.address, "0x8AC7230489E80000"]);
    await impersonatedTx(WHALE, AZL, encodeFunctionData({ abi: erc, functionName: "transfer", args: [fresh.address, reserve] }));
    const { register } = await import("./runner-cli.ts");
    const { discoverDraws, tickOnce } = await import("./botled-node.ts");
    await register();
    const count = await pub.readContract({ address: POOL, abi: poolAbi, functionName: "runnerCount" });
    const n = count > 15n ? 15 : Number(count);
    const cages = await pub.readContract({ address: FACTORY, abi: factoryAbi, functionName: "cageCount" });
    if (cages === 0n) throw new Error("no v4 cage on the fork");
    const cage = await pub.readContract({ address: FACTORY, abi: factoryAbi, functionName: "cages", args: [0n] });
    await rpc("anvil_setBalance", [POOL, "0xDE0B6B3A7640000"]);
    await rpc("anvil_setBalance", [cage, "0x8AC7230489E80000"]);
    const wrapper = await pub.readContract({ address: POOL, abi: poolAbi, functionName: "vrfWrapper" });
    await rpc("anvil_setCode", [wrapper, STUB]);
    await rpc("anvil_setBalance", [wrapper, "0x8AC7230489E80000"]);
    const now = (await pub.getBlock()).timestamp;
    const drawId = (900_001n << 8n) | 1n;
    const req = await impersonatedTx(cage, POOL, encodeFunctionData({
      abi: poolAbi, functionName: "requestDraw",
      args: [drawId, "0x0000000000000000000000000000000000000001", "0x0000000000000000000000000000000000000002", n, now + 86_400n],
    }));
    let requestId = 0n;
    for (const entry of req.logs) {
      try {
        const decoded = decodeEventLog({ abi: poolAbi, data: entry.data, topics: entry.topics });
        if (decoded.eventName === "DrawRequested") requestId = decoded.args.requestId;
      } catch { /* other logs */ }
    }
    if (requestId === 0n) throw new Error("no DrawRequested");
    await impersonatedTx(wrapper, POOL, encodeFunctionData({
      abi: poolAbi, functionName: "rawFulfillRandomWords", args: [requestId, [7n]],
    }));
    const drawn = await pub.readContract({ address: POOL, abi: poolAbi, functionName: "isDrawn", args: [cage, drawId, fresh.address] });
    if (!drawn && n < Number(count)) throw new Error("fresh runner was not in the capped draw");
    if (!drawn) throw new Error("fresh runner was not drawn");
    process.env.SCAN_FROM = req.blockNumber.toString();
    const found = await discoverDraws(fresh.address);
    const hit = found.some((d) => d.cage.toLowerCase() === cage.toLowerCase() && d.drawId === drawId);
    if (!hit) throw new Error(`scan missed the draw (saw ${found.length})`);
    const before = await pub.getTransactionCount({ address: fresh.address });
    await tickOnce(fresh);
    const after = await pub.getTransactionCount({ address: fresh.address });
    if (after !== before) throw new Error("node sent a tx for a draw whose cage is not in jury");
    console.log(JSON.stringify({ ok: true, runner: fresh.address, cage, drawId: drawId.toString(), found: found.length }));
  } finally {
    anvil.kill();
  }
}

main().catch((err) => { console.error(String(err).slice(0, 800)); process.exit(1); });
