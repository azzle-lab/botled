You are setting up Botled from this repository. Read README.md and deploy/v5-deploy-plan.md before you send anything.

Rules you do not relax:
- Do not modify Azzle contracts. Azzle is an external dependency.
- Do not print private keys, do not write them into the repo, and do not commit them.
- Do not set MAINNET_OK and do not set ALLOW_V4_CAGE.
- Do not broadcast a deployment and do not send any Base mainnet transaction unless the operator has explicitly said OK in this chat. Before Sunday 22 Nov 2026 06:00 Europe/Berlin, also do not call the live v4 cage 0xe16bF0267C36dA27a037F8340BdE2909B117EFb2. A real dispute is running there.
- No trusted execution environment and no human guardian. The cage and the runner are the product.

What the operator gives you:
- a wallet key file (mode 600) or an env var, never pasted into a commit
- AZL and a little ETH on Base
- a Surplus API key for the runner

Until mainnet is allowed, prove the runner on a fork only:

```
cd runner
npm install
npm run e2e
```

When the operator has allowed mainnet, set up a runner:

```
cd runner
npm install
RPC_URL=https://mainnet.base.org
RUNNER_KEY_FILE=/path/to/key.json
SURPLUS_KEY_FILE=/path/to/surplus.json
BOTLED_SEND=1
MAINNET_OK=1
node --experimental-strip-types setup.ts runner
```

That command checks the ETH balance (at least 0.0002 ETH), checks AZL against the pool reserve (100 AZL), checks the Surplus key, registers on the v5 pool if `V5_POOL` is set and otherwise on the v4 pool, starts the node, and waits for a heartbeat. Then run `runner-cli.ts status` and confirm `listed` and `eligible`.

Do not point the node at a hand-written task list. It finds DrawRequested logs itself. Leave LANE unset unless the operator names a lane. Leave ALLOW_V4_CAGE unset.

A v5 cage is possible only after the v5 factory is deployed and BotledConfig lists the standard module. Both of those are mainnet writes. Stop and ask before either one. The deploy script is script/DeployBotledV5.s.sol. Simulate it. Add --broadcast only after a separate OK. Budget about 0.002 ETH for gas, plus 0.002 ETH pfand, plus 11,000 AZL.

After the factory address is in runner/deployments/base.json (or V5_FACTORY / V5_POOL / V5_FROM_BLOCK):

```
CAGE_KEY_FILE=/path/to/operator.json
BOTLED_SEND=1
MAINNET_OK=1
node --experimental-strip-types setup.ts cage
```

That checks ETH above the pfand plus gas, checks 11,000 AZL, checks that PanelOwner still owns both modules, deploys a cage, approves AZL, calls seat, and reads seatStatus. Report the cage address and whether microEligible and standardEligible are true.

If a check fails, stop and report the balance, the revert, and the command you ran. Do not retry a reverted mainnet transaction in a loop.
