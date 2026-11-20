//! Botled NEAR runner registry. Rules live in `botled-logic`; this file is the NEAR wrapper.
//!
//! - USDC (NEP-141) `ft_transfer_call` with msg `{"signup":{"base":"0x..","sig":"0x.."}}` or `{"topup":{}}`
//! - `record_run`: a sponsor relay (or the runner itself, BYO key) bills a NEAR AI receipt against the runner budget
//! - `request_ticket`: charges new Base no-shows, then asks v1.signer to sign the EIP-712 enrollment ticket with the
//!   key derived for (this account, "botled-enroll-v1"); that address is `BotledNearConfig.enrollSigner` on Base
//! - `request_exit` / `finish_exit` / `collect`
//! - owner changes go through a timelock; retiring a NEAR AI key is immediate (it can only stop billing)

use botled_logic::crypto::{hex, unhex, unhex_n, Crypto};
use botled_logic::receipt::{self, SignerKey};
use botled_logic::registry::{self as rules, Change, Pending, Runner, Settings, Status};
use botled_logic::ticket::{self, ENROLL_PATH};
use near_sdk::json_types::{Base64VecU8, U128};
use near_sdk::serde::Serialize;
use near_sdk::serde_json::{self, json, Value};
use near_sdk::store::{LookupMap, LookupSet};
use near_sdk::{env, near, require, AccountId, Gas, NearToken, PanicOnDefault, Promise, PromiseError, PromiseOrValue};

const GAS_MPC_SIGN: Gas = Gas::from_tgas(50);
const GAS_ON_TICKET: Gas = Gas::from_tgas(10);
const GAS_FT_TRANSFER: Gas = Gas::from_tgas(10);
const GAS_ON_COLLECT: Gas = Gas::from_tgas(5);

pub struct NearCrypto;

impl Crypto for NearCrypto {
    fn sha256(&self, d: &[u8]) -> [u8; 32] {
        env::sha256_array(d)
    }
    fn keccak256(&self, d: &[u8]) -> [u8; 32] {
        env::keccak256_array(d)
    }
    fn ed25519_verify(&self, sig: &[u8; 64], msg: &[u8], pk: &[u8; 32]) -> bool {
        env::ed25519_verify(sig, msg, pk)
    }
    fn ecrecover(&self, hash: &[u8; 32], rs: &[u8; 64], v: u8) -> Option<[u8; 64]> {
        // malleability_flag = true: reject high-s (also checked in botled-logic)
        env::ecrecover(hash, rs, v, true)
    }
}

const C: NearCrypto = NearCrypto;

fn ok<T>(r: Result<T, &'static str>) -> T {
    r.unwrap_or_else(|e| env::panic_str(e))
}

fn now() -> u64 {
    env::block_timestamp() / 1_000_000_000
}

#[near(serializers = [json])]
pub struct RunnerView {
    pub base: String,
    pub budget: U128,
    pub spent: U128,
    pub penalties: U128,
    pub no_shows_charged: u32,
    pub epoch: u32,
    pub runs: u64,
    pub ticket_until: u64,
    pub status: String,
}

#[derive(Serialize)]
#[serde(crate = "near_sdk::serde")]
pub struct RunOut {
    pub runner: AccountId,
    pub cost: U128,
    pub charged: U128,
    pub shortfall: U128,
}

/// One billed NEAR AI run, kept in a bounded ring (`RUN_LOG_SIZE`) for public reconciliation against Base reveals
/// (runner-near/tools/audit.ts). Older entries are overwritten; `botled:run` log lines remain in NEAR history.
#[near(serializers = [borsh, json])]
#[derive(Clone, Debug)]
pub struct RunLog {
    pub index: u64,
    pub runner: String,
    pub account: AccountId,
    pub round: u8,
    pub case: String,
    pub request_sha256: String,
    pub response_sha256: String,
    pub signer_id: u32,
    pub model: String,
    pub caller: AccountId,
    pub sponsored: bool,
    pub charged: U128,
    pub at: u64,
}

pub const RUN_LOG_SIZE: u64 = 1024;

#[near(contract_state)]
#[derive(PanicOnDefault)]
pub struct Contract {
    owner: AccountId,
    timelock_secs: u64,
    mpc: AccountId,
    settings: Settings,
    pending: Vec<Option<Pending>>,
    runners: LookupMap<AccountId, Runner>,
    by_base: LookupMap<[u8; 20], AccountId>,
    receipts: LookupSet<[u8; 32]>,
    seats: LookupMap<[u8; 32], u8>,
    owed: LookupMap<AccountId, u128>,
    /// v1.signer root public key (x || y), only used with feature `derivation`
    mpc_root: Option<[u8; 64]>,
    run_log: LookupMap<u64, RunLog>,
    run_count: u64,
    /// sha256 of every 1Click quote payload already used by `bridge_penalties`
    bridged: LookupSet<[u8; 32]>,
}

#[near]
impl Contract {
    #[init]
    pub fn new(owner: AccountId, timelock_secs: u64, mpc: AccountId, settings: Settings, mpc_root: Option<String>) -> Self {
        require!(timelock_secs >= 86_400, "timelock < 1 day");
        for k in &settings.signers {
            ok(rules::validate(&Change::AddSigner(k.clone())));
        }
        ok(rules::validate(&Change::Params(settings.params.clone())));
        ok(rules::validate(&Change::Lanes(settings.lanes.clone())));
        if let Some(b) = &settings.reward_bridge {
            ok(botled_logic::oneclick::validate(b));
        }
        Self {
            owner,
            timelock_secs,
            mpc,
            settings,
            pending: Vec::new(),
            runners: LookupMap::new(b"r"),
            by_base: LookupMap::new(b"b"),
            receipts: LookupSet::new(b"x"),
            seats: LookupMap::new(b"s"),
            owed: LookupMap::new(b"o"),
            mpc_root: mpc_root.map(|s| ok(unhex_n::<64>(&s))),
            run_log: LookupMap::new(b"l"),
            run_count: 0,
            bridged: LookupSet::new(b"q"),
        }
    }

    // ------------------------------------------------------------------ USDC in

    /// NEP-141 receiver. Panics refund the whole transfer (NEP-141 ft_resolve_transfer).
    pub fn ft_on_transfer(&mut self, sender_id: AccountId, amount: U128, msg: String) -> PromiseOrValue<U128> {
        require!(env::predecessor_account_id().as_str() == self.settings.usdc, "only USDC");
        let m: Value = serde_json::from_str(&msg).unwrap_or_else(|_| env::panic_str("msg"));
        if let Some(s) = m.get("signup") {
            let base = ok(unhex_n::<20>(s["base"].as_str().unwrap_or("")));
            let sig = ok(unhex(s["sig"].as_str().unwrap_or("")));
            self.check_derivation(&sender_id, &base);
            if let Some(holder) = self.by_base.get(&base) {
                require!(holder == &sender_id, "base address is bound");
            }
            let existing = self.runners.get(&sender_id).cloned();
            let (runner, credits) = ok(rules::signup(
                &C,
                &self.settings,
                sender_id.as_str(),
                env::current_account_id().as_str(),
                existing.as_ref(),
                base,
                &sig,
                amount.0,
            ));
            self.credit_all(credits);
            self.by_base.insert(base, sender_id.clone());
            self.runners.insert(sender_id.clone(), runner);
            env::log_str(&format!("botled:signup {} base 0x{}", sender_id, hex(&base)));
        } else if let Some(t) = m.get("topup") {
            let who: AccountId = match t.get("runner").and_then(|x| x.as_str()) {
                Some(r) => r.parse().unwrap_or_else(|_| env::panic_str("runner")),
                None => sender_id.clone(),
            };
            let r = self.runners.get_mut(&who).unwrap_or_else(|| env::panic_str("unknown runner"));
            ok(rules::topup(r, amount.0));
            env::log_str(&format!("botled:topup {} {}", who, amount.0));
        } else {
            env::panic_str("msg");
        }
        PromiseOrValue::Value(U128(0))
    }

    // ------------------------------------------------------------------ inference billing

    /// Bills one NEAR AI receipt. Caller must be a sponsor relay or the runner named in the juror line (BYO key).
    pub fn record_run(&mut self, request: Base64VecU8, response: Base64VecU8, signer_id: u32, signature: String) -> RunOut {
        let key: &SignerKey = self.settings.signers.get(signer_id as usize).unwrap_or_else(|| env::panic_str("signer"));
        let v = ok(receipt::verify(&C, key, &request.0, &response.0, &ok(unhex(&signature))));
        let mut id = v.request_hash.to_vec();
        id.extend_from_slice(&v.response_hash);
        require!(self.receipts.insert(env::keccak256_array(&id)), "receipt already billed");
        let mut seat = v.juror.runner.to_vec();
        seat.push(v.juror.round);
        seat.extend_from_slice(&v.juror.case_hash);
        let seat = env::keccak256_array(&seat);
        let seat_runs = self.seats.get(&seat).copied().unwrap_or(0);
        let account = self.by_base.get(&v.juror.runner).cloned().unwrap_or_else(|| env::panic_str("unknown runner"));
        let caller = env::predecessor_account_id();
        let r = self.runners.get_mut(&account).unwrap();
        let ch = ok(rules::charge_run(&self.settings, r, account.as_str(), caller.as_str(), &v, seat_runs));
        self.seats.insert(seat, seat_runs + 1);
        self.credit(&caller, ch.charged);
        let index = self.run_count;
        if index >= RUN_LOG_SIZE {
            self.run_log.remove(&(index - RUN_LOG_SIZE));
        }
        let sponsored = self.settings.sponsors.iter().any(|x| x == caller.as_str());
        self.run_log.insert(
            index,
            RunLog {
                index,
                runner: format!("0x{}", hex(&v.juror.runner)),
                account: account.clone(),
                round: v.juror.round,
                case: format!("0x{}", hex(&v.juror.case_hash)),
                request_sha256: hex(&v.request_hash),
                response_sha256: hex(&v.response_hash),
                signer_id,
                model: v.model.to_string(),
                caller: caller.clone(),
                sponsored,
                charged: U128(ch.charged),
                at: now(),
            },
        );
        self.run_count = index + 1;
        env::log_str(&format!(
            "botled:run {} case 0x{} round {} model {} cost {} charged {} req {} resp {}",
            account,
            hex(&v.juror.case_hash),
            v.juror.round,
            v.model,
            ch.cost,
            ch.charged,
            hex(&v.request_hash),
            hex(&v.response_hash)
        ));
        RunOut { runner: account, cost: U128(ch.cost), charged: U128(ch.charged), shortfall: U128(ch.shortfall) }
    }

    // ------------------------------------------------------------------ Base enrollment via Chain Signatures

    /// `no_shows_covered` = the runner's `noShows` on Base. New ones are charged now ($2 each, into the reward fund);
    /// then v1.signer signs the ticket. `session_key` = a fresh Base address the runner generated for this ticket; it
    /// may sign relayed commits until the next ticket replaces it (no Chain Signatures call per commit).
    /// Attach the MPC fee (currently 1 yoctoNEAR); it is forwarded.
    #[payable]
    pub fn request_ticket(&mut self, no_shows_covered: u32, session_key: String) -> Promise {
        let session = ok(unhex_n::<20>(&session_key));
        let fee = env::attached_deposit();
        require!(fee >= NearToken::from_yoctonear(1), "attach the MPC fee");
        let account = env::predecessor_account_id();
        let r = self.runners.get_mut(&account).unwrap_or_else(|| env::panic_str("unknown runner"));
        let plan = ok(rules::plan_ticket(&self.settings, r, no_shows_covered, now()));
        let base = r.base;
        let penalty_to: AccountId = self.settings.penalty_to.parse().unwrap();
        self.credit(&penalty_to, plan.penalty);
        let near_account = ticket::near_account_hash(&C, account.as_str());
        let digest = ticket::enroll_digest(
            &C,
            &self.settings.pool,
            &base,
            &near_account,
            plan.epoch,
            plan.no_shows_covered,
            plan.valid_until,
            &session,
        );
        let args = json!({"request": {"path": ENROLL_PATH, "payload_v2": {"Ecdsa": hex(&digest)}, "domain_id": 0}});
        Promise::new(self.mpc.clone())
            .function_call("sign", args.to_string().into_bytes(), fee, GAS_MPC_SIGN)
            .then(Self::ext(env::current_account_id()).with_static_gas(GAS_ON_TICKET).on_ticket(
                hex(&base),
                hex(&near_account),
                plan.epoch,
                plan.no_shows_covered,
                plan.valid_until,
                hex(&session),
                hex(&digest),
            ))
    }

    /// Returns everything `BotledRunnerPoolNear.enroll` needs. On MPC failure the epoch is skipped (Base only needs
    /// strictly increasing epochs) and the penalty stays charged (it covers the same no-shows next time).
    #[private]
    pub fn on_ticket(
        &self,
        base: String,
        near_account: String,
        epoch: u32,
        no_shows_covered: u32,
        valid_until: u64,
        session_key: String,
        digest: String,
        #[callback_result] sig: Result<Value, PromiseError>,
    ) -> Value {
        let sig = sig.unwrap_or_else(|_| env::panic_str("mpc sign failed; retry request_ticket"));
        json!({
            "runner": format!("0x{base}"), "nearAccount": format!("0x{near_account}"), "epoch": epoch,
            "noShowsCovered": no_shows_covered, "validUntil": valid_until, "sessionKey": format!("0x{session_key}"), "digest": format!("0x{digest}"), "mpc": sig
        })
    }

    // ------------------------------------------------------------------ exit and payouts

    pub fn request_exit(&mut self) -> u64 {
        let r = self.runners.get_mut(&env::predecessor_account_id()).unwrap_or_else(|| env::panic_str("unknown runner"));
        ok(rules::request_exit(&self.settings, r, now()))
    }

    pub fn finish_exit(&mut self, account: AccountId) -> U128 {
        let r = self.runners.get_mut(&account).unwrap_or_else(|| env::panic_str("unknown runner"));
        let out = ok(rules::finish_exit(r, now()));
        self.credit(&account, out);
        U128(out)
    }

    /// Pays out what `account` is owed (profit, dev, penalties, sponsor or BYO reimbursements, exit refunds).
    pub fn collect(&mut self, account: AccountId) -> Promise {
        let amount = self.owed.remove(&account).unwrap_or(0);
        require!(amount > 0, "nothing owed");
        let usdc: AccountId = self.settings.usdc.parse().unwrap();
        Promise::new(usdc)
            .function_call(
                "ft_transfer",
                json!({"receiver_id": account, "amount": U128(amount)}).to_string().into_bytes(),
                NearToken::from_yoctonear(1),
                GAS_FT_TRANSFER,
            )
            .then(Self::ext(env::current_account_id()).with_static_gas(GAS_ON_COLLECT).on_collect(account, U128(amount)))
    }

    #[private]
    pub fn on_collect(&mut self, account: AccountId, amount: U128, #[callback_result] r: Result<(), PromiseError>) -> bool {
        if r.is_err() {
            self.credit(&account, amount.0);
        }
        r.is_ok()
    }

    // ------------------------------------------------------------------ penalties -> AZL rewards

    /// Permissionless keeper call: moves `amountIn` of the owed no-show penalties to a 1Click deposit address, bound
    /// by a 1Click-signed quote (see botled_logic::oneclick): USDC(NEAR) -> USDC(Base) -> BotledRewardSwapper, refund
    /// to `penalty_to`, slippage <= cap. The keeper cannot change recipient, assets, refund target or size; a failed
    /// transfer is re-credited. Each quote can be used once.
    pub fn bridge_penalties(&mut self, payload: String, signature: String) -> Promise {
        let bridge = self.settings.reward_bridge.clone().unwrap_or_else(|| env::panic_str("no reward bridge"));
        let fund: AccountId = self.settings.penalty_to.parse().unwrap_or_else(|_| env::panic_str("penalty_to"));
        let available = self.owed.get(&fund).copied().unwrap_or(0);
        let b = ok(botled_logic::oneclick::bind(&C, &bridge, &payload, &signature, fund.as_str(), available, now()));
        require!(self.bridged.insert(b.quote_hash), "quote already used");
        self.owed.insert(fund.clone(), available - b.amount_in);
        env::log_str(&format!(
            "botled:bridge {} usdc -> {} min_out {} quote {}",
            b.amount_in,
            bridge.recipient,
            b.min_amount_out,
            hex(&b.quote_hash)
        ));
        let usdc: AccountId = self.settings.usdc.parse().unwrap();
        let mut args = json!({"receiver_id": b.deposit_address, "amount": U128(b.amount_in)});
        if let Some(m) = b.deposit_memo {
            args["memo"] = json!(m);
        }
        Promise::new(usdc)
            .function_call("ft_transfer", args.to_string().into_bytes(), NearToken::from_yoctonear(1), GAS_FT_TRANSFER)
            .then(Self::ext(env::current_account_id()).with_static_gas(GAS_ON_COLLECT).on_collect(fund, U128(b.amount_in)))
    }

    // ------------------------------------------------------------------ owner

    pub fn propose(&mut self, change: Change) -> u32 {
        self.only_owner();
        ok(rules::validate(&change));
        self.pending.push(Some(Pending { change, eta: now() + self.timelock_secs }));
        (self.pending.len() - 1) as u32
    }

    pub fn cancel(&mut self, id: u32) {
        self.only_owner();
        self.pending[id as usize] = None;
    }

    /// Anyone may apply a due change.
    pub fn apply(&mut self, id: u32) {
        let p = self.pending.get_mut(id as usize).and_then(|x| x.take()).unwrap_or_else(|| env::panic_str("no change"));
        if let Some(o) = ok(rules::apply(&mut self.settings, p, now())) {
            self.owner = o.parse().unwrap_or_else(|_| env::panic_str("owner"));
        }
    }

    pub fn retire_signer(&mut self, id: u32) {
        self.only_owner();
        self.settings.signers[id as usize].active = false;
    }

    // ------------------------------------------------------------------ views

    pub fn get_runner(&self, account: AccountId) -> Option<RunnerView> {
        self.runners.get(&account).map(|r| RunnerView {
            base: format!("0x{}", hex(&r.base)),
            budget: U128(r.budget),
            spent: U128(r.spent),
            penalties: U128(r.penalties),
            no_shows_charged: r.no_shows_charged,
            epoch: r.epoch,
            runs: r.runs,
            ticket_until: r.ticket_until,
            status: match r.status {
                Status::Active => "active".into(),
                Status::Exiting { at } => format!("exiting until {at}"),
                Status::Exited => "exited".into(),
            },
        })
    }

    pub fn runner_of(&self, base: String) -> Option<AccountId> {
        self.by_base.get(&ok(unhex_n::<20>(&base))).cloned()
    }

    /// Billed runs `[from, from + limit)` still in the ring (limit <= 200). `run_count` = total ever billed.
    pub fn get_runs(&self, from: u64, limit: u64) -> Vec<RunLog> {
        let lo = from.max(self.run_count.saturating_sub(RUN_LOG_SIZE));
        let hi = self.run_count.min(lo.saturating_add(limit.min(200)));
        (lo..hi).filter_map(|i| self.run_log.get(&i).cloned()).collect()
    }

    pub fn run_count(&self) -> u64 {
        self.run_count
    }

    pub fn owed_to(&self, account: AccountId) -> U128 {
        U128(self.owed.get(&account).copied().unwrap_or(0))
    }

    pub fn get_settings(&self) -> &Settings {
        &self.settings
    }

    pub fn get_owner(&self) -> &AccountId {
        &self.owner
    }

    pub fn get_pending(&self) -> &Vec<Option<Pending>> {
        &self.pending
    }

    /// The Base address signup requires for `account`: its v1.signer address for path "base-1" under the stored
    /// `mpc_root` (None if no root is stored or the build has no `derivation` feature, i.e. not enforced).
    pub fn chain_signature_base(&self, account: AccountId) -> Option<String> {
        self.derived_base(&account).map(|b| format!("0x{}", hex(&b)))
    }

    pub fn signup_message(&self, account: AccountId, base: String) -> String {
        rules::signup_message(account.as_str(), &ok(unhex_n::<20>(&base)), env::current_account_id().as_str())
    }
}

impl Contract {
    fn only_owner(&self) {
        require!(env::predecessor_account_id() == self.owner, "owner only");
    }

    fn credit(&mut self, account: &AccountId, amount: u128) {
        if amount > 0 {
            *self.owed.entry(account.clone()).or_insert(0) += amount;
        }
    }

    fn credit_all(&mut self, credits: rules::Credits) {
        for (a, x) in credits {
            let a: AccountId = a.parse().unwrap_or_else(|_| env::panic_str("recipient"));
            self.credit(&a, x);
        }
    }

    #[cfg(feature = "derivation")]
    fn derived_base(&self, account: &AccountId) -> Option<[u8; 20]> {
        self.mpc_root.as_ref().map(|root| {
            let pk = ok(botled_logic::chainsig::derive_public_key(root, account.as_str(), BASE_PATH));
            botled_logic::crypto::eth_address(&C, &pk)
        })
    }

    #[cfg(not(feature = "derivation"))]
    fn derived_base(&self, _account: &AccountId) -> Option<[u8; 20]> {
        None
    }

    fn check_derivation(&self, account: &AccountId, base: &[u8; 20]) {
        if let Some(want) = self.derived_base(account) {
            require!(&want == base, "base is not the runner's chain-signature address");
        }
    }
}

/// Chain Signatures path the runner client uses for its Base identity.
pub const BASE_PATH: &str = "base-1";

#[cfg(test)]
mod tests;
