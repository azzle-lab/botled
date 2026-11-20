// Keeper (Base): BotledRewardSwapper USDC -> AZL -> pool.fundRewards. Read-only simulation unless BOTLED_SEND=1.
//   BASE_RPC=.. SWAPPER=0x.. ROUTE_DATA=0x<router calldata> [AMOUNT_IN=usdc units] node --experimental-strip-types tools/swap-rewards.ts
// ROUTE_DATA is calldata for the swapper's immutable `router` that delivers AZL to the swapper (e.g. an aggregator or
// Uniswap route built off-chain). The contract does not trust it: it enforces spent <= amountIn and an oracle-par
// floor (maxSlippageBps), so a bad route only reverts. Sending needs KEEPER_PK (any funded Base key; holds nothing).
import { createPublicClient, createWalletClient, http, parseAbi, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const abi = parseAbi([
  "function usdc() view returns (address)",
  "function router() view returns (address)",
  "function maxSlippageBps() view returns (uint16)",
  "function maxInPerCall() view returns (uint256)",
  "function floorUsd6(uint256) view returns (uint256)",
  "function swapAndFund(uint256 amountIn, bytes routerData) returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "error Slippage(uint256 azlOut, uint256 usdValue6, uint256 floor6)",
  "error Bounds()", "error Oracle()", "error Route()",
]);
const env = (k: string) => process.env[k] ?? (() => { throw new Error(`set ${k}`); })();
const client = createPublicClient({ transport: http(env("BASE_RPC")) });
const swapper = env("SWAPPER") as Hex;
const usdc = await client.readContract({ address: swapper, abi, functionName: "usdc" });
const bal = await client.readContract({ address: usdc, abi, functionName: "balanceOf", args: [swapper] });
const cap = await client.readContract({ address: swapper, abi, functionName: "maxInPerCall" });
const amountIn = BigInt(process.env.AMOUNT_IN ?? (bal < cap ? bal : cap));
const floor = await client.readContract({ address: swapper, abi, functionName: "floorUsd6", args: [amountIn] });
console.log({ usdcBalance: bal, amountIn, maxSlippageBps: await client.readContract({ address: swapper, abi, functionName: "maxSlippageBps" }), floorUsd6: floor });
const from = (process.env.KEEPER_PK ? privateKeyToAccount(process.env.KEEPER_PK as Hex).address : "0x000000000000000000000000000000000000dEaD") as Hex;
const sim = await client.simulateContract({ address: swapper, abi, functionName: "swapAndFund", args: [amountIn, env("ROUTE_DATA") as Hex], account: from });
console.log("simulated AZL out:", sim.result);
if (process.env.BOTLED_SEND !== "1") process.exit(0);
const w = createWalletClient({ transport: http(env("BASE_RPC")), account: privateKeyToAccount(env("KEEPER_PK") as Hex) });
const h = await w.writeContract({ ...sim.request, chain: null });
console.log("tx", h);
