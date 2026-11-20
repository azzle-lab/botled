# Botled v5/NEAR: provable-LLM juries with NEAR identities

Status: DEPLOYED 2026-11-20 (NEAR registry + Base BotledNearConfig/Verifier/libraries/RunnerPoolNear/FactoryV5Near; see deploy/mainnet-near-v5.json). No cage yet. Earlier note: before that, nothing had been deployed or broadcast on any chain. The only transactions ever sent went
to a throwaway local anvil chain (chain id 31337) in `runner-near/e2e.ts`. The live v4 cage
(0xe16bF0267C36dA27a037F8340BdE2909B117EFb2) and `/workspace/llm-arbitrator/runner` were left untouched. No Azzle code
was changed: Azzle v2 contracts are only imported in tests and in the local deploy script.

This revision implements the eight approved recommendations ("nimm deine empfehlungen"):

| # | Decision | Where |
|---|---|---|
| 1 | Lanes are `moonshotai/kimi-k3` (NEAR AI gateway key) and `deepseek-ai/DeepSeek-V4.1-Flash-1017` (NEAR-hosted TEE with its own key). Each lane has its own key class (`Lane.receiptKind`). GLM is dropped | `BotledNearConfig`, `BotledNearVerifier`, `registry.rs` (`LanePrice.receipt_kind`), `lanes.ts` |
| 2 | By default the Botled sponsor relay pays NEAR AI and bills the runner's NEAR budget. A runner can still use its own key, but only for liveness | `runner-near/relay.ts`, `record_run` |
| 3 | Only sponsor-co-signed receipts count as votes. The relay makes exactly one request per juror seat. Co-signing twice for one seat is a public fraud proof | `KIND_SPONSOR`, `sponsorDigest`, `reportEquivocation`, cage `counted` |
| 4 | Receipts use ECDSA as the primary scheme, and the ed25519 slot stays as a fallback | config signer slots |
| 5 | A no-show costs a $2 penalty, which goes to the reward fund (`penalty_to`). Tickets last 7 days. The exit delay is 2 days | `registry.rs` `Params::default` |
| 6 | Rewards are paid on Base in AZL (`rewardPerRound` from the pool), to counted votes only | `BotledRunnerPoolNear.settleDraw(status[])` |
| 7 | The cage assigns each seat's lane deterministically: `lane = (seat − 1) % laneCount`, where the seat is the 1-based VRF draw order. The two-provider rule stays | `BotledCageV5Near.reveal`, `pool.seat` |
| 8 | Each ticket carries a session key. It signs relayed commits, so a commit needs no Chain Signatures call | `Enroll(..., address sessionKey)`, `pool.sessionKeyOf`, `commitFor` |

## 1. Goals → mechanisms

| Requirement | Mechanism |
|---|---|
| Every runner provably runs an LLM | Each reveal carries a **NEAR AI receipt**, checked on Base. For kimi it is the gateway signature over `sha256(request):sha256(response)`. For DeepSeek it is the model-TEE signature over `model:sha256(request):sha256(response)` |
| Only verifiable models | The two lanes are pinned in the `BotledNearConfig` template, with `minProviders = 2`. Each lane accepts one key class only: gateway (1) or provider_tee (2). A provider_tee key is also bound to `keccak(model)` |
| The request is the real case | The request bytes must equal `HEAD(lane) ‖ juror line ‖ USER(case) ‖ TAIL(lane)`. HEAD pins the model and the system prompt. TAIL pins decoding, `max_tokens` and the JSON schema. USER is bound on-chain to Azzle's evidence hashes. The juror line pins runner, round and case |
| The answer is the model's answer | The cage parses the ruling out of the signed response, from `choices[0].message.content`, and ignores `reasoning_content`. The revealed vote must equal that ruling |
| No resampling | Only a receipt co-signed by a sponsor relay counts, and the relay serves one run per seat. Two co-signed runs for one seat retire the relay key (`reportEquivocation`, permissionless). NEAR billing also allows one run per seat |
| Signup from the runner's NEAR address, $20 USDC | `ft_on_transfer` splits it into $5 profit, $5 dev and a $10 budget |
| NEAR controls the Base identity | The Base address is the Chain Signatures address of `(runner, "base-1")`. Session keys are authorised only through an MPC-signed ticket |
| No minority slash, no AZL bond | There are no bonds. A no-show suspends the runner until NEAR has charged it $2 into the reward fund |
| Kept from v5 | VRF juries, commit/reveal, appeals with 3/7/15 jurors, the PanelOwner join flow, and the micro and standard panels |

## 2. Components

```
NEAR                                              Base
────                                              ────
botled-registry (near/)                           BotledNearConfig   (Ownable2Step + timelock ≥1d)
  USDC signup/top-up, budgets                       signer slots: kind 1 gateway | 2 provider_tee (model-bound) | 3 sponsor
  record_run: receipt → lane key class → cost       lanes: model, provider, HEAD/TAIL hash, receiptKind
  request_ticket(no_shows, session_key)             sponsorDigest / reportEquivocation (fraud proof)
     ──v1.signer(registry,"botled-enroll-v1")──►    enrollSigner = MPC address of (registry, "botled-enroll-v1")
     EIP-712 Enroll{..., sessionKey} ───────────►  BotledRunnerPoolNear (VRF draws, seats, tickets, session keys, AZL rewards)
runner NEAR account ──v1.signer(runner,"base-1")─► BotledCageV5Near (seat lane, counted vs liveness reveals)
sponsor relay (runner-near/relay.ts)               BotledNearVerifier (layout, sha256, key class, signature, sponsor, ruling)
  1 NEAR AI call per seat, record_run, co-sign     SCL_EIP6565 (linked library, ed25519 fallback; legacy pipeline)
NEAR AI Cloud (external anchor)                    BotledFactoryV5Near (clones; anchors the pool)
  gateway 0xb98a…e779 (ecdsa) / 40599f…4acb (ed25519)
  DeepSeek-V4.1-Flash TEE 0xfe00…337e (ecdsa) / 236f5a…da4c (ed25519)
```

### Files
- `src/botled/v5near/`: the contracts and `interfaces/IBotledNear.sol` (shared `INearVerifier.Receipt` struct)
- `script/DeployLocalNear.s.sol`: deploys the full stack to a **local anvil only** (it refuses any chain id ≠ 31337), for the e2e test
- `near/botled-logic` (pure rules), `near/botled-registry` (near-sdk contract), `near/sandbox-tests` (gas on a neard sandbox)
- `runner-near/`:
  - `lanes.ts`, `request.ts`, `nearai.ts`, `digests.ts`, `chainsig.ts`, `abi.ts`
  - `relay.ts`: the sponsor relay
  - `loop.ts`: the `Runner` class
  - `mock/`: NEAR AI, NEAR registry and MPC stand-ins
  - `e2e.ts`, `selftest.ts`
  - `near.ts`: production NEAR client (JSON-RPC + Borsh + ed25519; replaces the mock outside tests)
  - `audit.ts` + `tools/audit.ts`: relay audit (NEAR `get_runs` ↔ Base `Revealed`)
  - `tools/fetch-real-receipt.ts`, `tools/verify-attestation.ts`, `tools/testnet-ticket.ts`, `tools/bridge-penalties.ts`, `tools/swap-rewards.ts`
  - `attestation-pins.json`: the NEAR AI keys pinned on-chain + NVIDIA CA fingerprint
- `tools/attest/`: Rust TDX/DCAP verifier for NEAR AI attestation reports (dcap-qvl)
- `near/build-wasm.sh`, `near/wasm.sha256`: pinned registry build
- `src/botled/v5near/lib/Cage{Seat,Votes,Settle}.sol`: linked libraries split out of the cage; `rewards/BotledRewardSwapper.sol` (optional)
- `test/near-vectors/real/`: the real paid NEAR AI receipts for both lanes plus the DeepSeek attestation report. They contain no API key

## 3. Flows

### 3.1 Signup (NEAR, once)
This step is unchanged:
1. The client derives `base = addr(v1.signer, runner.near, "base-1")`.
2. It has `v1.signer` sign the EIP-191 hash of `signup_message`.
3. It calls `usdc.ft_transfer_call(registry, 20 USDC, {"signup":{base,sig}})`.
4. The registry checks the token, the amount, `ecrecover == base`, that **base equals the runner's v1.signer address** (`derive(mpc_root, runner, "base-1")`, feature `derivation`, on by default since 2026-11-20; view `chain_signature_base(account)`; +~3.9 Tgas, signup 6.69 Tgas), and that the base address is not already taken. It then splits the $20 into 5/5/10. Any failure panics, so NEP-141 refunds the whole transfer.

### 3.2 Enrollment ticket with a session key (NEAR → Base, about weekly)
1. The runner generates a **fresh session key** locally and reads `noShows` from `pool.runners(base)`.
2. It calls `registry.request_ticket(noShows, sessionKeyAddress)` with 1 yoctoNEAR attached.
3. The registry charges $2 for every new no-show. The money goes to `penalty_to`, the reward fund, which is converted to AZL and paid in through `pool.fundRewards`.
4. The registry bumps `epoch`, sets `validUntil = now + 7 days`, and gets the MPC signature over
   `Enroll(runner, nearAccount, epoch, noShowsCovered, validUntil, sessionKey)`.
5. Anyone relays `pool.enroll(..., sessionKey, sig)`. The pool stores `sessionKey`, and every new ticket **replaces** it. The old session key therefore dies with the next ticket, or after 7 days at the latest.
6. A runner is drawable while it is `listed`, `now ≤ validUntil`, `noShows ≤ noShowsCovered` and it has free capacity.

### 3.3 Case: draw → evidence → inference → commit → reveal → payout
1. `openCase` captures Azzle's evidence hashes and requests a VRF draw. `pool.seatOf` records each drawn runner's 1-based seat in draw order.
2. `bindEvidence(scope, posterDoc, workerDoc)` is permissionless and runs once. It checks the docs against Azzle's hashes. Gas: 324k.
3. **Seat lane.** `lane = (seat − 1) % 2`, so seats 1, 3, 5, … are kimi-k3 and seats 2, 4, … are DeepSeek. The runner cannot choose its lane. Any majority of 3 or more seats with two lanes must therefore include a DeepSeek seat.
4. **Inference through the sponsor relay (counted).** The runner POSTs its canonical request bytes to the relay. The relay:
   - parses the single juror line;
   - checks on Base that the case's round and inputHash match, that the runner holds a seat, and that the request's model and `max_tokens` belong to that seat's lane;
   - checks that it has **never** served this seat. A repeat call returns the stored receipt, and a different request for a served seat is refused;
   - calls NEAR AI with Botled's key, verifies the receipt text, and calls `record_run`, which bills the runner's budget and leaves a public log;
   - co-signs `sponsorDigest(runner, round, inputHash, sha256(req), sha256(resp))`, which is EIP-191 over
     `keccak(abi.encode(keccak("SponsoredRun(address runner,uint8 round,bytes32 inputHash,bytes32 requestSha256,bytes32 responseSha256)"), chainid, nearConfig, …))`.
5. **Own-key fallback (liveness only).** If the relay is down or refuses, the runner calls NEAR AI with its own key and bills itself with `record_run`. Its reveal proves it did the work, so there is no no-show penalty. It is **not tallied and earns no reward**; the votes marker is `bytes32(1)`.
6. **Commit.** The commitment is `keccak(cage, arb, taskId, round, runner, inputHash, outcome, bps, salt)`. The lane is no longer part of it, because the cage derives the lane from the seat. The runner signs the EIP-712 `Commit` with its **session key** and anyone relays `commitFor`, which accepts either the runner key or `pool.sessionKeyOf(runner)`. The Chain Signatures key still works for this. Runners hold no Base ETH. Gas: 110k with the MPC key, 113k with a session key.
7. **Reveal** (permissionless) takes `(arb, taskId, runner, outcome, bps, salt, Receipt{request, response, signerId, signature, sponsorId, sponsorSig})`. The verifier checks:
   - the layout for the seat's lane;
   - the sha256 of both blobs;
   - that `signer.kind == lane.receiptKind`, and that a TEE key's `modelHash == keccak(model)`;
   - the NEAR AI signature;
   - the ruling.

   If `sponsorId ≠ 0`, it also checks that the sponsor key is an active kind-3 ECDSA key and that its signature is valid. Only then is the vote counted.
8. `closeRound`: a majority needs more than half of the jury size in **counted** votes and at least 2 distinct lanes. `settleDraw(status[])` uses 0 for no-show (`noShows++`), 1 for liveness (no penalty, no reward) and 2 for counted (an equal share of `rewardPerRound` AZL).

### 3.4 Top-up and exit
- Top-up: `ft_transfer_call(..., {"topup":{}})`.
- Exit: call `request_exit()`. Once `max(now, ticket_until) + 2 days` has passed, call `finish_exit` and then `collect`. On Base the ticket expires and anyone can `delist` the runner.

## 4. Trust assumptions
1. **NEAR AI gateway key** (an external anchor, accepted by Daniel). For kimi-k3, which runs upstream at Chutes, we trust the gateway's word about what the upstream returned. Keys are timelocked for at least 1 day.
2. **DeepSeek TEE key.** The model runs on NEAR-hosted TEE hardware, and its signing keys (`0xfe00…337e` ecdsa, `236f…da4c` ed25519) appear in the attestation report (`test/near-vectors/real/deepseek.attestation.json`). Its signed text starts with the model id, and the Base signer slot is bound to `keccak("deepseek-ai/DeepSeek-V4.1-Flash-1017")`.
   - **Finding:** the same TEE compose also serves a `proxy-dsv41-abliterated` variant. Model binding therefore relies on the model-prefixed text plus `modelHash`; the key alone does not bind it. Tests cover this: a TEE receipt for another model is rejected.
   - We do not verify the TDX quote on-chain. Whoever proposes the key checks it off-chain before the timelocked `addSigner`.
3. **NEAR MPC network** (v1.signer) controls runner keys and the enrollment key. It can impersonate runners, but it cannot forge LLM answers.
4. **Registry and config owner.** Every change goes through a timelock. An owner can retire a key at once, which only stops it.
5. **Sponsor relay.** This is the new trust point.
   - *What it cannot do:* forge answers (it needs NEAR AI's signature), vote for a runner, or co-sign two runs for one seat without losing its key on the first fraud proof (`reportEquivocation` is permissionless and retires the key in the same transaction).
   - *Censorship* (refusing or delaying a seat). Mitigations:
     - the runner falls back to an own-key liveness reveal, so it suffers no penalty, but its vote is not counted;
     - several sponsor keys can be added (timelocked), and runners may use any of them;
     - refusals are visible: compare the `record_run` log on NEAR with the liveness-only `Revealed(counted=false)` events on Base;
     - a censored seat reduces the counted votes, so the case escalates (appeal or another round) rather than settling wrongly.
   - *Silent resampling* (the relay calls NEAR AI several times and co-signs the answer it prefers). This needs no double signature, so the fraud proof does not catch it. Mitigations:
     - every billed run appears on NEAR before co-signing, and `max_runs_per_seat = 1` is enforced there;
     - NEAR AI usage on the relay's key can be audited against `record_run`;
     - temperature 0 and seed 0 make outputs largely deterministic;
     - the two-provider rule means a single relay would need to bias two different models.

   A colluding relay plus a minority of runners still cannot outvote honest counted votes.
6. **Evidence availability:** anyone holding the docs can bind them, and the hash check prevents forgery.

### Why no Base collateral
A vote cannot be forged: it needs a receipt for this runner, round and case, under the pinned prompt and model, plus a sponsor co-signature. The only fault left is liveness, which is handled by suspension plus the $2 penalty into the reward fund.

## 5. Signatures and gas on Base

| Check (forge, fixture sizes ~3.5 KB) | Gas |
|---|---|
| receipt check, ECDSA gateway (unsponsored) | 304,097 |
| receipt check, ECDSA gateway + sponsor | 324,130 |
| receipt check, DeepSeek TEE + sponsor | 369,826 |
| receipt check, ed25519 fallback | 1,059,637 |
| ed25519 verify, real gateway sig (41 B) | 502,988 |
| `bindEvidence` (~160 B docs) | 323,923 |
| `commitFor`, Chain Signatures key | 109,713 |
| `commitFor`, session key | 113,180 |
| `reveal` kimi, ECDSA + sponsor | 558,173 |
| `reveal` DeepSeek, TEE + sponsor | 514,561 |
| `reveal` kimi, ed25519 + sponsor | 1,267,163 |
| `reveal`, liveness-only (own key) | 475,909 |

**Real receipts** (kimi 1.9 KB / DeepSeek 3.2 KB responses with `reasoning_content`). The parser now scans 32-byte
words with an exact per-byte `"` mask (SWAR) and only inspects quote positions; uniqueness of the top-level
`"content"` key is unchanged and the receipt is still hashed over the exact raw signed bytes.

| Real receipt (`testRealChatReceipts`, `verifier.check` only) | ECDSA | ed25519 |
|---|---|---|
| kimi-k3 (gateway) | 219,148 (was 855,459) | 982,153 |
| DeepSeek-V4.1-Flash (TEE) | 251,543 (was 1,159,320) | 1,016,817 |

**Full `reveal` with the real receipts** through the real cage (`testRealReceiptsFullRevealGas`: openCase → VRF seat on
the right lane → bindEvidence → commit → reveal; only `inputHash`/`scopeHash` are patched in storage). Execution gas;
a Base tx adds 21k + calldata (~81k kimi, ~102k DeepSeek):

| | sponsored (counted) | own key (liveness) |
|---|---|---|
| kimi ECDSA | **506,945** | 431,862 |
| kimi ed25519 | 1,269,688 | 1,194,709 |
| DeepSeek ECDSA | **560,142** | 485,734 |
| DeepSeek ed25519 | 1,325,158 | 1,250,912 |

Contract sizes (runtime, limit 24,576): **BotledCageV5Near 20,699 (3,877 B headroom)**, linked libraries CageSeat
3,978 / CageSettle 2,617 / CageVotes 843, BotledNearVerifier 13,422, BotledNearConfig 10,669, BotledRunnerPoolNear
10,449, BotledFactoryV5Near 3,569, BotledRewardSwapper 3,754. (The older Base-only `BotledCageV5` is not part of this
deployment: 1,432 B headroom.)

## 6. NEAR gas (near-workspaces 0.24, local neard sandbox, `near/sandbox-tests/tests/gas.rs`)

| Call | Gas |
|---|---|
| `new` | 1.84 Tgas |
| signup (`ft_on_transfer`, ecrecover) | 2.68 Tgas |
| top-up | 2.00 Tgas |
| `record_run` kimi (3.5 KB request, incl. audit ring entry) | 3.98 Tgas |
| `record_run` DeepSeek TEE (3.5 KB request, incl. audit ring entry) | 4.02 Tgas |
| `request_ticket` (registry part; the MPC sign happens on mainnet v1.signer) | 0.31 Tgas own, 6.06 Tgas incl. promise |
| `request_exit` | 1.94 Tgas |

At 0.1 mNEAR/Tgas every call costs under 0.0004 NEAR. The registry wasm (`near/build-wasm.sh`: rust 1.99.1, cargo-near 0.23, `--locked`) is 316 KB, sha256 `1e24c242…2b4c0b` (pinned in `near/wasm.sha256`), about 3.2 NEAR of storage stake; the 1,024-entry run ring adds up to ~2 NEAR. With session keys, commits need **no** MPC sign. Only the weekly ticket does (~0.025 NEAR).

## 7. Cost per case
Prices are NEAR AI `/v1/model/list` USD per million tokens: kimi-k3 3.30 in / 16.50 out; DeepSeek-V4.1-Flash 0.30 in / 1.20 out. `max_tokens` is sized for reasoning models, whose reasoning tokens count as completion tokens: **kimi 6000, DeepSeek 8000**. `max_cost_per_run` is $0.20.

| Lane | Real run (2026-11-20) | Cost | Worst case at max_tokens |
|---|---|---|---|
| kimi-k3 | 733 in / 344 out (221 reasoning) | **$0.0081** | ≈ $0.10 |
| DeepSeek-V4.1-Flash | 559 in / 578 out (506 reasoning) | **$0.00086** | ≈ $0.01 |

| | 3 jurors | 7 jurors | 15 jurors |
|---|---|---|---|
| Inference (typical, lanes alternate) | ≈ $0.017 | ≈ $0.036 | ≈ $0.07 |
| Base gas (commit 113k + real ECDSA reveal ~0.6–0.7M tx gas per juror, bind once) | ≈ 2.6M | ≈ 5.6M | ≈ 11.5M |

The $10 budget covers about 1,000+ seats at typical sizes.

## 8. Real NEAR AI receipts (done, test vectors)
`runner-near/tools/fetch-real-receipt.ts` sent the exact canonical request bytes (the `VECTOR_CASE` juror line, the real system prompt and schema, the lane's `max_tokens`) to `cloud-api.near.ai`. It then fetched `/v1/signature/{id}` for both `ecdsa` and `ed25519`. The API key came only from the environment; it was never printed or written. Total spend was **≈ $0.009**.

| Lane | request sha256 (= Solidity/TS/Rust vector) | signature_kind | ECDSA signer | ed25519 signer |
|---|---|---|---|---|
| kimi-k3 | `67e0b21a…8715f` | gateway | 0xb98a…e779 | 40599f…4acb |
| DeepSeek-V4.1-Flash-1017 | `f88f96f5…dd640` | provider_tee (`model:` prefix) | 0xfe00…337e | 236f5a…da4c |

- NEAR AI hashed **our exact bytes**. It did not re-encode the request: the request hashes equal the cross-language vectors.
- Both models answered `WORKER_WINS / 10000`, and the parser ignores the `reasoning_content`.
- All 4 signatures (2 lanes × ECDSA and ed25519) verify:
  - in Rust: `botled-logic::real_near_ai_chat_receipts`, with the keys pinned in the test;
  - in Solidity: `NearReceipt::testRealChatReceipts`, through the full `BotledNearVerifier.check`, with the keys pinned and the outcome asserted. The same receipt is rejected for the other lane.

## 9. Tests
- `forge test`: **111 passed, 0 failed** (9 suites), incl. full real-receipt reveals, the 2-sponsor retirement test and the
  reward swapper (7 incl. fuzz).
- `cargo test`: botled-logic 24 (`--features derivation`; incl. 5 1Click binding tests, one on a real 1Click-signed
  quote), botled-registry 15 (incl. run log and `bridge_penalties`), sandbox-tests 1 (neard; `get_runs` checked).
- `runner-near`: `tsc` strict clean; `selftest` 11 checks (incl. NEAR tx Borsh/signature == near-api-js 7.5.3);
  `e2e` OK: 4 runners, relay A + relay B (failover), own-key liveness seat, cross-relay resampling refused
  (`max_runs_per_seat`), Azzle SETTLED WORKER_WINS, audit `ok` with one LIVENESS finding, injected withheld run
  detected as `WITHHELD` against relay A.
- Live (free): `tools/verify-attestation.ts` 4/4; `tools/testnet-ticket.ts` real `v1.signer-prod.testnet` ticket;
  `tools/bridge-penalties.ts` dry 1Click quote within bounds.

## 10. Pre-mainnet hardening (2026-11-20)

### 10.1 NEAR AI attestation (`tools/verify-attestation.ts` → `tools/attest`)
Fresh report per key with a random nonce, for gateway (ecdsa, ed25519) and DeepSeek-V4.1-Flash-1017 (ecdsa, ed25519).
Result 2026-11-20: **all 4 pass, attested keys == pinned keys, TCB UpToDate, 8× H100 (HOPPER) GPU attestation true.**

Cryptographically verified:
- Intel TDX quote v4 (dcap-qvl 0.7.1: PCK chain → Intel SGX Root CA pinned inside dcap-qvl, TCB info, QE identity, CRLs).
- `report_data` = key (or address‖0¹²) ‖ our nonce → no replayed report; for ECDSA also keccak(pubkey) = address.
- MRTD/RTMR0–3 = `tcb_info`; RTMR3 = replay of the event log; compose-hash event = sha256(app_compose) = compose_hash.
- compose-manager quote: same TD (MRTD, RTMR0–2), `report_data` = sha256(canonical action log) ‖ nonce; the last
  `compose_up` (file `prod/deepseek-v4.1-flash-1017-vllm-dep4x2.yaml`, its sha256 and git commit) is reported.
- NVIDIA: NRAS EAT JWT + every per-GPU JWT ES384-verified against NVIDIA's JWKS, x5c chain checked, per-GPU digests,
  overall result true, `eat_nonce` = our nonce.

Relies on pinned roots / trust:
- Intel SGX root inside dcap-qvl; PCCS/Intel PCS only as collateral transport (signed).
- NVIDIA: JWKS fetched over TLS; chain top pinned by fingerprint (TOFU, `attestation-pins.json`). The GPU evidence is
  nonce-fresh but NOT cryptographically bound to the TD quote (NVIDIA/NEAR AI design gap).
- The compose file contents are only identified by sha256 + commit (NEAR AI repo); what vLLM serves is not proven.
- **The same TD also runs `proxy-dsv41-abliterated`** (a modified DeepSeek variant). The TEE key is per TD, so the
  `model:` prefix in the signed text (signed by NEAR AI's proxy code) is what separates the variants. Accepted as part
  of the NEAR AI external anchor; re-run the verifier before every `proposeSigner` and periodically.

### 10.2 Relay hardening
- Several sponsor keys (kind 3) are active at once; e2e and the deploy script use two relays. Equivocation retires one key
  at once (`reportEquivocation`), votes co-signed by the other keep counting (forge
  `testSecondSponsorKeepsJuriesRunningWhenOneIsRetired`). New keys take the 1-day timelock, so keep ≥2 live keys.
- `Revealed` now carries `sponsorId`; the registry keeps a 1,024-entry ring of billed runs (`get_runs`, `run_count`);
  relays expose `GET /seats`, `GET /health`. Runners take a comma-separated relay list and fail over; if the own-key
  `record_run` is refused (a relay billed the seat and withheld), the runner still reveals liveness.
- `tools/audit.ts` (read-only) flags `UNBILLED_SPONSORED`, `WITHHELD` (attributed to the billing relay), `LIVENESS`,
  `NO_SHOW`, `SEAT_MISMATCH` and per-relay billed/delivered/withheld counters.
- Residual: one relay can still bill-then-withhold a seat (max_runs_per_seat = 1 blocks the others); it is detected and
  attributable, not prevented.

### 10.3 Production NEAR client and build
- `runner-near/near.ts` implements `Near` with JSON-RPC (`query`, `send_tx` EXECUTED_OPTIMISTIC), Borsh tx encoding
  (FunctionCall, DeployContract) and ed25519 signing; vector-checked against near-api-js. Keys from env or
  `~/.near-credentials`, never logged; FunctionCall access-key limits are checked before sending.
- Live reads confirmed the pinned mainnet `v1.signer` root; testnet root `v1.signer-prod.testnet` added.
- **Testnet run (free faucet accounts, no money):** deploy of the pinned wasm, signup signed by
  `v1.signer-prod.testnet` for the derived Base address, `request_ticket` → MPC → ticket signature recovers to the
  derived `enrollSigner` 0x67bf…803c (`test/near-vectors/testnet-ticket.json`).
- `near/build-wasm.sh`: pinned toolchain, `--locked`, remapped paths; rebuilt from a different directory → same sha256.
  NEP-330 metadata (`sourcescan/cargo-near:0.23.0-rust-1.99.1@sha256:8013f0…`) for `cargo near build reproducible-wasm`
  (needs Docker + public git repo; `repository` is a placeholder).

### 10.4 Penalty USDC → AZL
Daniel funds the AZL reward fund (`pool.fundRewards`) himself for now. The bounded automatic path is ready but optional:
- NEAR: `bridge_penalties(payload, signature)` (permissionless) binds a 1Click-signed quote (pinned manager key):
  not dry, EXACT_INPUT, USDC(NEAR) → USDC(Base), recipient = configured Base address, refund to `penalty_to`,
  amountIn ≤ owed penalties and ≥ min batch, minAmountOut ≥ amountIn·(1 − cap ≤ 3%), deadline in the future, one use
  per quote, failed transfer re-credited. Disabled while `reward_bridge` is None (timelocked `Change::RewardBridge`).
- Keeper `tools/bridge-penalties.ts`: DRY by default (live dry quote 24 USDC → min 23.87 USDC, all bounds OK).
- Base: `BotledRewardSwapper` (no owner, no withdraw): swaps via an immutable router with keeper calldata, accepts only
  ≥ (1 − maxSlippageBps) of the USDC spent at the AzlUsdOracle par price, forwards all AZL to `fundRewards`;
  `tools/swap-rewards.ts` simulates. AZL is not listed on 1Click, so this Base leg is needed for full automation.

## 11. Open items (need Daniel before deploy)
1. Mainnet deploy itself (nothing was broadcast on any mainnet): NEAR registry account + `enrollSigner`, Base stack with
   linked SCL + Cage libraries, pinned NEAR AI keys (re-verify with `tools/verify-attestation.ts` right before),
   ≥2 sponsor keys/relays, pool anchored to the factory.
2. Accept or reject the `abliterated` variant sharing the DeepSeek TD (10.1).
3. Public repo URL for NEP-330 and a Docker `reproducible-wasm` run (or accept `near/build-wasm.sh` + sha256).
4. If automating penalties later: `penalty_to` account, Base router + `maxSlippageBps`/`maxInPerCall` for the swapper,
   and one `dry:false` 1Click quote to confirm the exact signed-payload format (keeper refuses to send if its local
   signature check fails).

## 12. Mainnet registry upgrade 1 (2026-11-20): chain-signature derivation enforced
- `botled-registry` builds with feature `derivation` by default. Signup panics with "base is not the runner's
  chain-signature address" unless `base == addr(derive(mpc_root, sender, "base-1"))`; the mainnet registry stores the
  v1.signer root (checked live). New view `chain_signature_base(account)`.
- wasm 357,622 B, sha256 `ae640bb3…5067` (near/wasm.sha256), deployed with a plain DeployContract (tx
  `Fp1qX1hEAoiP6QwMf4t5oKwYosCsnKE3XhymFHXytcsU`); contract state struct unchanged, so no migration. Read back: code
  hash, pending changes 0/1, settings and owner unchanged; `chain_signature_base("azzle.near")` = 0xae52…48fe
  (= runner-near chainsig.ts = v1.signer.derived_public_key).
- Tests: registry unit tests (accept MPC address, reject arbitrary key, reject another account's MPC address, real
  mainnet vectors, no root = not enforced) and `sandbox-tests/tests/derivation_upgrade.rs` (old mainnet wasm → new
  wasm on neard: state/pending/runners survive, wrong base refused, signup gas 6.69 Tgas).
