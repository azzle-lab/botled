# Botled

Botled is an LLM arbitrator caged in EVM contracts on Base. It is a client of the Azzle protocol. A cage bonds AZL, sits on the Azzle panel, and draws runners with Chainlink VRF. Each runner asks a pinned model, commits a hash, then reveals. There is no trusted execution environment and no human guardian. Bonds, randomness, commit/reveal, slashing, and two model providers carry the security.

Chain: Base, chain id 8453. The payment token is AZL (18 decimals). USD figures in Azzle policy are not the payment asset.

v5 is implemented and tested. It is not deployed. Do not broadcast a deployment, and do not send a transaction to the live v4 cage, unless the operator has said so in this conversation.

## Addresses

| Contract | Address |
|---|---|
| BotledConfig | `0x6A5785cc5e79Dc4c800367b54eA525c5e31040D7` |
| BotledRunnerPool v4 | `0xD2dEF94F5470C0B4AFa0E651427B9a1b100DB8b2` |
| BotledFactory v4 | `0x8297A533bFAE66c1529ce75C425AC2F462DDe073` |
| BotledArbitrator v4 implementation | `0xBd24ADaA60175c9AeE6F17194217508F4B7632Ac` |
| v4 cage (micro only) | `0xe16bF0267C36dA27a037F8340BdE2909B117EFb2` |
| BotledPanelOwner | `0xF7E5A611154C8d30A03791409F2606C278597a04` |
| BotledEvidence | `0xb2466cef02e7bfdaa85f141602a8759d3d96bf12` |
| Azzle micro module / vault | `0x905E561B44E76fdeAF5F41Bc2c46ebCE4E5E02fE` / `0x54242151DDCe196314fba21FA630bF62D56a14B3` |
| Azzle standard module / vault | `0x1003592A2eeF71b15A21457910007b38B0e2027A` / `0xFeF0722d2f3ba0FEb59b3fd5dCAaF49e69BD5387` |
| AZL | `0x931517E9502F9d52CDF6F5AC7fca7925e2A1BBA3` |
| Safe (2-of-3, owns PanelOwner through a 7-day timelock) | `0xB459145b74Ca4B198f73C0d573a161e85CA76D27` |

v5 pool and factory are null in `runner/deployments/base.json` until a deployment is broadcast. After that, set `V5_POOL`, `V5_FACTORY`, and `V5_FROM_BLOCK`.

The files under `src/azzle-deployed` and `src/azzle-optional` exist so the unit tests compile. They are not the Botled seat. Do not enable that panel-join module.

## What you need

A runner needs a Base RPC URL, a key that holds ETH for gas and at least 100 AZL, and a Surplus API key (`https://api.surplusintelligence.ai`). `LANE=0` pins claude-opus-5 (anthropic). `LANE=1` pins gemini-4-argon (google). Leave it unset and the node spreads lanes from the runner address.

A v5 cage operator needs the same wallet shape plus 11,000 AZL (1,000 for micro, 10,000 for standard) and 0.002 ETH for the pfand, plus a little ETH for gas. The v5 factory has to be deployed first, and BotledConfig has to list the standard module. That config write is a mainnet transaction on the shared v4 config. It waits for an explicit OK.

## Costs

Measured on a Base fork on 18 Nov 2026, with `eth_gasPrice` at 0.006 gwei. L1 data fee is extra and was small at this price. Budget 0.002 ETH for the deployment gas. The pfand is a separate 0.002 ETH.

| Step | Gas | L2 ETH at 0.006 gwei |
|---|---:|---:|
| v5 pool + factory | 7,304,181 | 0.0000438 |
| deployCage | 199,181 | 0.0000012 |
| seat (both bonds + join) | 453,101 | 0.0000027 |

A first VRF float of 0.001 ETH on the new pool covers several round-1 draws at this gas price. The plan is `deploy/v5-deploy-plan.md`. The script is `script/DeployBotledV5.s.sol`. Simulate it. Do not add `--broadcast` until the operator says so.

Runner registration pulls 100 AZL into the pool. A cage `seat` pulls 11,000 AZL. Appeal bonds, paid by the poster or the worker, are 200 AZL then 400 AZL.

## Slashing and locked funds

- A drawn runner who does not reveal loses 50 AZL.
- A reveal that is not the final vote loses 20 AZL, and only when a final vote exists.
- Each cut is capped at the 100 AZL reserve and at the runner's bond.
- Coherent reveals share that draw's slashes. If nobody is coherent, the slashed AZL stays in the reward fund. The fund can be empty, so a win can pay 0.
- Leaving the runner pool takes a 7-day cooldown, and only while no case is active. `exit` schedules that cooldown. A second `exit` after it elapses withdraws the bond.
- A cage `leave` unseats first, then schedules both vault cooldowns. `withdraw` after the cooldown returns only the AZL that just left the vault.
- The 0.002 ETH pfand is kicked if the seat is still on the panel and becomes ineligible. `scheduleExit` while seated reverts, so a withdrawal cannot by itself make the seat kickable.
- While the cage is the only eligible seated member, the vault refuses a withdrawal that would drop the bond under the minimum. Unseat first.
- The operator key can sweep the cage. A leaked operator key can take the pfand and, after the cooldown, the bonds.

Windows: VRF 1 hour, commit 3 hours, reveal 2 hours, appeal 6 hours. Juries are 3, then 7, then 15. A result needs a majority of the full jury and at least 2 distinct lanes.

## Runner

```
cd runner
npm install
# RPC_URL, RUNNER_PK or RUNNER_KEY_FILE, SURPLUS_API_KEY or SURPLUS_KEY_FILE
node --experimental-strip-types setup.ts runner
```

`setup.ts runner` checks ETH and AZL, checks the Surplus key against `/v1/payments/balance`, registers if needed, starts the node, and waits for a heartbeat.

The node reads `DrawRequested` on the v4 pool and, once configured, the v5 pool. It keeps draws where `isDrawn` is true and the draw is not settled. Salts are written to `runner/state` before `commit`. Keys are not logged.

Manual commands:

```
node --experimental-strip-types runner-cli.ts register
node --experimental-strip-types runner-cli.ts status
node --experimental-strip-types runner-cli.ts exit
```

Sends require `BOTLED_SEND=1`. A public RPC host also requires `MAINNET_OK=1`. The node refuses to send to the live v4 cage unless `ALLOW_V4_CAGE=1`. Leave that unset.

`KEEPER=1` lets the same key call `retryDraw`, `closeRound`, and `finalize` on a draw it was selected for. It does not open other people's cases.

## Cage

```
node --experimental-strip-types cage-cli.ts create
node --experimental-strip-types cage-cli.ts fund
node --experimental-strip-types cage-cli.ts join
node --experimental-strip-types cage-cli.ts leave
node --experimental-strip-types cage-cli.ts withdraw
```

Or `node --experimental-strip-types setup.ts cage`, which runs the balance checks, `create`, `fund`, and `join`, then reads `seatStatus`.

`create` needs `V5_FACTORY`. `fund` and `join` need `CAGE` and `CAGE_PK` (or `CAGE_KEY_FILE`).

## Tests

Fork tests, from this directory, with the Azzle sources at `../contracts`:

```
npm install
$env:FORK_BASE="true"; $env:BASE_RPC="https://mainnet.base.org"
forge test --match-contract BotledV5Fork
```

On 18 Nov 2026 that suite passed: 3 passed, 0 failed.

Runner fork test (local Anvil, fresh key, no mainnet send):

```
cd runner
npm install
npm run e2e
```

That test registers a new runner on a Base fork, fulfills a draw, and checks the node sees it. The case is not in the jury phase, so the node does not send a commit.

## License

MIT. See `LICENSE`.
