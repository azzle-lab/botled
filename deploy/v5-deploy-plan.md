# Botled v5 deploy plan

Status: prepared, not executed. Nothing in this plan has been sent to Base.

Fork tests (`FORK_BASE=true`, public Base RPC, `forge test --match-contract BotledV5Fork`) on 18.11.2026: 3 passed, 0 failed.

| Test | Result | Gas |
|---|---|---|
| testForkCreateJoinBothRuleBothLeave | pass | 11,818,862 |
| testForkAppealOnStandard | pass | 9,753,433 |
| testForkGasProfile | pass | 607,816 |

Measured inside the fork (excludes the 21,000 intrinsic and the L1 data fee):

| Step | Gas | L2 ETH at 0.006 gwei |
|---|---:|---:|
| RunnerPool v5 + FactoryV5 (includes the cage implementation) | 7,304,181 | 0.0000438 |
| deployCage | 199,181 | 0.0000012 |
| seat (both vault bonds + join) | 453,101 | 0.0000027 |

Live `eth_gasPrice` at measurement time was 0.006 gwei. L1 calldata for the two CREATEs is extra and was a few hundred thousand wei in the v4 snapshot. Budget **0.002 ETH** for pool, factory, one cage and seat. That is about 40 times the measured L2 cost. The seat also needs **0.002 ETH pfand**, sent as `msg.value` on `seat`, and **11,000 AZL** (1,000 micro + 10,000 standard) approved to the cage. A first VRF float of **0.001 ETH** on the new pool is enough for several round-1 draws at this gas price.

## What is deployed

Two CREATEs from one EOA, in this nonce order, so the pool's `config` slot equals the factory (the trust anchor). The script is `build/script/DeployBotledV5.s.sol`.

1. `BotledRunnerPool` (unmodified v4 code, new address). Reserve 100 AZL, exit cooldown 7 days, VRF gas 100,000 + 70,000 per juror, 3 confirmations.
2. `BotledFactoryV5`, which deploys the `BotledCageV5` implementation in its constructor.

Reused, not redeployed: BotledConfig, BotledPanelOwner, both Azzle modules, both vaults, AZL, the Chainlink VRF wrapper.

Not touched: the v4 pool, the v4 factory, the v4 implementation, the live v4 cage.

## Prerequisite, after the live dispute

`deployCage` reverts until BotledConfig lists the standard module. The config owner calls `proposeArbitration` on the standard module. Support starts one day later (`timelock`). That call writes the shared v4 config. It does not change the live micro cage, and it is still a mainnet transaction. Do not send it before Sun 22.11.2026 06:00 Berlin, and not without an explicit OK.

Simulate only:

```
forge script script/DeployBotledV5.s.sol --rpc-url $BASE_RPC --sender <deployer>
```

Broadcast is a separate step and is not part of this plan's execution.

## Security review (BotledCageV5, BotledFactoryV5)

No fork-test failure and no change to the contracts after review.

- Reentrancy. `seat`, `unseat`, `claimPfand`, `withdrawBond`, `openCase`, `retryDraw`, `appeal`, `closeRound`, `finalize` and `syncAzzleTimeout` use the contract-wide guard. `commit` and `reveal` make no external calls. `scheduleExit` only calls the two vaults. A callback during the pfand push can reenter `scheduleExit` and reset the cooldown timer. It cannot move AZL, because `withdrawBond` is guarded and the vault still enforces the cooldown.
- Case key. `keccak256(module, taskId)`. `openCase` accepts only the two modules stored from PanelOwner. `drawId` packs module index in bits 248+, task id in bits 8..247 (capped at 2^240-1), round in bits 0..7. Micro task 7 and standard task 7 do not share a case or a draw.
- Slashing. No reveal pays `noShowSlash`. A reveal that is not the final vote pays `minoritySlash`, and only when a final vote exists. Coherent reveals share that draw's slashes plus `rewardPerRound` and, on the last round, the forfeited half of appeal bonds. Each cut is capped by the pool at `runnerReserve` and at the runner's bond. Slashes with no coherent runner stay in the reward fund.
- Pfand and bonds. `unseat` calls `leave` (reverts while `canRelease` is true) and forwards the cage's ETH, which is the pushed pfand. A failed push sits in `claimable` and `claimPfand` pulls it. `withdrawBond` forwards only the AZL that just left the vault, so appeal bonds already held are not swept. `scheduleExit` reverts while the cage is seated, so a scheduled withdrawal cannot make the seat kickable.
- Last eligible member. The vault blocks `scheduleWithdrawal` and a bond drop under `minimumBond` while `authorized` is true and no other member is eligible. `exit` unseats first. After `leave`, `authorized` is false, so the cooldown can start. Calling `scheduleExit` while seated reverts `StillSeated` and does not reach the vault. The cage cannot be the last eligible member and start a withdrawal in the same state that would let a keeper `kick` the pfand.

Residual, accepted: the operator is the only address that can sweep ETH and AZL out of the cage. A direct ETH transfer to the cage is forwarded on `unseat`. Appeal bonds and the panel bond are the same AZL token. The withdraw path uses a balance delta so they stay separate.
