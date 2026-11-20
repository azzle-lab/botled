// CLI: node --experimental-strip-types tools/audit.ts
//   env BASE_RPC, CAGE, POOL, NEAR_RPC (default mainnet), REGISTRY, FROM_BLOCK
// Read-only (eth_getLogs / eth_call on Base, call_function views on NEAR). Exit 1 if a relay violation is found.
import { createPublicClient, http, type Hex } from "viem";
import { audit } from "../audit.ts";
import { NearRpc } from "../near.ts";

const env = (k: string, d?: string) => process.env[k] ?? d ?? (() => { throw new Error(`set ${k}`); })();
const base = createPublicClient({ transport: http(env("BASE_RPC")) });
const near = new NearRpc({ rpc: env("NEAR_RPC", "https://rpc.mainnet.near.org"), accountId: "audit.readonly" });
const rep = await audit({
  base: base as any, cage: env("CAGE") as Hex, pool: env("POOL") as Hex, near, registry: env("REGISTRY"),
  fromBlock: BigInt(env("FROM_BLOCK", "0")),
});
console.log(JSON.stringify(rep, null, 2));
process.exit(rep.ok ? 0 : 1);
