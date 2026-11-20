# Botled v5/NEAR

Botled is an LLM arbitrator caged in EVM contracts on Base. It is a client of the Azzle protocol: a cage sits on the
Azzle panel, draws juror runners with Chainlink VRF, and settles cases by commit/reveal votes.

In v5/NEAR every counted vote is proven by a **NEAR AI receipt signed in a TEE / by the NEAR AI gateway**, checked
on Base. Runners are identified by their NEAR account:

- **Signup on NEAR:** a runner pays **20 USDC once** to the NEAR registry. It is split **5 / 5 / 10**: $5 profit,
  $5 dev, $10 inference budget for the runner.
- **Chain Signatures identity:** the runner's Base address is the NEAR Chain Signatures (`v1.signer`) address of
  `(runner account, "base-1")`. The registry refuses any other address.
- **No bonds, no slashing for runners.** A drawn runner that does not show up is suspended until the registry has
  charged it a **$2 no-show penalty**, which goes to the reward fund.
- **Two pinned lanes:** `moonshotai/kimi-k3` (NEAR AI gateway key) and `deepseek-ai/DeepSeek-V4.1-Flash-1017`
  (NEAR-hosted TEE key). The cage assigns each seat's lane (`lane = (seat − 1) % 2`); a result needs two lanes.
- **Sponsor relays:** only receipts co-signed by a sponsor relay count as votes. The relay pays NEAR AI, bills the
  runner's NEAR budget (`record_run`) and serves exactly one run per seat. Co-signing two runs for one seat is a
  public fraud proof (`reportEquivocation`) that retires the relay key.
- **Rewards:** counted votes earn an equal share of `rewardPerRound` in AZL on Base, paid from the pool's reward fund
  (funded via `pool.fundRewards`).

The full design, trust assumptions and measurements are in [`DESIGN.md`](DESIGN.md).

## Status

**Live on mainnet, but NOT open yet.** The NEAR registry and the Base contracts (config, verifier, libraries, pool,
factory, cage implementation) are deployed (20 Nov 2026). No cage has been deployed and no sponsor relay is running.
The first cage and the relays are planned for **Monday 23 Nov 2026**.

**Do not sign up with real USDC until the operator announces that the cage is live.**

Two timelocked registry changes are proposed and pending (timelock 1 day; see `deploy/mainnet-near-v5.json`):

| id | Change | Proposed in | Applicable from |
|---|---|---|---|
| 0 | `Recipients`: `profit_to` = `dev_to` = `azzle.near`, `penalty_to` unchanged | `JfjWGtCQbHdo5MYZKiBK4MvD9VLxXTkiQ8TJAsJWrG4` | 2026-11-21 16:46:38 UTC |
| 1 | `Pool`: chain 8453, pool `0x4fE84CAe74039df848BEe0c7E7Dd9A4eAfaFf7EF` | `FPNtjXX2p8gxWQDekmBDmACq6WSBwx9FhiSiCHcyvC7T` | 2026-11-21 17:45:05 UTC |

Until change 1 is applied the registry's pool domain is unset and it signs no enrollment tickets.

Website: <https://botled.vercel.app>

## NEAR

| | |
|---|---|
| Network | NEAR mainnet |
| Registry account | `b0c3f8cbde21c8814baccfd84afce62f70ab33b57fe3717b01828ee41f06c625` (implicit account, also its own owner) |
| wasm sha256 | `ae640bb345f57a4caed813c7de316a0c7d108efc5a2ee43f3457a95de9685067` (`near/wasm.sha256`) |
| Code hash (base58) | `CjkRP25Vja4kBsAHo5pawjeTCZytazCP4txPcYjEEdux` |
| Deploy + init tx | `Bz1zEUWQn6yEDoN7NXzsAzmz36Jocthqed8TPsqw5ZsB` |
| Code upgrade 1 tx | `Fp1qX1hEAoiP6QwMf4t5oKwYosCsnKE3XhymFHXytcsU` (enforces the Chain Signatures derivation; state unchanged) |
| USDC (NEP-141) | `17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1` |
| MPC | `v1.signer`; enrollment key path `botled-enroll-v1` → Base `enrollSigner` `0x7dd9b26E03E355D2C59e972A355C9303B8d1Dd94` |
| Timelock | 86,400 s |

### Reproduce the wasm

```
near/build-wasm.sh          # rust 1.99.1, cargo-near 0.23.0, --locked; compares with near/wasm.sha256
```

The output must match `near/wasm.sha256`, which equals the on-chain code hash. Docker path (NEP-330):
`cd near/botled-registry && cargo near build reproducible-wasm`. See [`BUILD.md`](BUILD.md).

### Crates (`near/`)

- `botled-logic`: pure rules (settings, signup split, receipt parsing and pricing, tickets, timelock changes,
  Chain Signatures derivation, 1Click quote binding). No near-sdk.
- `botled-registry`: the near-sdk contract. Feature `derivation` is on by default.
- `sandbox-tests`: near-workspaces tests on a local neard sandbox (`gas.rs`, `derivation_upgrade.rs`).

### Main methods

| Method | What it does |
|---|---|
| `usdc.ft_transfer_call(registry, 20 USDC, {"signup":{base,sig}})` → `ft_on_transfer` | Signup. Checks token, amount, `ecrecover == base`, `base == chain_signature_base(sender)`, base not taken; splits 5/5/10. Any failure refunds the whole transfer |
| `ft_transfer_call(..., {"topup":{}})` | Adds to the runner's budget |
| `request_ticket(no_shows_covered, session_key)` (1 yoctoNEAR) | Charges $2 per new no-show, then has `v1.signer` sign a 7-day EIP-712 `Enroll` ticket with a session key, relayed to `pool.enroll` on Base |
| `record_run(request, response, signer_id, signature)` | Verifies a NEAR AI receipt against the lane's key class, bills the runner (max $0.20 per run, max 1 run per seat), logs it |
| `get_runs(from, limit)`, `run_count()` | Public 1,024-entry ring of billed runs (relay audit) |
| `request_exit()`, `finish_exit(account)`, `collect(account)` | Exit after `max(now, ticket_until) + 2 days`; balances owed are pull-based (`owed_to`) |
| `chain_signature_base(account)` | The Base address the registry accepts for `account` |
| `signup_message(account, base)` | The message the runner's Chain Signatures key signs for signup |
| `propose(change)`, `apply(id)`, `cancel(id)`, `get_pending()` | Owner changes behind the timelock: `Params`, `Recipients`, `Lanes`, `AddSigner`, `Sponsors`, `Pool`, `Owner`, `RewardBridge` |
| `retire_signer(id)` | Owner can retire a NEAR AI key at once (only stops it) |
| `get_settings()`, `get_owner()`, `get_runner(account)`, `runner_of(base)` | Views |
| `bridge_penalties(payload, signature)` | Optional bounded USDC → Base path for penalties; disabled while `reward_bridge` is unset |

### Settings at deploy (`deploy/near-registry-init-args.json`)

| Param | Value |
|---|---|
| signup fee / profit cut / dev cut | 20 / 5 / 5 USDC |
| no-show penalty | 2 USDC (to `penalty_to`) |
| min ticket budget | 1 USDC |
| ticket TTL / exit delay | 7 days / 2 days |
| max cost per run / max runs per seat | 0.20 USDC / 1 |
| kimi-k3 price (Gateway) | 3.30 in / 16.50 out USD per M tokens |
| DeepSeek-V4.1-Flash-1017 price (ProviderTee) | 0.30 in / 1.20 out USD per M tokens |
| NEAR AI keys | gateway ecdsa `0xb98a…e779`, gateway ed25519 `40599f…4acb`, DeepSeek TEE ecdsa `0xfe00…337e`, DeepSeek TEE ed25519 `236f5a…da4c` |
| sponsors (NEAR) | `2a193115…5a91`, `4a9aec07…4d60` |
| recipients | all three currently `ea850d69…b230`; see pending change 0 |

## Base (chain id 8453)

v5/NEAR contracts, deployed 20 Nov 2026:

| Contract | Address | Basescan source |
|---|---|---|
| BotledNearConfig | [`0xAdb89C4fb606d346BA62F58C4B0e0F47c3e9F20a`](https://basescan.org/address/0xAdb89C4fb606d346BA62F58C4B0e0F47c3e9F20a#code) | verified |
| BotledNearVerifier | [`0x5B649acd02838b33777FdBaEe49D9FC405A62483`](https://basescan.org/address/0x5B649acd02838b33777FdBaEe49D9FC405A62483#code) | verified |
| SCL_EIP6565 (library, ed25519) | [`0x4C10947994b0A0bA262Fc840EaBc3cE6e08FbbB2`](https://basescan.org/address/0x4C10947994b0A0bA262Fc840EaBc3cE6e08FbbB2#code) | verified |
| CageSeat (library) | [`0x3DD3443ea1712CA30a9797Ea4DFD341641CEa5F1`](https://basescan.org/address/0x3DD3443ea1712CA30a9797Ea4DFD341641CEa5F1#code) | verified |
| CageVotes (library) | [`0x90dfe90aC041aB64d7302282885144605bedfA94`](https://basescan.org/address/0x90dfe90aC041aB64d7302282885144605bedfA94#code) | verified |
| CageSettle (library) | [`0x404864C55e883D9b74be6FDfF5cFBcCD18d8fB58`](https://basescan.org/address/0x404864C55e883D9b74be6FDfF5cFBcCD18d8fB58#code) | verified |
| BotledRunnerPoolNear | [`0x4fE84CAe74039df848BEe0c7E7Dd9A4eAfaFf7EF`](https://basescan.org/address/0x4fE84CAe74039df848BEe0c7E7Dd9A4eAfaFf7EF#code) | verified (+ Sourcify full match) |
| BotledFactoryV5Near | [`0xaa7Ee7d31c4fC44060b47C34c6AcaF2ea271F819`](https://basescan.org/address/0xaa7Ee7d31c4fC44060b47C34c6AcaF2ea271F819#code) | **Sourcify full match only** (Basescan bytecode mismatch from the embedded cage implementation's linked-library metadata) |
| BotledCageV5Near implementation | [`0x14F7f6A60A96cce95575c5f3Bdf45277809546e4`](https://basescan.org/address/0x14F7f6A60A96cce95575c5f3Bdf45277809546e4#code) | verified (+ Sourcify full match); created by the factory constructor |

Pool parameters: reward token AZL, VRF wrapper `0xb0407dbe851f8318bd31404A49e658143C982F23`, `maxConcurrent` 4,
3 request confirmations. Config signer slots: 0–3 NEAR AI keys (as above), 4 sponsor relay A
`0x893DE9AAbd116E501Fe46466DF830251497FBdA7`, 5 sponsor relay B `0x9Aa579Bcef7F8836CBF55bAfA4aceA69F1721cF6`.
Config timelock 1 day. Lane HEAD/TAIL hashes and the prompt/rubric hashes are in `deploy/mainnet-near-v5.json`.

No cage yet: `deployCage` needs `BotledConfig.isSupportedArbitration(standard)`, which is currently false.

Shared contracts (also used by v4):

| Contract | Address |
|---|---|
| BotledConfig | `0x6A5785cc5e79Dc4c800367b54eA525c5e31040D7` |
| BotledPanelOwner | `0xF7E5A611154C8d30A03791409F2606C278597a04` |
| BotledEvidence | `0xb2466cef02e7bfdaa85f141602a8759d3d96bf12` |
| Azzle micro module / vault | `0x905E561B44E76fdeAF5F41Bc2c46ebCE4E5E02fE` / `0x54242151DDCe196314fba21FA630bF62D56a14B3` |
| Azzle standard module / vault | `0x1003592A2eeF71b15A21457910007b38B0e2027A` / `0xFeF0722d2f3ba0FEb59b3fd5dCAaF49e69BD5387` |
| AZL | `0x931517E9502F9d52CDF6F5AC7fca7925e2A1BBA3` |

Deploy scripts: `script/DeployBotledV5NearPhase1.s.sol`, `script/DeployBotledV5NearPhase2.s.sol`. Full record with
tx hashes and blocks: [`deploy/mainnet-near-v5.json`](deploy/mainnet-near-v5.json).

## Running a juror (agents and humans)

Start with the agent prompt: [`PROMPT.md`](PROMPT.md) (same text as <https://botled.vercel.app/agent-prompt.md>). The runner code is in `runner-near/`:

- `loop.ts`: the `Runner` (ticket with session key, seat watch, inference via the sponsor relay, commit, reveal).
- `relay.ts`: the sponsor relay. `chainsig.ts`: Chain Signatures derivation. `near.ts`: NEAR JSON-RPC client.
- `tools/verify-attestation.ts`: re-verify the NEAR AI TEE attestation against `attestation-pins.json`.
- `tools/audit.ts`: read-only relay audit (NEAR `get_runs` vs Base `Revealed`).

Main environment: `BOTLED_NEAR_REGISTRY` (set it to the registry account above), `BOTLED_POOL`, `BOTLED_CAGE`,
`SPONSOR_URL` (comma-separated list for failover), optional `NEAR_AI_API_KEY` for the own-key fallback, `BASE_RPC`.
Nothing is sent unless `BOTLED_SEND=1`. Runners need no Base ETH: commits are signed with the session key and relayed.

If the relay is down, a runner can call NEAR AI with its own key: that reveal proves liveness (no penalty) but is not
counted and earns no reward.

## Costs per case (`DESIGN.md` §7)

| Lane | Real run (2026-11-20) | Worst case at `max_tokens` |
|---|---|---|
| kimi-k3 (`max_tokens` 6000) | $0.0081 | ≈ $0.10 |
| DeepSeek-V4.1-Flash (`max_tokens` 8000) | $0.00086 | ≈ $0.01 |

| | 3 jurors | 7 jurors | 15 jurors |
|---|---|---|---|
| Inference (typical, lanes alternate) | ≈ $0.017 | ≈ $0.036 | ≈ $0.07 |
| Base gas (commit + real-receipt reveal per juror, bind once) | ≈ 2.6M | ≈ 5.6M | ≈ 11.5M |

The $10 budget covers about 1,000+ seats at typical sizes. NEAR calls cost under 0.0004 NEAR each (§6).

## Tests

```
forge test                                   # Solidity (needs forge-std + azzle-v2, see BUILD.md)
FORK_BASE=true forge test --match-contract MainnetPhase1Fork   # against the deployed Base contracts
cd near && cargo test -p botled-registry && cargo test -p botled-logic --features derivation
cd near/sandbox-tests && cargo test          # neard sandbox: gas, derivation upgrade
cd runner-near && npm install && npm run typecheck && npm run selftest && npm run e2e   # local anvil + mocks
```

Last recorded results (20 Nov 2026): forge 112/112, `botled-registry` 20, `botled-logic` 24, sandbox
`derivation_upgrade` and `gas` passing, runner-near selftest 11 checks and e2e OK (`DESIGN.md` §9, §12, `PROGRESS.md`).
Real NEAR AI receipts for both lanes are in `test/near-vectors/real/`.

## Legacy v4

The v4 cage is a separate, earlier deployment (Base-only, AZL runner bonds). It is unchanged by v5/NEAR.

| Contract | Address |
|---|---|
| BotledRunnerPool v4 | `0xD2dEF94F5470C0B4AFa0E651427B9a1b100DB8b2` |
| BotledFactory v4 | `0x8297A533bFAE66c1529ce75C425AC2F462DDe073` |
| BotledArbitrator v4 implementation | `0xBd24ADaA60175c9AeE6F17194217508F4B7632Ac` |
| v4 cage (micro only) | `0xe16bF0267C36dA27a037F8340BdE2909B117EFb2` |

Legacy code still in the tree, **not part of v5/NEAR and never deployed as v5**: the earlier Base-only "Surplus" v5
design (`src/botled/v5/`, `script/DeployBotledV5.s.sol`, `deploy/v5-deploy-plan.md`, `test/BotledV5.t.sol`), and the
v4/Surplus runner in `runner/` with its old prompt, now at `legacy/PROMPT-surplus.md`. Use `runner-near/` for v5/NEAR.

## License

MIT. See `LICENSE`.
