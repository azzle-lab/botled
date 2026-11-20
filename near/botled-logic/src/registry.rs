//! Runner accounting. All amounts are USDC base units (6 decimals).
//!
//! signup: $20 -> $5 profit_to + $5 dev_to + $10 runner LLM budget (anything above $20 also goes to the budget)
//! topup:  100% budget
//! run:    a NEAR AI receipt for the runner's juror line is priced from its signed `usage` and the lane price,
//!         and the cost moves from the runner's budget to whoever paid NEAR AI (sponsor relay, or the runner on BYO key)
//! ticket: before an enrollment ticket is signed, every Base no-show it covers is charged `no_show_penalty`
//! exit:   no new tickets; after the last ticket expired + exit_delay the remaining budget becomes withdrawable

use borsh::{BorshDeserialize, BorshSerialize};
use serde::{Deserialize, Serialize};

use crate::crypto::{hex, recover_personal, Crypto};
use crate::receipt::{SignerKey, Verified};
use crate::ticket::PoolDomain;

pub const USDC: u128 = 1_000_000;

#[derive(BorshSerialize, BorshDeserialize, Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct Params {
    pub signup_fee: u128,
    pub profit_cut: u128,
    pub dev_cut: u128,
    pub no_show_penalty: u128,
    /// budget a runner must still hold (after penalties) to get a ticket
    pub min_ticket_budget: u128,
    pub ticket_ttl_secs: u64,
    pub exit_delay_secs: u64,
    pub max_cost_per_run: u128,
    /// receipts billed per (runner, round, case): 1 = no resampling
    pub max_runs_per_seat: u8,
}

impl Default for Params {
    fn default() -> Self {
        Self {
            signup_fee: 20 * USDC,
            profit_cut: 5 * USDC,
            dev_cut: 5 * USDC,
            no_show_penalty: 2 * USDC, // -> penalty_to = the Botled reward fund
            min_ticket_budget: USDC,
            ticket_ttl_secs: 7 * 86_400,
            exit_delay_secs: 2 * 86_400,
            max_cost_per_run: USDC / 5, // worst case kimi-k3 with 6000 completion tokens ~ $0.11
            max_runs_per_seat: 1,
        }
    }
}

/// USDC units per million tokens.
#[derive(BorshSerialize, BorshDeserialize, Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct LanePrice {
    pub model: String,
    pub input_per_mtok: u128,
    pub output_per_mtok: u128,
    /// NEAR AI key class accepted for this lane (Gateway for kimi-k3, ProviderTee for DeepSeek-V4.1-Flash-1017)
    pub receipt_kind: crate::receipt::Kind,
}

#[derive(BorshSerialize, BorshDeserialize, Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct Settings {
    pub params: Params,
    pub usdc: String,
    pub profit_to: String,
    pub dev_to: String,
    /// receives no-show penalties: the Botled reward fund (converted to AZL for BotledRunnerPoolNear.fundRewards)
    pub penalty_to: String,
    pub lanes: Vec<LanePrice>,
    pub signers: Vec<SignerKey>,
    /// accounts that call NEAR AI with their own key and bill runners (Botled sponsor relay)
    pub sponsors: Vec<String>,
    pub pool: PoolDomain,
    /// USDC penalties -> Base reward swapper via a bound 1Click quote (None = penalties are only `collect`ed)
    #[serde(default)]
    pub reward_bridge: Option<crate::oneclick::RewardBridge>,
}

#[derive(BorshSerialize, BorshDeserialize, Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Active,
    Exiting { at: u64 },
    Exited,
}

#[derive(BorshSerialize, BorshDeserialize, Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct Runner {
    pub base: [u8; 20],
    pub budget: u128,
    pub spent: u128,
    pub penalties: u128,
    pub no_shows_charged: u32,
    pub epoch: u32,
    pub runs: u64,
    pub ticket_until: u64,
    pub status: Status,
}

/// Credits that move as a result of an action: (account, amount) pairs to add to the claimable ledger.
pub type Credits = Vec<(String, u128)>;

pub fn signup_message(account: &str, base: &[u8; 20], registry: &str) -> String {
    format!("botled-near signup v1\nnear: {account}\nbase: 0x{}\nregistry: {registry}", hex(base))
}

/// New runner from a USDC deposit. `base_sig` is an EIP-191 signature of `signup_message` by `base`
/// (made through v1.signer by the runner's NEAR account; see chainsig).
pub fn signup(
    c: &impl Crypto,
    s: &Settings,
    account: &str,
    registry: &str,
    existing: Option<&Runner>,
    base: [u8; 20],
    base_sig: &[u8],
    amount: u128,
) -> Result<(Runner, Credits), &'static str> {
    let p = &s.params;
    if amount < p.signup_fee {
        return Err("signup fee");
    }
    match existing {
        Some(r) if r.status != Status::Exited => return Err("already registered"),
        Some(r) if r.base != base => return Err("base address is bound"),
        _ => {}
    }
    if recover_personal(c, signup_message(account, &base, registry).as_bytes(), base_sig) != Some(base) {
        return Err("base proof");
    }
    let prev = existing.cloned();
    let runner = Runner {
        base,
        budget: amount - p.profit_cut - p.dev_cut,
        spent: prev.as_ref().map_or(0, |r| r.spent),
        penalties: prev.as_ref().map_or(0, |r| r.penalties),
        no_shows_charged: prev.as_ref().map_or(0, |r| r.no_shows_charged),
        epoch: prev.as_ref().map_or(0, |r| r.epoch),
        runs: prev.as_ref().map_or(0, |r| r.runs),
        ticket_until: 0,
        status: Status::Active,
    };
    Ok((runner, vec![(s.profit_to.clone(), p.profit_cut), (s.dev_to.clone(), p.dev_cut)]))
}

pub fn topup(r: &mut Runner, amount: u128) -> Result<(), &'static str> {
    if r.status != Status::Active || amount == 0 {
        return Err("topup");
    }
    r.budget += amount;
    Ok(())
}

pub fn price(lane: &LanePrice, prompt: u64, completion: u64) -> u128 {
    let raw = prompt as u128 * lane.input_per_mtok + completion as u128 * lane.output_per_mtok;
    raw.div_ceil(1_000_000)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Charge {
    pub cost: u128,
    pub charged: u128,
    pub shortfall: u128,
    pub payee: String,
}

/// Bills one verified receipt. `seat_runs` = receipts already billed for the same (runner, round, case).
/// Dedupe of the receipt itself (by request/response hash) is the caller's job (storage set).
pub fn charge_run(
    s: &Settings,
    r: &mut Runner,
    account: &str,
    caller: &str,
    v: &Verified,
    seat_runs: u8,
) -> Result<Charge, &'static str> {
    if matches!(r.status, Status::Exited) {
        return Err("exited");
    }
    if caller != account && !s.sponsors.iter().any(|x| x == caller) {
        return Err("not a sponsor");
    }
    if v.juror.runner != r.base {
        return Err("receipt is for another runner");
    }
    if seat_runs >= s.params.max_runs_per_seat {
        return Err("seat already billed");
    }
    let lane = s.lanes.iter().find(|l| l.model == v.model).ok_or("model is not a lane")?;
    if lane.receipt_kind != v.kind {
        return Err("wrong key class for lane");
    }
    let cost = price(lane, v.usage.prompt_tokens, v.usage.completion_tokens).min(s.params.max_cost_per_run);
    let charged = cost.min(r.budget);
    r.budget -= charged;
    r.spent += charged;
    r.runs += 1;
    Ok(Charge { cost, charged, shortfall: cost - charged, payee: caller.to_string() })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TicketPlan {
    pub epoch: u32,
    pub no_shows_covered: u32,
    pub valid_until: u64,
    pub penalty: u128,
}

/// Charges penalties for no-shows up to `covered` (the runner's on-Base `noShows`; claiming less keeps it suspended
/// on Base, claiming more only costs the runner) and plans the next ticket.
pub fn plan_ticket(s: &Settings, r: &mut Runner, covered: u32, now: u64) -> Result<TicketPlan, &'static str> {
    if r.status != Status::Active {
        return Err("not active");
    }
    let p = &s.params;
    let new = covered.saturating_sub(r.no_shows_charged) as u128;
    let penalty = new * p.no_show_penalty;
    if r.budget < penalty + p.min_ticket_budget {
        return Err("budget too low");
    }
    r.budget -= penalty;
    r.penalties += penalty;
    r.no_shows_charged = r.no_shows_charged.max(covered);
    r.epoch += 1;
    r.ticket_until = now + p.ticket_ttl_secs;
    Ok(TicketPlan { epoch: r.epoch, no_shows_covered: r.no_shows_charged, valid_until: r.ticket_until, penalty })
}

pub fn request_exit(s: &Settings, r: &mut Runner, now: u64) -> Result<u64, &'static str> {
    if r.status != Status::Active {
        return Err("not active");
    }
    let at = now.max(r.ticket_until) + s.params.exit_delay_secs;
    r.status = Status::Exiting { at };
    Ok(at)
}

/// Returns the budget that becomes withdrawable by the runner.
pub fn finish_exit(r: &mut Runner, now: u64) -> Result<u128, &'static str> {
    match r.status {
        Status::Exiting { at } if now >= at => {
            let out = r.budget;
            r.budget = 0;
            r.status = Status::Exited;
            Ok(out)
        }
        _ => Err("exit not due"),
    }
}

// ------------------------------------------------------------------ owner changes behind a timelock

#[derive(BorshSerialize, BorshDeserialize, Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub enum Change {
    Params(Params),
    Recipients { profit_to: String, dev_to: String, penalty_to: String },
    Lanes(Vec<LanePrice>),
    AddSigner(SignerKey),
    Sponsors(Vec<String>),
    Pool(PoolDomain),
    Owner(String),
    RewardBridge(Option<crate::oneclick::RewardBridge>),
}

#[derive(BorshSerialize, BorshDeserialize, Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct Pending {
    pub change: Change,
    pub eta: u64,
}

pub fn validate(change: &Change) -> Result<(), &'static str> {
    match change {
        Change::Params(p) => {
            if p.profit_cut + p.dev_cut > p.signup_fee || p.max_runs_per_seat == 0 || p.ticket_ttl_secs == 0 {
                return Err("params");
            }
        }
        Change::Lanes(l) => {
            if l.is_empty() {
                return Err("lanes");
            }
        }
        Change::RewardBridge(Some(b)) => crate::oneclick::validate(b)?,
        Change::AddSigner(k) => {
            let len_ok = match k.scheme {
                crate::receipt::Scheme::Ecdsa => k.key.len() == 20,
                crate::receipt::Scheme::Ed25519 => k.key.len() == 32,
            };
            let model_ok = (k.kind == crate::receipt::Kind::ProviderTee) == k.model.is_some();
            if !len_ok || !model_ok || !k.active {
                return Err("signer");
            }
        }
        _ => {}
    }
    Ok(())
}

/// Applies a due change; returns the new owner if ownership moved.
pub fn apply(s: &mut Settings, p: Pending, now: u64) -> Result<Option<String>, &'static str> {
    if now < p.eta {
        return Err("timelock");
    }
    match p.change {
        Change::Params(x) => s.params = x,
        Change::Recipients { profit_to, dev_to, penalty_to } => {
            s.profit_to = profit_to;
            s.dev_to = dev_to;
            s.penalty_to = penalty_to;
        }
        Change::Lanes(x) => s.lanes = x,
        Change::AddSigner(k) => s.signers.push(k),
        Change::Sponsors(x) => s.sponsors = x,
        Change::Pool(x) => s.pool = x,
        Change::Owner(o) => return Ok(Some(o)),
        Change::RewardBridge(b) => s.reward_bridge = b,
    }
    Ok(None)
}
