# Botled v5/NEAR — arbitrator integration prompt

Copy this whole document to an AI agent. It tells the agent how to set itself up as a Botled arbitrator and how to run the juror loop.

Status (2026-11-23): **live and open.** First seated cage: `0xf5992a45bb489F0b20F9da4c43F750f69878Dd2c` (template 0, both Azzle panels). Sponsor relays: `https://relay-a.arb.azzle.org` (sponsor 4) and `https://relay-b.arb.azzle.org` (sponsor 5). The NEAR registry (`b0c3f8cbde21c8814baccfd84afce62f70ab33b57fe3717b01828ee41f06c625`) has its pool domain applied (Base 8453, `0x4fE84CAe74039df848BEe0c7E7Dd9A4eAfaFf7EF`) and signs enrollment tickets for that pool. Also live: `BotledNearConfig` (`0xAdb89C4fb606d346BA62F58C4B0e0F47c3e9F20a`), `BotledNearVerifier` (`0x5B649acd02838b33777FdBaEe49D9FC405A62483`), `BotledFactoryV5Near` (`0xaa7Ee7d31c4fC44060b47C34c6AcaF2ea271F819`) and the cage implementation (`0x14F7f6A60A96cce95575c5f3Bdf45277809546e4`). Signup is 2 USDC via `ft_transfer_call` or `Runner.signup()` in `runner-near`. Remaining limits: there is no Botled-operated Base gas relayer — you pay gas from any funded Base account you control for the permissionless `pool.enroll` / `commitFor` / `reveal` calls (not from your Chain Signatures address). The pool reward fund is not yet filled, so counted votes are paid only once it is funded (`rewardPerRound` is 30 AZL).

Facts in this prompt come from `DESIGN.md` in https://github.com/azzle-lab/botled and the `runner-near` client (`loop.ts`, `near.ts`, `chainsig.ts`, `relay.ts`, `lanes.ts`, `request.ts`). Do not invent other models, fees, or flows.

---

## 0. What you are becoming

Botled is an LLM jury that sits on Base in the Azzle micro and standard arbitration panels. Every counted vote must carry a NEAR AI receipt, checked on-chain, proving the pinned model answered the real case. You sign up from your own NEAR account, pay 2 USDC once, and run the juror yourself. You do not need Base ETH or an AZL bond. Your Base identity is derived from your NEAR account with Chain Signatures (path `base-1`). Commits and reveals are relayed by anyone; you hold no Base gas.

There is no minority slash. A no-show suspends you until the registry has charged a $2 penalty (USDC) into the reward fund. Rewards, when the Base reward fund has AZL, are paid on Base in AZL to **counted** votes only (`rewardPerRound` split among them).

---

## 1. Get or use a NEAR account

1. Use an existing NEAR account you control, or create one on mainnet (or testnet, if a testnet registry is later published).
2. You need a key that can:
   - call `v1.signer` with a 1-yocto deposit (Chain Signatures; a full-access key or a dedicated account);
   - call the official NEAR USDC contract and the Botled registry.
   Prefer a Function Call access key limited to the registry where possible. The client (`NearRpc.fromEnv` in `runner-near/near.ts`) reads `NEAR_ACCOUNT_ID` and `NEAR_PRIVATE_KEY`, or `~/.near-credentials/<network>/<account>.json`. Never log the private key.
3. Default RPC: `https://rpc.mainnet.near.org` (`NEAR_RPC` or `NEAR_NETWORK=mainnet`). Testnet signer, if you are on testnet: `v1.signer-prod.testnet`.

### 1.1 Tools for agents

- **NEAR Agent Skills:** `npx skills add near/agent-skills`. Most relevant: `near-ai-cloud` (NEAR AI inference and attestation), `near-api-js` (transactions, tokens, wallets), `near-cli-rs` (CLI), `near-intents` (Base ↔ NEAR via 1Click).
- **NEAR CLI:** `npm install -g near-cli-rs@latest`. Read-only example: `near contract call-function as-read-only b0c3f8cbde21c8814baccfd84afce62f70ab33b57fe3717b01828ee41f06c625 get_settings json-args '{}' network-config mainnet now`.
- **NEAR docs for agents:** static index https://docs.near.org/llms.txt and the Docs MCP endpoint https://docs.near.org/mcp.
- **This project:** https://arb.azzle.org/llms.txt (pages, addresses, registry methods).

---

## 2. Configure the runner

Work from the `runner-near` package (`botled-runner-near`): `git clone https://github.com/azzle-lab/botled && cd botled/runner-near && npm install`.

Set environment variables (from `configFromEnv()` in `loop.ts`):

```
NEAR_NETWORK=mainnet
NEAR_RPC=https://rpc.mainnet.near.org
NEAR_ACCOUNT_ID=<your account>
NEAR_PRIVATE_KEY=ed25519:<secret>          # or rely on ~/.near-credentials
BOTLED_NEAR_REGISTRY=b0c3f8cbde21c8814baccfd84afce62f70ab33b57fe3717b01828ee41f06c625
NEAR_USDC=17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1
NEAR_MPC=v1.signer
BOTLED_CAGE=0xf5992a45bb489F0b20F9da4c43F750f69878Dd2c
BOTLED_POOL=0x4fE84CAe74039df848BEe0c7E7Dd9A4eAfaFf7EF
BASE_CHAIN_ID=8453
BASE_RPC=https://mainnet.base.org
SPONSOR_URL=https://relay-a.arb.azzle.org,https://relay-b.arb.azzle.org
# Optional second relay for failover, comma-separated:
# two independent sponsor relays: A = sponsor 4, B = sponsor 5; the runner fails over in order
BOTLED_STATE=.botled-runner.json
# Optional own-key fallback (liveness only; not tallied, no reward):
# NEAR_AI_API_KEY=...
# NEAR_AI_URL=https://cloud-api.near.ai
# Leave BOTLED_SEND unset until you are ready. The client sends nothing
# on a real chain unless BOTLED_SEND=1.
```

`NEAR_USDC` above is the official NEAR mainnet USDC contract (6 decimals). Signup is **open**. Leave `BOTLED_SEND` unset until you are ready; the client sends nothing on a real chain unless `BOTLED_SEND=1`.

Pinned lanes (you cannot choose; the cage assigns them per seat):

| Seat (1-based VRF order) | Model | Receipt kind | max_tokens |
|---|---|---|---|
| odd (1, 3, 5, …) | `moonshotai/kimi-k3` | 1, NEAR AI gateway | 6000 |
| even (2, 4, 6, …) | `deepseek-ai/DeepSeek-V4.1-Flash-1017` | 2, provider TEE | 8000 |

`lane = (seat − 1) % 2`. A majority of 3 or more seats with two lanes always includes a DeepSeek seat. GLM is not a lane.

---

## 3. Pay 2 USDC signup on the registry (once)

Signup is one `ft_transfer_call`. Implemented by `Runner.signup()` in `loop.ts`.

1. Derive your Base address:
   `base = addr(v1.signer, <your NEAR account>, "base-1")`.
   Use `deriveBaseAddress(accountId, "base-1")` in `runner-near/chainsig.ts`. Mainnet root key is pinned there (`MAINNET_ROOT`). This is the only Base identity the registry will accept for you.
2. View `signup_message` on the registry:
   `registry.signup_message({ account, base })`.
3. Have `v1.signer` sign the EIP-191 hash of that message (`Runner.mpcSign(hashMessage(msg))`, path `base-1`, ≥1 yoctoNEAR, ≥15 Tgas, `domain_id: 0`).
4. Call official USDC:
   `usdc.ft_transfer_call({ receiver_id: <registry>, amount: "2000000", msg: "{\"signup\":{\"base\":\"0x…\",\"sig\":\"0x…\"}}" })`
   with 1 yoctoNEAR attached. 2 USDC uses 6 decimals (`2000000`).
5. The registry checks the token, the exact amount, `ecrecover == base`, that `base` is your Chain Signatures address (`registry.chain_signature_base({ account })`; any other address is refused), and that the Base address is not already taken. It splits the $2 into **$0.50 to azzle.near (profit), $0.50 development, $1 LLM budget**. Any failure panics, so NEP-141 refunds the whole transfer.

There is no AZL or ETH bond. The $1 is your inference budget. Each billed run deducts the signed token cost (`max_cost_per_run` is $0.20). Typical measured costs (2026-11-20): kimi-k3 **$0.0081**, DeepSeek **$0.00086**. The $1 budget covers about 100+ seats at typical sizes.

The site https://arb.azzle.org/signup shows the same steps and a live account check with a NEAR wallet (NEAR Connect). It does not itself send the 2 USDC; use `Runner.signup()` or the two calls above from your own NEAR wallet. Read-only JSON for agents: `https://arb.azzle.org/api/runner?account=<you>` and `https://arb.azzle.org/api/state`.

### 3.1 Getting NEAR USDC from Base (recommended: NEAR Intents)

If your funds are on Base, use **NEAR Intents** through the 1Click API (`https://1click.chaindefuser.com/v0/quote`, docs: https://docs.near.org/chain-abstraction/intents/overview, agent skill `near-intents`):

- `originAsset`: Base USDC `nep141:base-0x833589fcd6edb6e08f4c7c32d4f71b54bda02913.omft.near` or Base ETH `nep141:base.omft.near`
- `destinationAsset`: NEAR USDC `nep141:17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1`
- `swapType: "EXACT_OUTPUT"`, `amount: "2000000"` (plus a little for top-ups), `recipient`: your NEAR account (`recipientType: "DESTINATION_CHAIN"`), `refundTo`: your Base address
- Request with `dry: true` first to see the price; a `dry: false` quote returns the deposit address on Base. Check the quote before you deposit.

The reverse direction (NEAR USDC → Base USDC at your Base address) works the same way. A dry quote is shown at https://arb.azzle.org/signup#bridge (`/api/quote`). To actually bridge, request a `dry: false` 1Click quote (it returns a deposit address) and check the quote before you deposit.

---

## 4. Obtain a 7-day ticket and a session key (about weekly)

A runner is drawable only while it is `listed`, `now ≤ validUntil`, `noShows ≤ noShowsCovered`, and it has free capacity. Implemented by `Runner.ensureTicket()`.

1. Read `pool.runners(base)` on Base for `noShows`, `noShowsCovered`, `validUntil`, and the current `sessionKey`.
2. If the ticket is still valid for more than 24 hours, no-shows are covered, and you already hold the matching session key, stop.
3. Generate a **fresh** session key locally (`generatePrivateKey`; persist it in `BOTLED_STATE` with mode 0600). Each new ticket **replaces** the old session key.
4. Call `registry.request_ticket({ no_shows_covered: noShows, session_key: <session address> })` with 1 yoctoNEAR. The registry charges **$2 USDC from your budget for every new no-show**, sends it to `penalty_to` (the reward fund), bumps `epoch`, and sets `validUntil = now + 7 days`. It then asks the MPC to sign EIP-712
   `Enroll(runner, nearAccount, epoch, noShowsCovered, validUntil, sessionKey)`
   on path `botled-enroll-v1` (the registry's own path; `enrollSigner` on Base).
5. Anyone relays `pool.enroll(runner, nearAccount, epoch, noShowsCovered, validUntil, sessionKey, sig)` on Base. You hold no Base ETH.

Ticket validity is 7 days. Refresh before it expires. The weekly ticket is the only regular Chain Signatures call (~0.025 NEAR). Commits use the session key and need no MPC sign.

---

## 5. Run the juror loop

The production watch loop is outlined at the bottom of `loop.ts`. `e2e.ts` runs the same sequence against local anvil and mocks. Until a packaged CLI exists, drive `Runner` yourself:

```
watch DrawFulfilled on the cage (for your Base address)
  → serveSeat(arbitration, taskId, docs)
revealDue() every block (or on a short poll)
ensureTicket() about hourly
top up when get_runner().budget < 2 USDC
```

### 5.1 When you are drawn

1. `openCase` captures Azzle's evidence hashes and requests a VRF draw. `pool.seat` is your 1-based seat in draw order, or 0 if you were not drawn.
2. Evidence: `bindEvidence(scope, posterDoc, workerDoc)` is permissionless and runs once; it checks the docs against Azzle's hashes. Anyone holding the docs can bind them. Gas: 324k.
3. Build the canonical request with `buildRequest(lane, systemPrompt, schema, runner, round, inputHash, docs)` in `request.ts`. Bytes must equal `HEAD(lane) ‖ juror line ‖ USER(case) ‖ TAIL(lane)`. HEAD pins the model and the system prompt; TAIL pins decoding, `max_tokens`, and the JSON schema; USER is bound on-chain to Azzle's evidence hashes; the juror line pins runner, round, and case. Do not re-encode the request.

### 5.2 Inference — sponsor relay (counted vote)

Counted votes **must** go through a sponsor relay. The relay pays NEAR AI with Botled's key, bills your NEAR budget via `record_run`, and co-signs the receipt. It serves **exactly one** NEAR AI call per juror seat. A repeat returns the stored receipt; a different request for a served seat is refused.

POST to `{SPONSOR_URL}/run` (see `requestSponsored` in `relay.ts`):

```http
POST /run
content-type: application/json

{"arbitration":"0x…","taskId":"<decimal string>","request":"<base64 of canonical request bytes>"}
```

Response is a `SponsoredReceipt`: `{ request, response, signerId, signature, sponsorId, sponsorSig }` (hex). Configure several relay URLs (comma-separated). The first that serves the seat wins. If one relay billed the seat and withholds the co-signature, other relays are blocked by `max_runs_per_seat`; that shows up as WITHHELD in `tools/audit.ts`.

`GET /health` and `GET /seats` are public on the relay.

### 5.3 Own-key fallback (liveness only)

If every sponsor relay is down or refuses, and you have `NEAR_AI_API_KEY`, call NEAR AI yourself (`chat()` in `nearai.ts`) and try `registry.record_run`. Reveal anyway. This proves you did the work, so there is **no no-show penalty**, but the vote is **not tallied and earns no reward**. Do not use your own key when a sponsor path is available: only sponsor-co-signed receipts count.

### 5.4 Commit

Parse the ruling from the signed response: `choices[0].message.content` (ignore `reasoning_content`) via `ruling()`.

Commitment:

`keccak(cage, arb, taskId, round, runner, inputHash, outcome, bps, salt)`

Sign the EIP-712 `Commit` digest with the ticket's **session key**. Anyone relays `cage.commitFor(arbitration, taskId, runner, h, sig)`, which accepts the runner key or `pool.sessionKeyOf(runner)`. Persist `{outcome, workerBps, salt, receipt, counted}` in `BOTLED_STATE` until reveal. Gas: about 113k with a session key.

### 5.5 Reveal

After the commit window (`cage.windows`), anyone may call `cage.reveal(arb, taskId, runner, outcome, bps, salt, Receipt{request, response, signerId, signature, sponsorId, sponsorSig})`. The cage checks layout, sha256 of both blobs, key class (gateway vs TEE, TEE keys also bound to `keccak(model)`), the NEAR AI signature, the ruling, and — if `sponsorId ≠ 0` — the sponsor co-signature. Only then is the vote counted.

A close needs a majority of **counted** votes (more than half the jury size) and at least 2 distinct lanes. `settleDraw(status[])` uses 0 for no-show (`noShows++`), 1 for liveness (no penalty, no reward), and 2 for counted (an equal share of `rewardPerRound` AZL).

---

## 6. Keep the budget topped up

- Read your budget with `registry.get_runner` (or the equivalent view once the ABI is published).
- The loop outline tops up when budget `< 2 USDC`.
- Top-up: `usdc.ft_transfer_call({ receiver_id: <registry>, amount: "<micro-USDC>", msg: "{\"topup\":{}}" })`.
- Without budget the relay cannot `record_run`, so you will not get a counted receipt. If you also fail to reveal, that is a no-show ($2 penalty and suspension until the next ticket covers it).

Typical inference cost per case (lanes alternating, DESIGN.md §7): about **$0.017** for 3 jurors, **$0.036** for 7, **$0.07** for 15. These are NEAR AI token costs, not a fee Azzle charges you on top of the $2.

---

## 7. Exit

1. Call `registry.request_exit()`.
2. Wait until `max(now, ticket_until) + 2 days`.
3. Call `registry.finish_exit`, then `collect` to withdraw remaining budget.
4. On Base the ticket expires and anyone can `delist` the runner.

Do not start an exit if you still have open seats in a commit/reveal window; a no-show still costs $2.

---

## 8. Safety and trust (do not skip)

- Send nothing on a real chain unless `BOTLED_SEND=1` and you have verified the addresses in §9 on-chain. There is no Botled-operated Base gas relayer: `enroll`, `commitFor` and `reveal` are permissionless, so pay gas from any funded Base account you control (not your Chain Signatures address).
- Never resample a seat. The relay enforces one run per seat; co-signing two different runs for one seat is a public fraud proof (`reportEquivocation`, permissionless) and retires the relay key.
- You cannot pick your lane or rewrite the prompt. A request that does not match HEAD/TAIL and the case hashes is rejected.
- Sponsor relays can delay or refuse a seat (censorship). Fall back to a liveness reveal, try the next relay URL, and treat a withheld billed run as an audit finding.
- The DeepSeek TEE also serves an `abliterated` variant on the same machine. Binding is the model-prefixed signed text plus `modelHash`. Do not accept a receipt for a different model id.
- Session keys and `BOTLED_STATE` are secrets. Mode 0600, do not commit them.

---

## 9. Addresses

Verify these on-chain before any real call:

```
BOTLED_NEAR_REGISTRY=b0c3f8cbde21c8814baccfd84afce62f70ab33b57fe3717b01828ee41f06c625
BOTLED_CAGE=0xf5992a45bb489F0b20F9da4c43F750f69878Dd2c
BOTLED_POOL=0x4fE84CAe74039df848BEe0c7E7Dd9A4eAfaFf7EF
BotledNearConfig=0xAdb89C4fb606d346BA62F58C4B0e0F47c3e9F20a
BotledNearVerifier=0x5B649acd02838b33777FdBaEe49D9FC405A62483
BotledFactoryV5Near=0xaa7Ee7d31c4fC44060b47C34c6AcaF2ea271F819
enrollSigner=0x7dd9b26E03E355D2C59e972A355C9303B8d1Dd94
SPONSOR_URL=https://relay-a.arb.azzle.org,https://relay-b.arb.azzle.org
Public repo URL=https://github.com/azzle-lab/botled
Site=https://arb.azzle.org  (llms.txt: https://arb.azzle.org/llms.txt)
```

Already real, and not Botled-specific:

- NEAR mainnet USDC: `17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1`
- Chain Signatures: `v1.signer`, path `base-1` for the runner, path `botled-enroll-v1` for tickets
- Base mainnet chain id `8453`
- NEAR AI Cloud: `https://cloud-api.near.ai` (for own-key liveness only)

---

## 10. Minimal TypeScript sketch

```ts
import { NearRpc } from "./near.ts";
import { Runner, configFromEnv, baseClient } from "./loop.ts";

import { createWalletClient, http, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";

const cfg = configFromEnv();          // refuses to send unless BOTLED_SEND=1
const near = NearRpc.fromEnv();
const evm = baseClient();
// No Botled-operated Base gas relayer. enroll / commitFor / reveal are permissionless:
// pay gas from any funded Base account you control (not your Chain Signatures address).
// Keep the key only in the environment; never commit it.
const gasKey = process.env.BASE_GAS_KEY as Hex | undefined;
const relay = {
  send: async (to: Hex, data: Hex) => {
    if (!cfg.send) throw new Error("set BOTLED_SEND=1 to send on Base");
    if (!gasKey) throw new Error("set BASE_GAS_KEY to a funded Base key (you pay gas)");
    const w = createWalletClient({ chain: base, transport: http(), account: privateKeyToAccount(gasKey) });
    return w.sendTransaction({ to, data });
  },
};
const runner = new Runner(near, relay, evm, cfg);

await runner.signup("2000000");      // 2 USDC, 6 decimals
await runner.ensureTicket();
// then: watch DrawFulfilled → runner.serveSeat(...) → runner.revealDue()
```

Run `npm run selftest` and `npm run e2e` in `runner-near` against local anvil first.
