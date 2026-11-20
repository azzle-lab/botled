//! No-show penalties (USDC on NEAR) -> Base, through a NEAR Intents 1Click quote that this module BINDS, so a
//! permissionless keeper can trigger the bridge but cannot redirect, resize or reprice it.
//!
//! Checked against the 1Click-signed payload (ed25519 over base58(sha256(payload)), pinned manager key):
//!   dry == false, swapType EXACT_INPUT, depositType ORIGIN_CHAIN, recipientType DESTINATION_CHAIN,
//!   refundType ORIGIN_CHAIN, refundTo == the penalty account, originAsset / destinationAsset / recipient == the
//!   configured bridge (USDC on NEAR -> USDC on Base -> BotledRewardSwapper), min <= amountIn <= owed penalties,
//!   minAmountOut >= amountIn * (1 - max_slippage_bps) (both sides USDC, 6 decimals), deadline in the future.
//! The Base leg (USDC -> AZL, oracle-bounded) is BotledRewardSwapper.sol.
use crate::crypto::Crypto;
use borsh::{BorshDeserialize, BorshSerialize};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// 1Click manager key (`@defuse-protocol/one-click-sdk-typescript`; same pin as near-hire).
pub const ONE_CLICK_MANAGER_KEY: &str = "reYaWhvwu8Jzo3WUM3zhn6VrhuMEF4eADL17qtRVifc";
pub const MAX_SLIPPAGE_BPS: u16 = 300;

#[derive(BorshSerialize, BorshDeserialize, Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct RewardBridge {
    /// base58 ed25519 key that signs 1Click quotes
    pub manager_key: String,
    /// e.g. "nep141:17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1" (USDC on NEAR)
    pub origin_asset: String,
    /// e.g. "nep141:base-0x833589fcd6edb6e08f4c7c32d4f71b54bda02913.omft.near" (USDC on Base)
    pub destination_asset: String,
    /// BotledRewardSwapper on Base, 0x-hex
    pub recipient: String,
    pub max_slippage_bps: u16,
    /// smallest batch worth bridging (fees are flat), in USDC units
    pub min_amount: u128,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Bound {
    pub deposit_address: String,
    pub deposit_memo: Option<String>,
    pub amount_in: u128,
    pub min_amount_out: u128,
    pub quote_hash: [u8; 32],
}

pub fn validate(b: &RewardBridge) -> Result<(), &'static str> {
    let key = bs58::decode(&b.manager_key).into_vec().map_err(|_| "bridge key")?;
    let r = b.recipient.strip_prefix("0x").unwrap_or("");
    if key.len() != 32
        || b.max_slippage_bps > MAX_SLIPPAGE_BPS
        || r.len() != 40
        || !r.bytes().all(|c| c.is_ascii_hexdigit())
        || !b.origin_asset.starts_with("nep141:")
        || b.destination_asset.is_empty()
        || b.min_amount == 0
    {
        return Err("bridge");
    }
    Ok(())
}

pub fn bind(
    c: &impl Crypto,
    b: &RewardBridge,
    payload: &str,
    signature: &str,
    refund_to: &str,
    available: u128,
    now_secs: u64,
) -> Result<Bound, &'static str> {
    let key: [u8; 32] = bs58::decode(&b.manager_key).into_vec().map_err(|_| "bridge key")?.try_into().map_err(|_| "bridge key")?;
    let sig: [u8; 64] = bs58::decode(signature.strip_prefix("ed25519:").unwrap_or(signature))
        .into_vec()
        .map_err(|_| "quote signature")?
        .try_into()
        .map_err(|_| "quote signature")?;
    let quote_hash = c.sha256(payload.as_bytes());
    let msg = bs58::encode(quote_hash).into_string();
    if !c.ed25519_verify(&sig, msg.as_bytes(), &key) {
        return Err("bad quote signature");
    }
    let v: Value = serde_json::from_str(payload).map_err(|_| "quote json")?;
    let t = |k: &str| v.get(k).and_then(Value::as_str).ok_or("quote field missing");
    let n = |k: &str| -> Result<u128, &'static str> { t(k)?.parse::<u128>().map_err(|_| "quote amount") };
    if v.get("dry").and_then(Value::as_bool) != Some(false) {
        return Err("dry quote");
    }
    if t("swapType")? != "EXACT_INPUT"
        || t("depositType")? != "ORIGIN_CHAIN"
        || t("recipientType")? != "DESTINATION_CHAIN"
        || t("refundType")? != "ORIGIN_CHAIN"
    {
        return Err("quote type");
    }
    if t("refundTo")? != refund_to {
        return Err("refund target");
    }
    if t("originAsset")? != b.origin_asset || t("destinationAsset")? != b.destination_asset {
        return Err("quote assets");
    }
    if !t("recipient")?.eq_ignore_ascii_case(&b.recipient) {
        return Err("recipient mismatch");
    }
    let amount_in = n("amountIn")?;
    if let Some(a) = v.get("amount").and_then(Value::as_str) {
        if a != t("amountIn")? {
            return Err("amount mismatch");
        }
    }
    if amount_in < b.min_amount || amount_in > available {
        return Err("quote amount out of bounds");
    }
    let min_out = n("minAmountOut")?;
    if min_out.saturating_mul(10_000) < amount_in.saturating_mul(10_000 - b.max_slippage_bps as u128) {
        return Err("slippage above cap");
    }
    let deadline = iso_secs(t("deadline")?).ok_or("quote deadline")?;
    if deadline <= now_secs + 60 {
        return Err("quote expired");
    }
    let deposit = t("depositAddress")?;
    if !valid_account(deposit) {
        return Err("deposit address");
    }
    let memo = v.get("depositMemo").and_then(Value::as_str).map(str::to_string);
    Ok(Bound { deposit_address: deposit.to_string(), deposit_memo: memo, amount_in, min_amount_out: min_out, quote_hash })
}

/// NEAR account id rules (implicit 64-hex or named).
pub fn valid_account(a: &str) -> bool {
    (2..=64).contains(&a.len())
        && a.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, b'-' | b'_' | b'.'))
        && !a.starts_with(['.', '-', '_'])
        && !a.ends_with(['.', '-', '_'])
        && !a.contains("..")
}

/// "YYYY-MM-DDTHH:MM:SS(.fff)Z" -> unix seconds
pub fn iso_secs(s: &str) -> Option<u64> {
    let b = s.as_bytes();
    if b.len() < 20 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' || b[16] != b':' || !s.ends_with('Z') {
        return None;
    }
    let num = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, m, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (hh, mm, ss) = (num(11..13)?, num(14..16)?, num(17..19)?);
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) || hh > 23 || mm > 59 || ss > 60 {
        return None;
    }
    // days from civil (H. Hinnant)
    let y2 = if m <= 2 { y - 1 } else { y };
    let era = y2.div_euclid(400);
    let yoe = y2 - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    u64::try_from(days * 86_400 + hh * 3600 + mm * 60 + ss).ok()
}
